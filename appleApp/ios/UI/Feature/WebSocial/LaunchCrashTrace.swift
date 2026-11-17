import Foundation

/// 启动期崩溃现场记录。
///
/// LaunchGuard 只能数「上次有没有走完」，不知道**为什么**没走完。拿到 .ips 之前，
/// 我们要有一份自己写的、哪怕只有一两行的现场：崩在哪个阶段、异常名、最上面几帧。
/// Crashlytics 在 `bootstrap()` 里才启用，崩在它之前的现场它一条都收不到。
///
/// 做法刻意的笨：
/// - 每个启动阶段一个编号，追加进一个单字节标记文件。崩溃时读最后那个字节，
///   就知道它倒在哪一步；哪怕崩溃日志一个字都没写进去也有效。
/// - 信号处理里只做三件事：读标记文件最后一个字节、查常量表、`write`。
///   不构造 String、不做新分配、不读 Swift 可变静态属性。
///
/// 覆盖范围：未捕获的 ObjC/Swift 异常（`NSException`）与 SIGABRT / SIGSEGV /
/// SIGBUS / SIGILL / SIGTRAP / SIGFPE。dyld 加载失败、以及早于 `main` 的 KMP
/// native 崩溃这里同样抢不到，只能靠 .ips。
enum LaunchCrashTrace {
    /// 崩溃日志的文件描述符。
    private nonisolated(unsafe) static var crashFd: Int32 = -1
    /// 启动阶段标记文件（单字节追加）。
    private nonisolated(unsafe) static var stageFd: Int32 = -1
    /// 上一次启动留下的崩溃现场（本次启动开头读到的），没有则为 nil。
    private(set) nonisolated(unsafe) static var previous: String?

    private static var cache: String { NSHomeDirectory().appending("/Library/Caches") }

    /// 在 `FlareApp.init()` 里、`LaunchGuard.begin()` 之后立刻调用，只调一次。
    static func install() {
        crashFd = open("\(cache)/flare-launch-crash.log", O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        stageFd = open("\(cache)/flare-launch-stage.log", O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)

        // 事先把信号处理要用的东西全部烘进这块常量表：两个 fd + 路径 C 串 +
        // 每种信号每个阶段的整行。信号处理只持有它，不碰任何可变静态。
        fatalTable = FatalTable(
            stagePath: "\(cache)/flare-launch-stage.log",
            crashFd: crashFd
        )

        NSSetUncaughtExceptionHandler { exception in
            // 普通线程上下文：可以用 String。
            let stack = exception.callStackSymbols.prefix(20).joined(separator: "\n    ")
            let stage = Stage.lastLoggedFromDisk()?.name ?? "before-init"
            writeLog("NSException \(exception.name.rawValue)\n  reason: \(exception.reason ?? "")\n  stage: \(stage)\n  stack:\n    \(stack)\n\n")
            // 交还默认处理，让进程照常崩掉；带着坏状态继续跑只会更难查。
            signal(SIGABRT, SIG_DFL)
            raise(SIGABRT)
        }

        // 信号处理里只用下标索引，不做查找。
        // 用 `sigaction` 而不是 `signal`：后者只接受顶层函数指针，拿不到捕获得来的状态。
        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { received in
                // 只做整数比较 + 数组索引，不调用任何 Swift 方法。
                for (position, known) in fatalSignals.enumerated() where known == received {
                    fatalTable?.write(position)
                    break
                }
                signal(received, SIG_DFL)
                raise(received)
            }
            // 空掩码：处理期间不额外屏蔽别的信号，避免二次崩溃丢失现场。
            sigemptyset(&action.sa_mask)
            // 处理完自动恢复默认动作，即使 handler 里没走到 raise 也不会卡死。
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }

        previous = readLog()
        stage(.initEntered)
    }

    /// 标记进入某个启动阶段。单字节写 + 必要时 fsync，信号安全。
    static func stage(_ stage: Stage) {
        guard stageFd >= 0 else { return }
        var byte = stage.rawValue
        _ = Darwin.write(stageFd, &byte, 1)
        // 只跨越 Kotlin 初始化前后强制落盘；每个阶段都同步会把冷启动拖慢。
        if stage.durable { _ = fcntl(stageFd, F_FULLFSYNC) }
    }

    /// 上一次启动的记录（没有则为空串），排查时直接读。
    static var lastCrash: String { previous ?? "" }

    // MARK: - 日志读写（普通线程上下文）

    private static func writeLog(_ text: String) {
        guard crashFd >= 0 else { return }
        text.withCString { _ = Darwin.write(crashFd, $0, strlen($0)) }
    }

    private static func readLog() -> String? {
        let fd = open("\(cache)/flare-launch-crash.log", O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)
    }
}

/// 信号处理用的常量表：路径 + 预先拼好的整行。构造好之后只读。
/// 不写成 `LaunchCrashTrace` 的静态属性，是为了在信号上下文里取它时不必再
/// 经过 Swift 的可变静态访问检查。
private nonisolated(unsafe) var fatalTable: FatalTable?

/// 信号处理只认这 6 个信号，下标即查表位置。
/// 放成文件级 `let`：`signalLines` 在 install 阶段就构造好，签名里再复用它，
/// 信号处理里不做任何查找。
private let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

private struct FatalTable {
    /// 同上，但挂在实例上：信号处理里不触发 `static let` 的懒初始化检查。
    let signalCount: Int

    /// `strdup` 出来的阶段文件路径，信号上下文里可直接 `open`。
    private let stagePath: UnsafeMutablePointer<CChar>
    private let crashFd: Int32
    /// 下标 = 信号在 `signalOrder` 中的位置；元素 = stage 原始值 → 整行字节。
    /// 用定长数组而不是字典：信号上下文里字典查找要走 Hasher，不安全。
    private let lines: [[[UInt8]]]

    init(stagePath: String, crashFd: Int32) {
        self.stagePath = strdup(stagePath)
        self.crashFd = crashFd
        var table: [[[UInt8]]] = []
        for sig in fatalSignals {
            var byStage: [[UInt8]] = []
            for stage in LaunchCrashTrace.Stage.allCases {
                var bytes = Array("fatal-signal sig=".utf8)
                bytes.append(UInt8(sig) / 10 + 0x30)
                bytes.append(UInt8(sig) % 10 + 0x30)
                bytes.append(contentsOf: " stage=".utf8)
                bytes.append(contentsOf: Array(stage.name.utf8))
                bytes.append(0x0A)
                byStage.append(bytes)
            }
            table.append(byStage)
        }
        lines = table
        signalCount = table.count
    }

    /// 信号上下文专用：读标记文件最后一字节 → 数组索引 → 定长写。
    /// 不做新分配、不碰 String、不查字典、不触发静态懒初始化。
    func write(_ signalIndex: Int) {
        guard signalIndex >= 0, signalIndex < signalCount else { return }

        var code = LaunchCrashTrace.Stage.none.rawValue
        var lastByte: UInt8 = 0
        let stageFd = open(stagePath, O_RDONLY)
        if stageFd >= 0 {
            let size = lseek(stageFd, 0, SEEK_END)
            if size > 0, pread(stageFd, &lastByte, 1, off_t(size - 1)) == 1 {
                code = lastByte
            }
            close(stageFd)
        }

        let byStage = lines[signalIndex]
        guard byStage.indices.contains(Int(code)) else { return }
        let line = byStage[Int(code)]
        line.withUnsafeBytes { raw in
            if crashFd >= 0 { _ = Darwin.write(crashFd, raw.baseAddress, raw.count) }
            _ = Darwin.write(STDERR_FILENO, raw.baseAddress, raw.count)
        }
    }
}

extension LaunchCrashTrace {
    /// 启动链路阶段。rawValue 会落进真机日志，改动要保证旧日志仍能读懂。
    enum Stage: UInt8, CaseIterable {
        /// 还没进任何阶段（`LaunchGuard.begin()` 之前就崩了）。
        case none = 0
        /// `FlareApp.init()`，写启动标记。
        case initEntered = 0x41
        /// `startLaunch()` 起来，判断恢复模式。
        case startLaunch = 0x42
        /// 清理 Instagram 状态（SQLite + WKWebsiteDataStore）。
        case stateIsolation = 0x43
        /// `bootstrap()` 里纯 Swift 配置（媒体缓存、音频、外观、Firebase）。
        case bootstrapConfig = 0x44
        /// `AppleSharedHelper.shared.initialize`，Kotlin 侧初始化。
        case kotlinInitialize = 0x45
        /// 主界面开始渲染。
        case rootRendering = 0x46
        /// 主界面已出现。
        case rootShown = 0x47

        var name: String {
            switch self {
            case .none: "before-init"
            case .initEntered: "app-init"
            case .startLaunch: "start-launch"
            case .stateIsolation: "state-isolation"
            case .bootstrapConfig: "bootstrap"
            case .kotlinInitialize: "kotlin-init"
            case .rootRendering: "root-render"
            case .rootShown: "root-shown"
            }
        }

        /// 这个阶段崩了是否值得立刻 fsync。
        var durable: Bool { self == .kotlinInitialize || self == .rootRendering }

        /// 从标记文件读最后一个字节（普通线程上下文用）。
        static func lastLoggedFromDisk() -> Stage? {
            let fd = open(NSHomeDirectory().appending("/Library/Caches/flare-launch-stage.log"), O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }
            return Stage(rawValue: buf[n - 1])
        }
    }
}
