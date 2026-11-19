# 启动崩溃现场：怎么取、怎么看

本文说明 `LaunchCrashTrace` 自己写的崩溃现场落在哪、主界面横幅是什么意思，
以及怎么从真机取 `.ips` 和这两份日志。

## 一、现场落在哪

目录固定为 App 的 Documents：

```
Documents/flare-launch/
  crash.log   本次启动的装载基址 + 崩溃时的信号/stage/调用栈
  stage.log   本次启动已经走到的阶段（单字节追加）
```

- 不用 `Library/Caches`：低存储时系统会清 Caches，用户崩溃后隔几天再开 App 就没了。
- 整个目录设置了 `isExcludedFromBackup`，不会进 iCloud/iTunes 备份。
- 每次启动都会重写这两个文件；上次的 `crash.log` 在重写前读进内存，供横幅和恢复页显示。
- 删除 App 会连同目录一起删除；目前没有单独的“导出/删除诊断”入口。

## 二、主界面横幅是什么意思

满足 `LaunchGuard.lastCrashCount >= 1` 且上次 `crash.log` 非空时，主界面顶部会出现：

```
上次启动没有完成，已进安全模式                 复制现场  展开  ×
```

- **出现条件**：上次启动没有走到“主界面已出现后进入后台”
  （`markStable()` 受 `fullUIShown` 保护，满足后才会清零崩溃计数）。
  它只说明上次没走完，**不等于已经定位到根因**。
- **复制现场**：把 `crash.log` 的完整文本放进剪贴板，用户可以直接贴回聊天窗口。
- **展开 / 收起**：展开后最多显示 140pt 高的等宽日志；默认收起，不挡主界面。
- **×**：只关掉本次运行的横幅，不删文件、不改计数。
- **进后台**：主界面已出现时，`LaunchGuard.markStable()` 清零崩溃计数；
  无论是否已清零，App 进后台都会收起横幅。
- 连续两次没走完会进恢复页（`LaunchRecoveryView`），那里显示同一份现场，也带复制按钮。

## 三、从设备取两份日志

### 方式 A：文件 App（最快）

`Info.plist` 已开启 `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`。

1. 打开“文件”App → “我的 iPhone” → “Flare”。
2. 进入 `flare-launch`，长按 `crash.log` / `stage.log` → 拷贝或共享到本机。

### 方式 B：Finder / iTunes 文件共享

1. 数据线连接设备，Mac 打开 Finder（Windows 用 iTunes / Apple Devices）。
2. 在设备页的“文件”标签里选 “Flare”。
3. 把 `flare-launch` 整个目录拖出来。

### 方式 C：Xcode 下载容器

1. Xcode → Window → Devices and Simulators → 选中设备。
2. 在 Installed Apps 里选 “Flare” → 齿轮 → Download Container。
3. 右键 `.xcappdata` → 显示包内容 → `AppData/Documents/flare-launch/`。

## 四、从设备取 `.ips`

自写日志覆盖不到 watchdog、jetsam、dyld 和 `main` 之前，`.ips` 仍然不可替代。

### 设备上直接看

1. 设置 → 隐私与安全性 → 分析与改进 → 分析数据。
2. 在列表里找 `Flare-2026-…` 开头的 `.ips`（按时间排序，找崩溃发生的那次）。
3. 点进去 → 右上角分享 → 存到“文件”/AirDrop 到电脑。

### 用 Xcode 导出

1. Xcode → Window → Devices and Simulators → 选中设备。
2. 点 “View Device Logs”，等列表加载完。
3. 找到 Flare 的崩溃条目，右键 “Export Log”，或直接拖到桌面。

### 从 Mac 的 Console 找

崩溃后设备连接 Mac，打开 Console → 左侧选设备 → 搜索 `Flare`，
崩溃报告通常位于 `~/Library/Logs/CrashReporter/MobileDevice/<设备名>/`。

## 五、`crash.log` 怎么读

信号崩溃（SIGABRT / SIGSEGV / SIGBUS / SIGILL / SIGTRAP / SIGFPE）：

```
image-base 0x102f4c000 slide 0 stage app-init
fatal-signal sig=11 stage=kotlin-init
stack:
# 00 0x102a1b2c3
# 01 0x102a1b2f7
...
```

- 第一行是**本次启动**的主二进制装载基址（PIE 每次启动都变），信号栈里是绝对地址；
  没有这行就无法还原符号。
- `stage=` 是进程倒下前最后一个启动阶段，对应关系见 `LaunchCrashTrace.Stage`：
  `before-init` / `app-init` / `start-launch` / `state-isolation` / `bootstrap` /
  `kotlin-init` / `root-render` / `root-shown`。
- `stage.log` 是同样阶段编号的原始字节流水，用来交叉验证。

未捕获的 `NSException` 走普通线程路径，写的是已经符号化的栈：

```
NSException NSInternalInconsistencyException
  reason: ...
  stage: kotlin-init
  stack:
    ...callStackSymbols...
```

## 六、用 `atos` 还原始地址

准备与设备上完全一致的 `Flare.app/Flare`（同一次构建；有 dSYM 时 `atos` 会自动使用）：

```bash
atos -o /path/to/Flare.app/Flare -l 0x102f4c000 0x102a1b2c3 0x102a1b2f7
```

- `-l` 后面就是 `image-base` 那行的十六进制值。
- 不确定架构时先省略 `-arch`；需要时再按二进制实际架构加 `-arch arm64` / `arm64e`。
- 一次可以传多个地址，把 `stack:` 下面需要的帧都带上。
- 如果拿的是 `.ips`，优先用 Xcode 的符号化结果或 `symbolicatecrash`（需 dSYM）核对。

## 七、覆盖边界

| 崩溃类型 | 自写日志 | 说明 |
|---|---|---|
| 未捕获 `NSException` | 能 | 异常名 + reason + 符号化栈 + stage |
| Swift 运行时 trap | 能 | 信号 + stage + 原始地址栈 |
| Kotlin 异常冒泡 | 多半能（SIGABRT） | 信号 + stage + 原始地址栈 |
| 主线程 watchdog（0x8badf00d） | **不能** | 系统直接 kill，不经过信号 |
| 内存耗尽（jetsam） | **不能** | 同上 |
| dyld / `main` 之前 | **不能** | 只能靠 `.ips` |

自写日志的价值是“用户一打开 App 就能复制现场”，不是替代 `.ips`。
拿到现场后先看 `stage=` 和栈顶几帧，再对照 `.ips` 的 `faultingThread` 确认。
