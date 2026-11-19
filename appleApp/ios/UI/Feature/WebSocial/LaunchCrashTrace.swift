import Foundation
import Darwin
import MachO

/// 启动期崩溃现场记录。
///
/// LaunchGuard 只能数「上次有没有走完」，不知道**为什么**没走完。拿到 .ips 之前，
/// 我们要有一份自己写的、哪怕只有一两行的现场：崩在哪个阶段、异常名、最上面几帧。
/// Crashlytics 在 `bootstrap()` 里才启用，崩在它之前的现场它一条都收不到。
///
/// 做法刻意的笨：
/// - 每个启动阶段一个编号，追加进一个单字节标记文件。崩溃时读最后那个字节，
///   就知道它倒在哪一步；哪怕崩溃日志一个字都没写进去也有效。
/// - 信号处理里只做四件事：读标记文件最后一个字节、查常量表、`backtrace`、`write`。
///   不构造 String、不做新分配、不读 Swift 可变静态属性。
///
/// 记录写在 Documents 而不是 Caches：Caches 会被系统在低存储时清掉，而我们要的
/// 恰恰是「用户崩溃之后、还没打开 App 之前，文件还在」。Documents 另外设了
/// `isExcludedFromBackup`，不会污染 iCloud 备份。
///
/// 覆盖范围：未捕获的 ObjC/Swift 异常（`NSException`）与 SIGABRT / SIGSEGV /
/// SIGBUS / SIGILL / SIGTRAP / SIGFPE。dyld 加载失败、以及早于 `main` 的 KMP
/// native 崩溃这里同样抢不到，只能靠 .ips。watchdog 与 jetsam 是被系统直接
/// kill 的，不经过信号，也抢不到。
enum LaunchCrashTrace {
    /// 崩溃日志的文件描述符。
    private nonisolated(unsafe) static var crashFd: Int32 = -1
    /// 启动阶段标记文件（单字节追加）。
    private nonisolated(unsafe) static var stageFd: Int32 = -1
    /// 上一次启动留下的崩溃现场（本次启动开头读到的），没有则为 nil。
    private(set) nonisolated(unsafe) static var previous: String?

    /// 记录目录。Documents 下单独一层，方便整目录删。
    private static var directory: String {
        NSHomeDirectory().appending("/Documents/flare-launch")
    }

    /// 在 `FlareApp.init()` 里、`LaunchGuard.begin()` 之后立刻调用，只调一次。
    static func install() {
        // 必须赶在打开 crash.log（O_TRUNC）之前读上次现场：O_TRUNC 会立刻把文件清零，
        // 之后再 readLog() 只能读到空文件，横幅和恢复页拿到的 lastCrash 永远是空串。
        previous = readLog()

        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        excludeFromBackup(directory)

        crashFd = open("\(directory)/crash.log", O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        stageFd = open("\(directory)/stage.log", O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)

        // 事先把信号处理要用的东西全部烘进这块常量表：两个 fd + 路径 C 串 +
        // 每种信号每个阶段的整行。信号处理只持有它，不碰任何可变静态。
        fatalTable = FatalTable(
            stagePath: "\(directory)/stage.log",
            crashPath: "\(directory)/crash.log",
            crashFd: crashFd
        )

        stage(.initEntered)
        // 开头已经把上次的现场读进内存了，这里再确保文件从 0 开始写本次的。
        // 第一行写本次启动的装载基址：信号崩溃栈里是绝对地址，没这行就还原不出符号。
        if crashFd >= 0 {
            _ = ftruncate(crashFd, 0)
            _ = lseek(crashFd, 0, SEEK_SET)
        }
        writeImageBase(to: crashFd, stage: Stage.initEntered.name)

        // 预热信号路径会读到的所有文件级常量。Swift 的 `let` 全局是懒初始化的，
        // 第一次访问会走一次运行时检查；提前在这里读一遍，信号处理里就不会有第一次。
        prewarmSignalPath()

        // 等日志首行和信号路径用到的常量全部就绪后，最后才安装处理器。
        // 反过来的话，handler 已生效但 image-base 还没写、常量还没预热，
        // 这个窗口内收到信号就会在信号上下文里首次初始化全局量。
        NSSetUncaughtExceptionHandler(flareUncaughtExceptionHandler)

        // 信号处理必须是无捕获的顶层 C 函数：`sigaction` 的 `__sa_handler` 是
        // `@convention(c)` 指针，捕获了上下文的闭包根本转换不过去（编译期报错）。
        // 所以这里挂 `flareSignalHandler`，它通过文件级 `fatalTable` 取表。
        for sig in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = flareSignalHandler
            // 空掩码：处理期间不额外屏蔽别的信号，避免二次崩溃丢失现场。
            sigemptyset(&action.sa_mask)
            // 处理完自动恢复默认动作，即使 handler 里没走到 raise 也不会卡死。
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }
    }

    /// 触碰一遍信号路径上的全局量，让它们完成惰性初始化。
    /// 只有 install 阶段（普通线程上下文）调用。
    private static func prewarmSignalPath() {
        _ = fatalSignals.count
        _ = hexDigits.length
        _ = lineHeader.length
        _ = lineFooter.length
        _ = backtraceDepth
        _ = fatalTable != nil
        _ = SIG_DFL
        _ = STDERR_FILENO
        _ = F_GETFL
        _ = O_APPEND
        _ = SEEK_END
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

    /// `NSException` 路径用：可以随便分配 String。
    nonisolated fileprivate static func writeLog(header: String, reason: String, stage: String, stack: String) {
        guard crashFd >= 0 else { return }
        let text = "\(header)\n  reason: \(reason)\n  stage: \(stage)\n  stack:\n    \(stack)\n\n"
        text.withCString { _ = Darwin.write(crashFd, $0, strlen($0)) }
    }

    private static func readLog() -> String? {
        let fd = open("\(directory)/crash.log", O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: LOG_READ_LIMIT)
        let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return nil }
        return String(bytes: buf[0..<n], encoding: .utf8)
    }

    /// 整个目录排除 iCloud 备份。失败无所谓：备份里多一点日志不影响正确性。
    private static func excludeFromBackup(_ path: String) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// 信号处理用的常量表：路径 + 预先拼好的整行。构造好之后只读。
/// 不写成 `LaunchCrashTrace` 的静态属性，是为了在信号上下文里取它时不必再
/// 经过 Swift 的可变静态访问检查。
private nonisolated(unsafe) var fatalTable: FatalTable?

/// 信号处理只认这 6 个信号，下标即查表位置。
/// 放成文件级 `let`：表在 install 阶段就构造好，签名里再复用它，
/// 信号处理里不做任何查找。
private nonisolated let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

/// 信号处理器本体。
///
/// 必须是**无捕获的顶层函数**并标 `@convention(c)`：`sigaction.__sa_handler`
/// 就是 C 函数指针，捕获了上下文的闭包在编译期就转换失败。这里只能通过
/// 文件级变量 `fatalTable` 取预烘好的常量表。
///
/// 函数体内只做整数分支与 `write`/`raise`，不构造 String、
/// 不做新分配、不触发 Swift 静态懒初始化 —— 这些都是 async-signal-safe 的要求。
/// 未捕获 NSException 的处理器。
///
/// 同样是 `@convention(c)` 指针，必须是**无捕获的顶层 nonisolated 函数**——
/// 写成捕获上下文的内联闭包在 `-default-isolation=MainActor` 下会转换失败。
private nonisolated func flareUncaughtExceptionHandler(_ exception: NSException) {
    // 普通线程上下文：可以用 String。
    let stack = exception.callStackSymbols.prefix(20).joined(separator: "\n    ")
    let stage = LaunchCrashTrace.Stage.lastLoggedFromDisk()?.name ?? "before-init"
    LaunchCrashTrace.writeLog(
        header: "NSException \(exception.name.rawValue)",
        reason: exception.reason ?? "",
        stage: stage,
        stack: stack
    )
    // 交还默认处理，让进程照常崩掉；带着坏状态继续跑只会更难查。
    signal(SIGABRT, SIG_DFL)
    raise(SIGABRT)
}

private nonisolated func flareSignalHandlerImpl(_ received: Int32) {
    // 固定 switch 直接映射到预烘表的行号，不遍历 Swift 数组、不调用集合方法。
    switch received {
    case SIGABRT:
        fatalTable?.write(0)
    case SIGSEGV:
        fatalTable?.write(1)
    case SIGBUS:
        fatalTable?.write(2)
    case SIGILL:
        fatalTable?.write(3)
    case SIGTRAP:
        fatalTable?.write(4)
    case SIGFPE:
        fatalTable?.write(5)
    default:
        break
    }
    signal(received, SIG_DFL)
    raise(received)
}

private let flareSignalHandler: @convention(c) (Int32) -> Void = flareSignalHandlerImpl

/// 栈最多取多少帧。`backtrace` 本身是固定开销，只需要一块足够大的指针数组。
private nonisolated let backtraceDepth: Int32 = 64
/// 崩溃日志读取上限（字节），防止无限读。
private let LOG_READ_LIMIT: Int = 64 * 1024

private struct FatalTable {
    /// 同上，但挂在实例上：信号处理里不触发 `static let` 的懒初始化检查。
    nonisolated let signalCount: Int

    /// `strdup` 出来的阶段文件路径，信号上下文里可直接 `open`。
    /// 可选：`strdup` 只有内存耗尽才返回 nil，那时信号路径直接跳过读阶段（无害）。
    private nonisolated(unsafe) let stagePath: UnsafeMutablePointer<CChar>?
    /// 崩溃文件路径：信号处理里只用来「兜底 open 一次」，正常走 crashFd。
    private nonisolated(unsafe) let crashPath: UnsafeMutablePointer<CChar>?
    private nonisolated let crashFd: Int32

    /// 所有 `信号 × stage` 的整行，平铺在**一块**连续内存里，install 阶段一次分配。
    ///
    /// 不用嵌套 `[[[UInt8]]]`：数组在信号上下文里做下标访问会走 retain/release 和
    /// COW 检查，`withUnsafeBytes` 还可能触发桥接。这里只留下裸指针 + 固定步长，
    /// 信号处理里就是「指针 + 下标 * 步长」，没有任何 Swift 运行时参与。
    private nonisolated(unsafe) let rowBuffer: UnsafeMutablePointer<UInt8>
    private nonisolated let rowBytes: Int
    private nonisolated let stageCount: Int
    /// `rawValue → 行内 stage 下标` 的定长映射表（大小 256，直接按字节索引）。
    /// 这样信号处理里不做任何「rawValue 是否连续」的假设，也不做查找；坏字节映射到 0。
    private nonisolated(unsafe) let stageIndexByRaw: UnsafeMutablePointer<UInt8>

    init(stagePath: String, crashPath: String, crashFd: Int32) {
        self.stagePath = strdup(stagePath)
        self.crashPath = strdup(crashPath)
        self.crashFd = crashFd

        let stages = LaunchCrashTrace.Stage.allCases
        // 先按文本拼好的行量一遍，取最大值作为固定步长。
        var rows: [[UInt8]] = []
        for sig in fatalSignals {
            for stage in stages {
                var bytes = Array("fatal-signal sig=".utf8)
                bytes.append(UInt8(sig) / 10 + 0x30)
                bytes.append(UInt8(sig) % 10 + 0x30)
                bytes.append(contentsOf: " stage=".utf8)
                bytes.append(contentsOf: Array(stage.name.utf8))
                bytes.append(0x0A)
                rows.append(bytes)
            }
        }
        let stride = rows.reduce(0) { max($0, $1.count) }
        // 一次分配、零初始化；后面只写不建新数组。行尾天然是 0，兼作结束标记。
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, stride * rows.count))
        buffer.initialize(repeating: 0, count: max(1, stride * rows.count))
        for (index, row) in rows.enumerated() {
            for (offset, byte) in row.enumerated() {
                buffer[index * stride + offset] = byte
            }
        }
        self.rowBuffer = buffer
        self.rowBytes = stride
        self.stageCount = stages.count
        self.signalCount = fatalSignals.count

        // rawValue → stage 下标，256 项全覆盖；没登记过的字节一律指到 0（before-init）。
        let mapping = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        mapping.initialize(repeating: 0, count: 256)
        for (index, stage) in stages.enumerated() where index < 255 {
            mapping[Int(stage.rawValue)] = UInt8(index)
        }
        self.stageIndexByRaw = mapping
    }

    /// 信号上下文专用：读标记文件最后一字节 → 定位行 → 写整行 → 写调用栈。
    /// 不做新分配、不碰 String、不查字典、不触发静态懒初始化、不做 Swift 数组下标。
    nonisolated func write(_ signalIndex: Int) {
        guard signalIndex >= 0, signalIndex < signalCount else { return }

        var code: UInt8 = 0
        var lastByte: UInt8 = 0
        if let stagePath {
            let stageFd = open(stagePath, O_RDONLY)
            if stageFd >= 0 {
                let size = lseek(stageFd, 0, SEEK_END)
                if size > 0, pread(stageFd, &lastByte, 1, off_t(size - 1)) == 1 {
                    code = lastByte
                }
                close(stageFd)
            }
        }

        // 字节 → stage 下标：查 256 项映射表，一次索引，不做任何假设。
        let stageIndex = Int(stageIndexByRaw[Int(code)])
        let rowStart = rowBuffer + (signalIndex * stageCount + stageIndex) * rowBytes

        // crashFd 在 install 里 open 过一次；如果进程后面把它关了（或 fd 被复用），
        // 走一次 O_WRONLY|O_APPEND 兜底。open 是本函数的最后一个可失败分支。
        var fd = crashFd
        if fcntl(fd, F_GETFL) < 0, let crashPath {
            fd = open(crashPath, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        }

        // 行长度 = 到第一个 0 为止。裸指针扫，不构造 String、不建数组。
        var length = 0
        while length < rowBytes && (rowStart + length).pointee != 0 {
            length += 1
        }
        if length > 0 {
            if fd >= 0 { _ = Darwin.write(fd, rowStart, length) }
            _ = Darwin.write(STDERR_FILENO, rowStart, length)
        }
        writeBacktrace(to: fd)
    }

    /// 把当前线程调用栈写进 fd。
    ///
    /// 信号处理里**不能**调 `backtrace_symbols_fd`：它不是 async-signal-safe 的，
    /// 内部要分配内存并可能加锁。这里只用 `backtrace` 拿到一串绝对返回地址，
    /// 逐帧写成 `# NN 0x...`，全程临时缓冲，没有任何分配。
    ///
    /// 也不在这里用 `dladdr` 还原符号：它会拿 dyld 的锁，崩溃时那把锁很可能正被
    /// 别的线程持有，属于会死锁的那类调用。代价是只拿得到地址。
    ///
    /// 还原方法：崩溃日志第一行有 `image-base 0x...`（本次启动时算出来的装载基址）。
    /// 用 `atos -o Flare.app/Flare -arch arm64 -l <image-base> 0x<addr>` 还原符号。
    nonisolated private func writeBacktrace(to fd: Int32) {
        // `withUnsafeTemporaryAllocation` 给的是临时缓冲，不经过数组的堆分配
        // 和 COW 检查，正好适合信号上下文。
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: Int(backtraceDepth)) { frames in
            for index in frames.indices { frames[index] = nil }
            guard let base = frames.baseAddress else { return }
            let depth = backtrace(base, backtraceDepth)
            guard depth > 0 else { return }

            writeLiteral(lineHeader, to: fd)
            for index in 0..<min(Int(depth), frames.count) {
                guard let frame = frames[index] else { continue }
                writeFrame(frame, index: index, to: fd)
            }
            writeLiteral(lineFooter, to: fd)
        }
    }

    /// 写一帧：`# NN 0x<绝对地址>\n`。缓冲区固定 32 字节，最长用到 25 字节。
    nonisolated private func writeFrame(_ frame: UnsafeMutableRawPointer, index: Int, to fd: Int32) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { out in
            guard let base = out.baseAddress else { return }
            base[0] = 0x23  // '#'
            base[1] = 0x20
            base[2] = 0x20
            var cursor = 3
            // 帧号：两位十进制足够（最多 64 帧）。
            base[cursor] = UInt8(truncatingIfNeeded: index / 10 % 10) + 0x30
            base[cursor + 1] = UInt8(truncatingIfNeeded: index % 10) + 0x30
            cursor += 2
            base[cursor] = 0x20
            base[cursor + 1] = 0x30  // '0'
            base[cursor + 2] = 0x78  // 'x'
            cursor += 3

            let value = UInt64(UInt(bitPattern: UnsafeRawPointer(frame)))
            var started = false
            for step in stride(from: 60, through: 0, by: -4) {
                let nibble = UInt8((value >> UInt64(step)) & 0xF)
                if !started && nibble == 0 && step != 0 { continue }
                started = true
                base[cursor] = hexDigits.pointer[Int(nibble)]
                cursor += 1
            }
            base[cursor] = 0x0A
            cursor += 1

            if fd >= 0 { _ = Darwin.write(fd, base, cursor) }
            _ = Darwin.write(STDERR_FILENO, base, cursor)
        }
    }

    /// 写常量字节串（预先烘好的 `lineHeader` / `lineFooter` 缓冲区）。
    nonisolated private func writeLiteral(_ literal: StaticBytes, to fd: Int32) {
        guard literal.length > 0 else { return }
        if fd >= 0 { _ = Darwin.write(fd, literal.pointer, literal.length) }
        _ = Darwin.write(STDERR_FILENO, literal.pointer, literal.length)
    }
}

/// 一块常驻的字节串：install 阶段分配一次，信号处理里只读。
/// 用它替代 `[UInt8]`，是因为数组在信号上下文里做 `withUnsafeBytes` 会走桥接。
private struct StaticBytes: @unchecked Sendable {
    nonisolated(unsafe) let pointer: UnsafeMutablePointer<UInt8>
    nonisolated let length: Int

    nonisolated init(_ text: String) {
        let bytes = Array(text.utf8)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, bytes.count))
        buffer.initialize(repeating: 0, count: max(1, bytes.count))
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        self.pointer = buffer
        self.length = bytes.count
    }
}

/// 栈的标题行与结尾行。文件级 `let`：`install()` 一进来就会预热它们，先于任何信号。
private nonisolated let lineHeader = StaticBytes("stack:\n")
private nonisolated let lineFooter = StaticBytes("\n")
/// 十六进制字符表。裸指针常量，信号处理里下标访问不碰 Swift 数组。
private nonisolated let hexDigits = StaticBytes("0123456789abcdef")

/// 算出主二进制的运行时装载基址，写进崩溃日志开头。
/// 普通线程上下文（install 阶段）调用，可以用 Foundation 和字符串。
///
/// `_dyld_get_image_header(0)` 返回的就是主可执行文件 mach_header 在**本次运行**
/// 内存里的地址，也就是 dyld 报告的 loadAddress，不再需要额外加 slide。
/// `_dyld_get_image_vmaddr_slide(0)` 单独记一份，方便人工核对与 atos 对照。
private func writeImageBase(to fd: Int32, stage: String) {
    guard fd >= 0 else { return }
    // 返回 UnsafePointer<mach_header>?，转成整数地址再格式化。
    let header = _dyld_get_image_header(0)
    let headerAddress = header.map { UInt(bitPattern: UnsafeRawPointer($0)) } ?? 0
    let slide = _dyld_get_image_vmaddr_slide(0)
    let text = "image-base 0x\(String(headerAddress, radix: 16)) slide \(slide) stage \(stage)\n"
    text.withCString { _ = Darwin.write(fd, $0, strlen($0)) }
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

        nonisolated var name: String {
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
        nonisolated static func lastLoggedFromDisk() -> Stage? {
            let fd = open(NSHomeDirectory().appending("/Documents/flare-launch/stage.log"), O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }
            return Stage(rawValue: buf[n - 1])
        }
    }
}
