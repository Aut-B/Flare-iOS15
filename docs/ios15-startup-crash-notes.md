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
