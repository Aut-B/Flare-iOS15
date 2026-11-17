# 15 Pro Max 启动闪退 · 排查准备（无 .ips 阶段）

状态：**尚无真机 crash log**。本文只做事实登记，不含任何「已确认根因」的结论。

---

## 一、LaunchGuard 现状

文件：`appleApp/ios/UI/Feature/WebSocial/LaunchGuard.swift`（148 行）
配套：`Instagram/InstagramStateIsolator.swift`（275 行）

### 它兜的是什么
iOS 15 移植期出现过「登录 Instagram 后，15PM 每次冷启动都闪退」——崩在**主界面构建阶段**。
解决方式不是修崩溃，而是**隔离坏状态**：清 Instagram cookie / DbAccount / WKWebsiteDataStore。

### 生效点（启动链路顺序）
```
FlareApp.init()
  └─ LaunchGuard.begin()            ← 写 activeKey=true，synchronize()
WindowGroup → LaunchLoadingView.onAppear
  └─ startLaunch()
       ├─ if recoveryMode → LaunchRecoveryView（不 bootstrap）
       ├─ InstagramStateIsolator.quarantineIfNeeded()
       └─ bootstrap()
            └─ AppleSharedHelper.shared.initialize()  ← Kotlin / Koin
  └─ appRoot → onAppear → LaunchGuard.markFullUIShown()
scenePhase == .background → LaunchGuard.markStable()   ← 唯一清零点
```

### 判定逻辑
| 条件 | 结果 |
|---|---|
| 上次 `activeKey` 还在（没进过后台） | 崩 1 次 → 安全模式（阻断隐藏网页 + IG 隔离） |
| 连续 2 次 | → `LaunchRecoveryView`，`bootstrap()` 完全跳过 |
| 主界面存活 45s | 解除安全模式（崩溃计数不清零） |
| 进入后台 | 彻底清零 |

### 明确兜不住的
1. **dyld 阶段**：`begin()` 是 Swift 代码；符号缺失 / framework 加载失败到不了这里。
2. **任何「硬崩」**：LaunchGuard 是事后计数，进程被 kill 时什么都写不了。
3. **`bootstrap()` 抛 NSException**：会累加计数，但恢复动作只有 IG 隔离这一条，对非 IG 原因无效。
4. **`quarantineIfNeeded()` 内部崩**（Kotlin 初始化之前跑 SQLite）：会计数，但没有对应恢复路径。

---

## 二、15PM 与 6S 的差异面

| 维度 | iPhone 15 Pro Max | iPhone 6S | 启动期风险 |
|---|---|---|---|
| 最高系统 | iOS 26.x 可用 | **iOS 15.8 封顶** | 决定走哪条根视图路径 |
| 根视图 | `FlareRoot`（`@available(iOS 18.0,*)`） | `BackportFlareRoot` | **两条完全不同的代码路径** |
| SwiftUI API | `Tab(value:role:)` / `TabSection` | NavigationBackport 回退 | 15PM 独有的 API 面 |
| CPU 架构 | arm64e | arm64 | arm64e PAC 下符号/指针问题更敏感 |
| Metal | A17 Pro | A9 | Compose 渲染后端能力差异 |
| dyld | 新版 chained fixups | 旧版 | 15PM 对库加载更严格 |

**关键结论**：15PM 和 6S 跑的**不是同一份界面代码**。任何只在 15PM 上出现的启动崩溃，
首先要怀疑 `FlareRoot` 分支与 `BackportFlareRoot` 分支的差异，而不是共享层。

---

## 三、启动链路节点清单（当前代码）

| # | 节点 | 代码位置 | 候选崩溃类型 |
|---|---|---|---|
| 0 | dyld 加载 | 二进制 | 符号缺失、framework 损坏、bitcode |
| 1 | `LaunchGuard.begin()` | `FlareApp.swift:24` | UserDefaults 异常（概率低） |
| 2 | `LaunchCrashTrace.install()` | 本次新增 | open/strdup 失败（已容忍） |
| 3 | `startLaunch` → 恢复模式判断 | `FlareApp.swift:60` | 无 |
| 4 | `quarantineIfNeeded()` | `InstagramStateIsolator.swift:99` | SQLite 损坏、WKWebsiteDataStore 回调死锁 |
| 5 | `MediaCacheMaintenance.configure()` | `bootstrap()` | 文件系统 / 磁盘配额 |
| 6 | `configureAudioSessionForMixing()` | `AudioSessionManager.activateAmbient()` | **已 try/catch，低风险** |
| 7 | `FirebaseBootstrap.configureIfAvailable()` | `Shared/Firebase/FirebaseBootstrap.swift` | **低风险**：plist 不在仓库（.gitignore），脚本缺失即禁用，不会调 configure |
| 8 | `AppleSharedHelper.shared.initialize()` | `apple-shared/.../AppleSharedHelper.kt:27` | **高风险**：`startKoin<AppleKoinApplication>()` 无任何保护，Koin 装配失败 / `requireNotNull` 抛 Kotlin 异常 → Swift 侧直接 abort |
| 9 | 三个 BridgeHolder（异步主线程） | `FlareApp.swift:103` | Swift bridge 构造异常 |
| 10 | `FlareRoot`（iOS 18+） | `UI/FlareRoot.swift:15` | 4 个 `@StateObject` Kotlin presenter 构造期抛异常 |
| 11 | `BackportFlareRoot`（iOS 15） | `UI/FlareRoot.swift:138` | 同上，另一条路径 |

### 已排除
- **Firebase 配置缺失**：`.gitignore` 排除了 `GoogleService-Info.plist`，但 xcodegen 的
  `Copy Firebase Config` 脚本在文件不存在时只打一行日志，`configureIfAvailable()` 返回 false。
- **音频会话**：`setCategory` / `setActive` 全部包在 do/catch 里。
- **权限描述缺失**：不算问题。`MediaSaver` 用的全是 `.addOnly` 授权，
  只需要 `NSPhotoLibraryAddUsageDescription`，`Info.plist` 里有。
  而且这些调用都在保存图片的交互路径，**不在启动链路**。
- **Privacy Manifest**：全仓无 `PrivacyInfo.xcprivacy`。这是上架合规问题，**不导致启动崩溃**。

---

## 四、LaunchGuard 兜底边界（说死）

能兜：
- 主界面构建期**可恢复**的崩溃（坏缓存 / 坏账号状态 / 坏 JSON）—— 靠清状态。
- 重复崩 → 停在兜底页，至少 App 能打开。

不能兜：
- dyld 加载失败、KMP native `main` 之前崩。
- 符号缺失类问题。
- 每次都崩且与状态无关的确定性崩溃（清状态没用，只会让用户丢账号）。

**所以：拿到 .ips 先看崩溃线程和栈，不要先怀疑 LaunchGuard 没兜住。**

---

## 五、拿到 .ips 之后的动作

1. 解析 `exception` / `termination.reason` / `faultingThread`，确认是 ObjC 异常、Swift 运行时、还是 SIGSEGV/SIGABRT。
2. 符号化栈顶 5 帧，映射到上表节点编号。
3. 对照兜底页里 `LaunchCrashTrace` 记录的 `stage=`，判断是启动期一次性崩还是特定状态崩。
4. **有确定根因再出 patch。**

---

## 六、FlareRoot 的 iOS 18+ 专有 API 静态排查（不需要真机）

`FlareRoot` 定义在 `appleApp/ios/UI/FlareRoot.swift:15`，`@available(iOS 18.0, *)`，
`FlareApp.appRoot` 用 `if #available(iOS 18.0, *)` 二选一。15PM（iOS 18/26）走这里，
6S（iOS 15 上限）走 `BackportFlareRoot`。下面是逐个 API 的清点。

| API | 位置 | iOS | 说明 |
|---|---|---|---|
| `Tab(value:role:)` | `:31` | 16.0 / role 参数 18.0 | 新 tab 构造器；`role: .search` 只在 discover 一个 tab 上 |
| `Tab(value:){}label:` | `:102` `:116` | 18.0 | iPad 侧栏用 |
| `TabSection` | `:53` | 18.0 | iPad 侧栏分组 |
| `.tabPlacement(.sidebarOnly)` | `:66` `:111` `:125` | 18.0 | iPad 侧栏专用放置 |
| `.tabViewStyle(.sidebarAdaptable)` | `:80` | 18.0 | iPhone 上等价于普通 tab bar |
| `.badge(_:)` | `:43` `:169` | 15.0 | 不是 18 专有 |

### 结论 1：`ForEach(items, id: \.name)` 重名假设 —— **排除**

`items` 是 `HomeTabsPresenterStateHomeTabs`，Kotlin 侧
（`shared/.../presenter/HomeTabsPresenter.kt:23-27`）是一个只有三个值的 enum：
`Home` / `Notifications` / `Discover`，且 `tabsFlow` 只用 `persistentListOf` 拼固定组合
（`:35-45`），最多 3 个、不会重复。`id: \.name` 不可能撞车。
**这条假设不成立，不需要为它改代码。**

### 结论 2：`TabSection` / `ForEach(tabs, id: \.tab)` 重名 —— **不适用**

两者都在 `if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular`
里面（`:46`）。15PM 是 iPhone，整段不执行。二级 tab 的 `Tab` 是 `data class`
（`SecondaryTabsPresenter.kt:50`），`id: \.tab` 用整对象比较，理论上同账号配置里出现
两条完全相同的 shortcut 才会撞，但这条路 15PM 走不到。

### 结论 3：`UIDevice.current.userInterfaceIdiom` 读在 body 里

`:46` 在 `body` 里读 `UIDevice.current`：这是 UIKit 环境值，不参与 SwiftUI 依赖追踪，
iPhone 上是常量 `false`，不会引发重算风暴。**风险低，不改。**

### 结论 4：空 tabs 列表会渲染空 TabView —— **两分支共有，不是 15PM 独有**

`StateView`（`FlareAppleCore/.../StateView.swift:24-33`）只有 loading / error / success
三态。`HomeTabsPresenter` 在账号服务为空时仍会返回 `.success(空列表)`，此时
`FlareRoot` 与 `BackportFlareRoot` 都会渲染一个**没有任何 tab 的 TabView**。
如果这是崩溃源，6S 上也会崩；既然只有 15PM 报，说明它不是主因。**列为待观察，不改。**

### 结论 5：`.tabViewStyle(.sidebarAdaptable)` 在 iPhone 上的行为

iPhone 上 `sidebarAdaptable` 退化为标准底部 tab bar，**但 UIKit 层仍会建
`UITabBarController` 并走 `tabs` / `compactTabIdentifiers` 那套新模型**。
仓库里已有前科：`IPadCompactTabBarModifier.swift:30` 的注释写着
「avoid the iOS 27 tab bar rebuild crash」，那是上游 `708954ce2` 为 iPad 修的，
**并且它第一行就是 `guard userInterfaceIdiom == .pad else { return }`** —— iPhone
不走这段修补。也就是说：同类崩溃在 iPhone 上没有任何护栏。

> 这是本轮唯一一条「代码层面能看出缺护栏」的线索，但**没有证据说 15PM 就是它**。
> 要证伪/证实必须靠 .ips 的崩溃线程与栈。在此之前不改 FlareRoot。

**注意**：`IPadCompactTabBarModifier` 里 `.introspect(.tabView, on: .iOS(.v17))`
（iOS 15 backport 后改成 `.v17`），而上游原版是 `.iOS(.v18, .v26, .v27)`。
backport 把版本列表收窄到 `.v17` —— 在 iOS 26 上 introspect 是否还会回调，
**这一点存疑，可能让 iPad 的护栏在 26 上失效**。与 iPhone 无关，但值得单独提给 flare。
（已核实：改动来自 `940dec712`，是 deploymentTarget 17→15 时连带改的，不是有意为之。）

---

## 七、崩溃时线程调用栈

### 为什么不用 `backtrace_symbols_fd`

`backtrace_symbols_fd` **不是 async-signal-safe** 的：内部要 `malloc` 并可能拿锁。
在信号处理里调用，如果信号正好打断了一次 malloc 或某个持锁操作，就会死锁或再次崩溃，
现场反而丢了。

### 为什么不用 `dladdr`

`dladdr` 会拿 dyld 的锁。崩溃时那把锁很可能正被别的线程持有，调用它就是死锁风险。

### 实际做法

1. `backtrace(buffer, 64)` 填一串返回地址。`backtrace` 只读栈和 unwind 信息，
   比 `backtrace_symbols_fd` 安全得多，是崩溃处理器里常见的选择。
2. 逐帧格式化成 `# NN 0x<绝对地址>`，全程 `withUnsafeTemporaryAllocation` 临时缓冲，
   无堆分配。
3. 补偿：`install()` 时往崩溃日志第一行写本次运行的 `image-base 0x...`
   （`_dyld_get_image_header(0)`，PIE 每次启动都变）。
   拿到地址后 `atos -o Flare.app/Flare -arch arm64 -l <image-base> 0x<addr>` 即可还原。

### 信号处理器必须是顶层 `@convention(c)`

`sigaction.__sa_handler` 就是 C 函数指针，捕获了上下文的闭包在编译期转换不过去。
所以处理器是文件级的 `flareSignalHandler: @convention(c) (Int32) -> Void`，
通过文件级 `fatalTable` 取预烘好的表。**改这段时别用回捕获闭包，编译必挂。**

### 信号路径的分配清理

原实现的表是嵌套 `[[[UInt8]]]`，下标访问会走 retain/release 和 COW 检查，
`withUnsafeBytes` 还可能桥接。现在：

- 所有 `信号 × stage` 的行平铺在**一整块**连续内存里（裸指针 + 固定步长 + NUL 结尾）。
- `rawValue → 下标` 走 256 项定长映射表，不假设 rawValue 连续。
- 帧缓冲和十六进制表都是裸缓冲，不碰 Swift 数组。
- `install()` 末尾 `prewarmSignalPath()` 把信号路径要读的全局常量先摸一遍，
  避免首次访问时的惰性初始化检查。

### 覆盖边界（说死）

| 崩溃类型 | 能否记录 | 拿到什么 |
|---|---|---|
| `NSException`（ObjC/Swift 抛出未捕获） | 能 | 异常名 + reason + 符号化栈 + stage |
| Swift 运行时 trap（越界/强解包） | 能 | 信号 + stage + 原始栈地址 |
| Kotlin 异常冒泡 | 多半能（落到 SIGABRT） | 信号 + stage + 原始栈地址 |
| 主线程 watchdog（0x8badf00d） | **不能** | 进程被系统 kill，不经过信号 |
| 内存耗尽（jetsam） | **不能** | 同上 |
| dyld / `main` 之前 | **不能** | 只能靠 .ips |

**所以 .ips 仍然不可替代。** 这套记录的价值是：用户一打开 App 就能把现场贴回来，
不用等用户学会导出 .ips，也不用等崩溃同步到 Crashlytics。

---

## 八、兜底页显示条件放宽到 crashes>=1

### 原问题

`LaunchCrashTrace` 的记录只在 `LaunchRecoveryView`（`crashes>=2`）里显示。
但崩 1 次时走的是安全模式下的**正常主界面**，用户根本看不到恢复页。
等于第一次崩溃的现场白存，要等第二次崩了才看得到 —— 那时候可能已经丢账号了。

### 做法

- `startLaunch()` 里在 `LaunchGuard.recoveryMode` 判断之前，
  用 `LaunchGuard.lastCrashCount >= 1 && !lastCrash.isEmpty` 决定是否显示。
- 显示位在主界面顶部，用 `.safeAreaInset(edge: .top)`，一条可展开/可复制/可关闭的横幅。
- 进后台时（`markStable()` 会清零崩溃计数）同时把横幅收掉，避免误导。

### 为什么不直接把恢复页提前显示

那会让崩一次的用户直接看到一屏兜底界面，等于把当前的「安全模式」降级没了。
安全模式的价值是「App 还能用，只是隐藏网页被阻断」；把它变成恢复页是**功能倒退**。

### 为什么用 safeAreaInset 而不是 VStack 包 root

`VStack` 包住 `TabView` 会让它失去自己的安全区，可能连带影响 tab bar 布局，
风险远大于收益。`safeAreaInset`（iOS 15.0 起可用）是工程里已经在用的写法。

---

## 九、记录改写到 Documents

### 改动

- 目录从 `Library/Caches/flare-launch` 换成 `Documents/flare-launch`。
- `install()` 时对目录设置 `isExcludedFromBackup = true`。

### 理由与代价

`Caches` 是系统在低存储时会主动清理的目录，且**不需要 App 在场**。
用户崩溃后过几天才开 App，现场完全可能已经不在了。`Documents` 不会被系统清。

- `Documents` 默认会被 iCloud/iTunes 备份，日志进备份会浪费空间。
  已用 `isExcludedFromBackup` 排除。注意：**这个标记只排除备份，不阻止系统清理**
  （Documents 本来也不清）。
- 文件一直留在用户可见的 Documents 里。两个小文件、每次启动在崩溃日志开头写一行、
  阶段文件每次重置，总量 KB 级，不构成问题。
- 目前没有给用户看的「导出/删除诊断」入口。以后补一个更合适，本轮不扩散。

**明确的取舍**：Documents 能扛系统清理，但扛不住用户手动「删除 App」。任何方案都一样。

