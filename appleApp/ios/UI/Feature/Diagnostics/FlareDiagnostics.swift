import AVFAudio
import Darwin
import Foundation
import UIKit

/// 全局诊断中心 —— 用一个通用包一次抓透微信读书 / 小红书 / Instagram / 微博转发 /
/// 画中画并存状态。
///
/// 背景：用户明确不要「一个 bug 一个专项诊断包」。各模块把请求 / 响应摘要 /
/// 错误 / 关键状态统一写进这里，App 内先抓一次状态快照，再一次导出 zip，
/// 用户把整个 zip 分享出来即可。
///
/// 设计约束：
/// - 只依赖 Foundation / UIKit / AVFAudio，不碰 Kotlin，避免跨层编译风险。
/// - 线程安全（NSLock），写入来自任意请求回调线程。
/// - 内存环形缓冲；只有用户主动导出时才写文件，落盘内容必须脱敏，且不带
///   成功响应体（6S 存储硬约束：笔记正文、划线、想法一律不落本地）。
nonisolated final class FlareDiagnostics: @unchecked Sendable {
    static let shared = FlareDiagnostics()

    private init() {}

    // MARK: - 模块

    nonisolated enum Module: String, CaseIterable {
        case weread = "微信读书"
        case xhs = "小红书"
        case instagram = "Instagram"
        case weibo = "微博转发"
        case pip = "画中画/系统"

        var fileName: String {
            switch self {
            case .weread: return "weread.txt"
            case .xhs: return "xhs.txt"
            case .instagram: return "instagram.txt"
            case .weibo: return "weibo.txt"
            case .pip: return "pip-system.txt"
            }
        }

        var scope: String {
            switch self {
            case .weread: return "接口状态 / 笔记拉取 / 阅读进度 / 时长上报"
            case .xhs: return "取图 / 视频 / 评论 / 主页"
            case .instagram: return "登录态 / 请求状态码与错误码"
            case .weibo: return "转发请求次数 / 服务端原文"
            case .pip: return "画中画并存 / 音频会话 / 进程与存储"
            }
        }
    }

    // MARK: - 单条事件

    nonisolated struct Event: Codable {
        let ts: Date
        let module: String
        let level: String
        let detail: String
    }

    // MARK: - 状态

    private let lock = NSLock()
    private var events: [Event] = []
    private let maxEvents = 600
    private var environment = EnvironmentSnapshot()

    private nonisolated struct EnvironmentSnapshot: Sendable {
        var capturedAt: Date?
        var deviceModel = "未采集"
        var systemVersion = "?"
        var appVersion = "?"
        var appBuild = "?"
        var appState = "未采集"
        var battery = "未采集"
        var thermal = "未采集"
        var uptime = "未采集"
        var physicalMB = 0
        var footprintMB = 0
        var diskFreeMB = 0
        var diskTotalMB = 0
        var audioCategory = "未采集"
        var audioOptions = "未采集"
        var audioOutput = "未采集"
        var otherAudio = "未采集"
    }

    // MARK: - 写入

    /// 统一入口。level 用 REQ / RES / ERR / STATE；detail 不要放 cookie 原文，
    /// 即便放了也会在这里被替换成 `<redacted len=N>`。
    func record(_ module: Module, _ level: String, _ detail: String) {
        let event = Event(
            ts: Date(),
            module: module.rawValue,
            level: level,
            detail: Redaction.clean(detail)
        )
        lock.lock()
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()
        // 不自动落盘：6S 存储硬约束，诊断数据只在用户主动导出时写文件。
    }

    /// 用户点「清空」时调用；只清内存，不碰业务数据。
    func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    // MARK: - 状态快照（主线程只做轻量读取，重活在后台）

    /// 主线程只读取 UIKit 必须主线程的标量和 Store 的轻量字段；
    /// 磁盘容量、音频会话、内存统计、报告拼接全部在后台队列完成。
    private nonisolated struct SnapshotInput: Sendable {
        var capturedAt = Date()
        var deviceModel = "未采集"
        var systemVersion = "?"
        var appVersion = "?"
        var appBuild = "?"
        var appState = "未采集"
        var battery = "未采集"

        var wereadLoggedIn = false
        var wereadNicknamePresent = false
        var wereadBookCount = 0
        var wereadProgressedCount = 0
        var wereadReaderLinkCount = 0
        var wereadRecoveryText = "idle"
        var wereadLoading = false
        var wereadError: String?
        var wereadCookieLength = 0

        var xhsLoggedIn = false
        var xhsNoteCount = 0
        var xhsLoading = false
        var xhsLoadingMore = false
        var xhsHasMore = false
        var xhsLoadMoreFailed = false
        var xhsFollowing = false
        var xhsCookieLength = 0
        var xhsUserAgentLength = 0
        var xhsError: String?

        var instagramLoggedIn = false
        var instagramUserNamePresent = false
        var instagramFeedCount = 0
        var instagramLoading = false
        var instagramLoadingMore = false
        var instagramLikeOverrideCount = 0
        var instagramCookieLength = 0
        var instagramCsrfPresent = false
        var instagramUserIdPresent = false
        var instagramNeedsQuarantine = false
        var instagramSuppressAdoption = false
        var instagramEpoch = 0
        var instagramError: String?
    }

    /// 抓一次当前状态并返回报告文本。主线程只做必要的 UIKit / Store 字段读取，
    /// 磁盘遍历、音频会话查询、内存统计与报告拼接都在后台完成，避免 6S 卡死。
    @discardableResult
    func captureSnapshot() async -> String {
        let input = await MainActor.run { Self.readMainActorSnapshot() }
        return await Task.detached(priority: .utility) {
            self.apply(input)
            return self.report()
        }.value
    }

    private func apply(_ input: SnapshotInput) {
        let env = Self.collectEnvironment(from: input)
        lock.lock()
        environment = env
        lock.unlock()

        recordEnvironment(env)
        recordWereadState(input)
        recordXhsState(input)
        recordInstagramState(input)
        recordWeiboState()
    }

    /// 只在主线程调用：电量/前台状态必须走 UIKit；Store 字段只做值拷贝。
    @MainActor
    private static func readMainActorSnapshot() -> SnapshotInput {
        var input = SnapshotInput()
        input.capturedAt = Date()

        let device = UIDevice.current
        input.deviceModel = UIDevice.modelName
        input.systemVersion = device.systemVersion
        input.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        input.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        switch UIApplication.shared.applicationState {
        case .active: input.appState = "active(前台)"
        case .inactive: input.appState = "inactive(切换中)"
        case .background: input.appState = "background(后台)"
        @unknown default: input.appState = "unknown"
        }

        let batteryWasEnabled = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let charging: String
        switch device.batteryState {
        case .charging: charging = "充电中"
        case .full: charging = "已充满"
        case .unplugged: charging = "未充电"
        case .unknown: charging = "未知"
        @unknown default: charging = "未知"
        }
        device.isBatteryMonitoringEnabled = batteryWasEnabled
        input.battery = level < 0 ? "未知" : String(format: "%.0f%% · %@", level * 100, charging)

        let weread = WereadStore.shared
        let books = weread.books
        input.wereadLoggedIn = weread.isLoggedIn
        input.wereadNicknamePresent = !weread.nickname.isEmpty
        input.wereadBookCount = books.count
        input.wereadProgressedCount = books.reduce(into: 0) { count, book in
            if book.progress > 0 { count += 1 }
        }
        input.wereadReaderLinkCount = weread.readerLinks.count
        input.wereadRecoveryText = Self.recoveryText(weread.entryRecoveryState)
        input.wereadLoading = weread.isLoading
        input.wereadError = weread.errorMessage
        input.wereadCookieLength = weread.cookie.count

        let xhs = XhsStore.shared
        input.xhsLoggedIn = xhs.isLoggedIn
        input.xhsNoteCount = xhs.notes.count
        input.xhsLoading = xhs.isLoading
        input.xhsLoadingMore = xhs.isLoadingMore
        input.xhsHasMore = xhs.hasMore
        input.xhsLoadMoreFailed = xhs.loadMoreFailed
        input.xhsFollowing = xhs.following
        input.xhsCookieLength = xhs.cookie.count
        input.xhsUserAgentLength = XhsSigner.desktopUserAgent.count
        input.xhsError = xhs.errorMessage

        let instagram = InstagramStore.shared
        let service = InstagramService.shared
        input.instagramLoggedIn = instagram.isLoggedIn
        input.instagramUserNamePresent = !instagram.userName.isEmpty
        input.instagramFeedCount = instagram.feed.count
        input.instagramLoading = instagram.isLoading
        input.instagramLoadingMore = instagram.isLoadingMore
        input.instagramLikeOverrideCount = instagram.likeOverrides.count
        input.instagramCookieLength = service.cookie.count
        input.instagramCsrfPresent = !service.csrfToken.isEmpty
        input.instagramUserIdPresent = !service.userId.isEmpty
        input.instagramNeedsQuarantine = InstagramStateIsolator.needsQuarantine
        input.instagramSuppressAdoption = InstagramStateIsolator.suppressAdoptionThisLaunch
        input.instagramEpoch = InstagramStateIsolator.quarantineEpoch
        input.instagramError = instagram.errorMessage

        return input
    }

    /// 后台采集：磁盘容量、音频会话、内存占用都是可能阻塞的调用，禁止回主线程。
    private static func collectEnvironment(from input: SnapshotInput) -> EnvironmentSnapshot {
        var env = EnvironmentSnapshot()
        env.capturedAt = input.capturedAt
        env.deviceModel = input.deviceModel
        env.systemVersion = input.systemVersion
        env.appVersion = input.appVersion
        env.appBuild = input.appBuild
        env.appState = input.appState
        env.battery = input.battery

        switch ProcessInfo.processInfo.thermalState {
        case .nominal: env.thermal = "nominal"
        case .fair: env.thermal = "fair"
        case .serious: env.thermal = "serious"
        case .critical: env.thermal = "critical"
        @unknown default: env.thermal = "unknown"
        }
        env.uptime = String(format: "%.0f 分钟", ProcessInfo.processInfo.systemUptime / 60)
        env.physicalMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
        env.footprintMB = Self.footprintMB()
        let disk = Self.diskMB()
        env.diskFreeMB = disk.free
        env.diskTotalMB = disk.total

        let audio = AVAudioSession.sharedInstance()
        env.audioCategory = audio.category.rawValue
        env.audioOptions = Self.describe(options: audio.categoryOptions)
        env.audioOutput = audio.currentRoute.outputs.first?.portType.rawValue ?? "无"
        env.otherAudio = audio.isOtherAudioPlaying ? "是" : "否"
        return env
    }

    private func recordEnvironment(_ env: EnvironmentSnapshot) {
        record(.pip, "STATE", "环境 · \(env.deviceModel) · iOS \(env.systemVersion) · App \(env.appVersion)(\(env.appBuild))")
        record(.pip, "STATE", "应用 · \(env.appState) · 运行 \(env.uptime) · 热状态 \(env.thermal) · 电量 \(env.battery)")
        record(.pip, "STATE", "内存 · 物理 \(env.physicalMB)MB · 占用 \(env.footprintMB)MB · 磁盘剩余 \(env.diskFreeMB)MB/\(env.diskTotalMB)MB")
        record(.pip, "STATE", "音频 · category=\(env.audioCategory) · options=\(env.audioOptions) · 输出=\(env.audioOutput) · 其他音频=\(env.otherAudio)")
        record(.pip, "STATE", "画中画 · App 未使用原生 AVPictureInPictureController；并存状态按音频会话/前后台/内存判断")
    }

    private func recordWereadState(_ input: SnapshotInput) {
        record(
            .weread, "STATE",
            "书架 · 登录=\(Self.onOff(input.wereadLoggedIn)) · 昵称=\(input.wereadNicknamePresent ? "有" : "空") · 书 \(input.wereadBookCount) 本 · 进度>0 \(input.wereadProgressedCount) 本 · 阅读器链接 \(input.wereadReaderLinkCount) 条"
        )
        record(
            .weread, "STATE",
            "恢复态 · \(input.wereadRecoveryText) · 加载中=\(Self.onOff(input.wereadLoading)) · 错误=\(input.wereadError ?? "无")"
        )
        record(
            .weread, "STATE",
            "凭据 · cookie=\(input.wereadCookieLength == 0 ? "无" : "\(input.wereadCookieLength)字符")"
        )

        let rows = snapshotEvents().filter { $0.module == Module.weread.rawValue }
        let notes = rows.filter { Self.isNoteRequest($0.detail) }.count
        let duration = rows.filter { Self.isDurationLine($0.detail) }.count
        let progress = rows.filter { $0.detail.localizedCaseInsensitiveContains("progress") }.count
        record(
            .weread, "STATE",
            "本轮 · 事件 \(rows.count) 条 · 笔记接口 \(notes) 条 · 进度相关 \(progress) 条 · 时长上报 \(duration) 条"
        )
    }

    private func recordXhsState(_ input: SnapshotInput) {
        record(
            .xhs, "STATE",
            "首页 · 登录=\(Self.onOff(input.xhsLoggedIn)) · 笔记 \(input.xhsNoteCount) 条 · 加载中=\(Self.onOff(input.xhsLoading)) · 更多中=\(Self.onOff(input.xhsLoadingMore)) · hasMore=\(Self.onOff(input.xhsHasMore)) · 加载更多失败=\(Self.onOff(input.xhsLoadMoreFailed)) · 关注流=\(Self.onOff(input.xhsFollowing))"
        )
        record(
            .xhs, "STATE",
            "凭据 · cookie=\(input.xhsCookieLength == 0 ? "无" : "\(input.xhsCookieLength)字符") · UA=\(input.xhsUserAgentLength == 0 ? "空" : "\(input.xhsUserAgentLength)字符") · 错误=\(input.xhsError ?? "无")"
        )
    }

    private func recordInstagramState(_ input: SnapshotInput) {
        record(
            .instagram, "STATE",
            "时间线 · 登录=\(Self.onOff(input.instagramLoggedIn)) · 用户=\(input.instagramUserNamePresent ? "有" : "空") · feed \(input.instagramFeedCount) 条 · 加载中=\(Self.onOff(input.instagramLoading)) · 更多中=\(Self.onOff(input.instagramLoadingMore)) · 点赞覆盖 \(input.instagramLikeOverrideCount)"
        )
        record(
            .instagram, "STATE",
            "会话 · cookie=\(input.instagramCookieLength == 0 ? "无" : "\(input.instagramCookieLength)字符") · csrf=\(input.instagramCsrfPresent ? "有" : "无") · userId=\(input.instagramUserIdPresent ? "有" : "无") · 需要隔离=\(Self.onOff(input.instagramNeedsQuarantine)) · 本次抑制收养=\(Self.onOff(input.instagramSuppressAdoption)) · epoch=\(input.instagramEpoch)"
        )
        record(.instagram, "STATE", "失败态 · \(input.instagramError ?? "无")")
    }

    private func recordWeiboState() {
        let rows = snapshotEvents().filter { $0.module == Module.weibo.rawValue }
        let successes = rows.filter { $0.level == "RES" }.count
        let failures = rows.filter { $0.level == "ERR" }.count
        record(
            .weibo, "STATE",
            "本轮写操作 · 成功 \(successes) 次 · 失败 \(failures) 次 · 总 \(successes + failures) 次（一次点击只应产生一条记录）"
        )
    }

    // MARK: - 报告

    /// 屏幕预览 / 复制用。纯内存拼接，不做 I/O；detail 已在写入时脱敏。
    func report() -> String {
        buildReport(diskSafe: false)
    }

    /// 清空后重算报告；拼接放后台，避免卡住诊断页。
    func currentReport() async -> String {
        await Task.detached(priority: .utility) {
            self.report()
        }.value
    }

    /// 写入磁盘 / zip 用。成功响应体不落盘，避免带出笔记正文。
    func exportText() async -> String {
        await Task.detached(priority: .userInitiated) {
            self.buildExportText()
        }.value
    }

    private func buildExportText() -> String {
        buildReport(diskSafe: true)
    }

    private func buildReport(diskSafe: Bool) -> String {
        let formatter = Self.makeFormatter()
        let snapshot = snapshotEvents()
        let env = environmentCopy()

        var lines: [String] = []
        lines.append("===== Flare 通用诊断报告 =====")
        lines.append("导出时间: \(formatter.string(from: Date()))")
        lines.append("事件数: \(snapshot.count)（上限 \(maxEvents)，超出丢弃最旧）")
        lines.append("App: \(Self.appVersionText())")
        lines.append("设备: \(env.deviceModel) / iOS \(env.systemVersion)")
        lines.append("脱敏: cookie / token / 会话 id 一律替换为 <redacted>，不输出明文。")
        lines.append("存储: 导出文件不含成功响应体，只保留方法 / 路径 / 状态码 / 字节数 / 错误原因；笔记正文不落盘。")
        lines.append("覆盖: 微信读书·小红书·Instagram·微博转发·画中画/系统。")
        lines.append("")

        for module in Module.allCases {
            lines.append(contentsOf: summaryLines(for: module, in: snapshot, formatter: formatter))
            if !snapshot.isEmpty {
                let rows = snapshot.filter { $0.module == module.rawValue }
                if !rows.isEmpty {
                    lines.append("")
                    lines.append("----- \(module.rawValue) 全量事件 -----")
                    for event in rows {
                        let detail = diskSafe ? Redaction.diskSafe(level: event.level, detail: event.detail) : event.detail
                        lines.append("[\(formatter.string(from: event.ts))] \(event.level) \(detail)")
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func summaryLines(
        for module: Module,
        in snapshot: [Event],
        formatter: DateFormatter
    ) -> [String] {
        let rows = snapshot.filter { $0.module == module.rawValue }
        var lines = ["----- \(module.rawValue) (\(rows.count)) · \(module.scope) -----"]
        guard !rows.isEmpty else {
            lines.append("(本轮无记录)")
            return lines
        }

        let counts = Dictionary(grouping: rows, by: \.level).mapValues(\.count)
        lines.append(
            "分级: " + ["REQ", "RES", "ERR", "STATE"]
                .map { "\($0) \(counts[$0] ?? 0)" }
                .joined(separator: " / ")
        )

        if module == .weibo {
            lines.append(contentsOf: weiboSummary(rows, formatter: formatter))
        } else {
            let tallies = requestTallies(rows)
            if !tallies.isEmpty {
                lines.append("请求:")
                for item in tallies.prefix(12) {
                    lines.append("  \(item.key) × \(item.count)")
                }
            }
        }

        let errors = rows.filter { $0.level == "ERR" }
        if !errors.isEmpty {
            lines.append("错误（共 \(errors.count)，最近 \(min(errors.count, 10)) 条）:")
            for event in errors.suffix(10) {
                lines.append("  [\(formatter.string(from: event.ts))] \(Redaction.diskSafe(level: event.level, detail: event.detail))")
            }
        }

        let states = rows.filter { $0.level == "STATE" }
        if !states.isEmpty {
            lines.append("状态（共 \(states.count)，最近 \(min(states.count, 20)) 条）:")
            for event in states.suffix(20) {
                lines.append("  [\(formatter.string(from: event.ts))] \(Redaction.diskSafe(level: event.level, detail: event.detail))")
            }
        }
        return lines
    }

    private func weiboSummary(_ rows: [Event], formatter: DateFormatter) -> [String] {
        let successes = rows.filter { $0.level == "RES" }.count
        let failures = rows.filter { $0.level == "ERR" }.count
        let gaps = rows.compactMap { Self.gapSeconds(from: $0.detail) }

        var line = "写操作: 成功 \(successes) 次 · 失败 \(failures) 次 · 总 \(successes + failures) 次"
        if let minGap = gaps.min(), let maxGap = gaps.max() {
            line += String(format: " · 间隔 最小 %.1fs / 最大 %.1fs", minGap, maxGap)
        }
        if let last = gaps.last {
            line += String(format: " / 最近 %.1fs", last)
        }
        var lines = [line]
        lines.append("判读: 一次点击只应产生一条记录；短间隔（<8s）连续失败更可能是账号/会话被风控，而不是客户端重发。")

        let recentFailures = rows.filter { $0.level == "ERR" }.suffix(5)
        if !recentFailures.isEmpty {
            lines.append("服务端原文（最近 \(recentFailures.count) 条）:")
            for event in recentFailures {
                lines.append("  [\(formatter.string(from: event.ts))] \(Redaction.diskSafe(level: event.level, detail: event.detail))")
            }
        }
        return lines
    }

    /// 单模块明细，供 zip 内的 weread.txt / xhs.txt 等使用。
    func moduleText(_ module: Module) -> String {
        let formatter = Self.makeFormatter()
        let snapshot = snapshotEvents()
        var lines: [String] = []
        lines.append("===== \(module.rawValue) 诊断明细 =====")
        lines.append("范围: \(module.scope)")
        lines.append("导出时间: \(formatter.string(from: Date()))")
        lines.append("")
        lines.append(contentsOf: summaryLines(for: module, in: snapshot, formatter: formatter))
        lines.append("")
        lines.append("----- 全量事件（响应体不落盘） -----")
        let rows = snapshot.filter { $0.module == module.rawValue }
        if rows.isEmpty {
            lines.append("(本轮无记录)")
        }
        for event in rows {
            let detail = Redaction.diskSafe(level: event.level, detail: event.detail)
            lines.append("[\(formatter.string(from: event.ts))] \(event.level) \(detail)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 导出

    /// 报告文件 URL（纯文本，作为 zip 失败时的兜底）；写盘在后台完成。
    func exportFileURL() async -> URL {
        await Task.detached(priority: .userInitiated) {
            self.exportFileURLSync()
        }.value
    }

    private func exportFileURLSync() -> URL {
        let directory = FileManager.default.temporaryDirectory
        cleanOldExports(in: directory)
        let url = directory.appendingPathComponent("flare-diag-\(Self.stamp()).txt")
        try? buildExportText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 通用诊断 zip。返回 nil 表示写入失败，调用方可退回纯文本；生成与写盘在后台。
    func exportZip() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            self.exportZipSync()
        }.value
    }

    private func exportZipSync() -> URL? {
        let directory = FileManager.default.temporaryDirectory
        cleanOldExports(in: directory)
        let url = directory.appendingPathComponent("flare-diag-\(Self.stamp()).zip")
        let entries: [(name: String, data: Data)] = [
            ("README.txt", Data(readmeText().utf8)),
            ("report.txt", Data(buildExportText().utf8)),
            ("device.txt", Data(deviceText().utf8)),
            ("weread.txt", Data(moduleText(.weread).utf8)),
            ("xhs.txt", Data(moduleText(.xhs).utf8)),
            ("instagram.txt", Data(moduleText(.instagram).utf8)),
            ("weibo.txt", Data(moduleText(.weibo).utf8)),
            ("pip-system.txt", Data(moduleText(.pip).utf8)),
        ]
        let archive = Self.zip(entries: entries, date: Date())
        guard (try? archive.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private func readmeText() -> String {
        """
        Flare 通用诊断包
        ================
        一次抓透五类问题，不再每个 bug 出一个专项包：
          1. 微信读书：接口状态码 / 笔记拉取 / 阅读进度 / 时长上报
          2. 小红书：取图 / 视频 / 评论 / 主页
          3. Instagram：登录态 / 请求状态码与错误码
          4. 微博：转发请求次数 / 服务端返回原文
          5. 画中画/系统：音频会话、前后台、内存、磁盘、温升

        目录
        ----
        README.txt     本说明
        report.txt     总报告（各模块汇总 + 全量事件）
        device.txt     设备 / 系统 / 画中画并存状态
        weread.txt     微信读书
        xhs.txt        小红书
        instagram.txt  Instagram
        weibo.txt      微博转发
        pip-system.txt 画中画 / 系统事件

        脱敏与存储
        ----------
        - cookie、xsec_token、csrf、sessionid、st 等凭据字段统一替换为 <redacted>。
        - 长 hex / base64 串（可能是 token 或对象 id）同样替换为 <redacted>。
        - 写入磁盘的只有诊断文本；成功响应体一律不落盘，只保留方法/路径/状态码/字节数。
        - 笔记、划线、想法正文不会进入本 zip，App 也不在本地保存这些内容。

        覆盖与缺口
        ----------
        覆盖：微读接口/笔记/进度/时长、小红书取图/视频/评论/主页、IG 登录与请求、微博写操作、PiP 并存环境。
        缺口：微博只有「写操作成功/失败」回调级记录，没有逐请求 POST 日志；
              App 未使用原生 AVPictureInPictureController，因此没有系统 PiP 生命周期事件。

        怎么用
        ------
        先在 App 里复现一次（微读翻一章、小红书点开评论、微博连转两次），
        再回诊断页点「抓当前状态快照」和「导出诊断 zip」，把整个 zip 发给开发者。
        """
    }

    private func deviceText() -> String {
        let formatter = Self.makeFormatter()
        let env = environmentCopy()
        var lines = ["===== 设备 / 系统 / 画中画并存状态 ====="]
        lines.append("采集时间: \(env.capturedAt.map { formatter.string(from: $0) } ?? "未采集（请点『抓当前状态快照』）")")
        lines.append("机型: \(env.deviceModel) · 系统: iOS \(env.systemVersion) · App: \(env.appVersion)(\(env.appBuild))")
        lines.append("应用状态: \(env.appState) · 运行时长: \(env.uptime) · 热状态: \(env.thermal)")
        lines.append("电量: \(env.battery)")
        lines.append("内存: 物理 \(env.physicalMB)MB · 占用 \(env.footprintMB)MB · 磁盘剩余 \(env.diskFreeMB)MB/\(env.diskTotalMB)MB")
        lines.append("音频: category=\(env.audioCategory) · options=\(env.audioOptions) · 输出=\(env.audioOutput) · 其他音频=\(env.otherAudio)")
        lines.append("PiP: App 未使用原生 AVPictureInPictureController；并存问题按音频会话/前后台/内存/温升复现。")
        lines.append("")
        lines.append("----- 画中画/系统 全量事件（响应体不落盘） -----")
        let rows = snapshotEvents().filter { $0.module == Module.pip.rawValue }
        if rows.isEmpty {
            lines.append("(本轮无记录)")
        }
        for event in rows {
            let detail = Redaction.diskSafe(level: event.level, detail: event.detail)
            lines.append("[\(formatter.string(from: event.ts))] \(event.level) \(detail)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func cleanOldExports(in directory: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for item in items {
            let name = item.lastPathComponent
            guard name.hasPrefix("flare-diag-") || name.hasPrefix("flare-diagnostic-") else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - 统计工具

    private nonisolated struct Tally {
        let key: String
        let count: Int
    }

    private func snapshotEvents() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func environmentCopy() -> EnvironmentSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return environment
    }

    private func requestTallies(_ rows: [Event]) -> [Tally] {
        var counts: [String: Int] = [:]
        for event in rows where event.level == "REQ" || event.level == "RES" || event.level == "ERR" {
            guard let key = Self.requestKey(event.detail) else { continue }
            counts[key, default: 0] += 1
        }
        return counts
            .map { Tally(key: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private static func requestKey(_ detail: String) -> String? {
        guard let arrow = detail.range(of: " → ") else { return nil }
        let head = detail[..<arrow.lowerBound]
        let parts = head.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = parts[1].split(separator: "?").first.map(String.init) ?? String(parts[1])
        let status = detail[arrow.upperBound...].prefix(3)
        return "\(parts[0]) \(path) → \(status)"
    }

    private static func gapSeconds(from detail: String) -> Double? {
        guard let range = detail.range(of: "距上次 ") else { return nil }
        let rest = detail[range.upperBound...]
        let number = rest.prefix { $0.isNumber || $0 == "." }
        guard !number.isEmpty else { return nil }
        return Double(number)
    }

    private static func isNoteRequest(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("bookmark") || lowered.contains("review") || lowered.contains("note")
    }

    private static func isDurationLine(_ detail: String) -> Bool {
        detail.hasPrefix("read ") || detail.contains("rt=") || detail.contains("时长")
    }

    // MARK: - 环境工具

    private static func onOff(_ value: Bool) -> String {
        value ? "是" : "否"
    }

    private static func recoveryText(_ state: WereadEntryRecoveryState) -> String {
        switch state {
        case .idle: return "idle"
        case .recovering: return "恢复中"
        case .restored: return "已恢复"
        case .needsLogin: return "需要登录"
        case .unreachable: return "暂时不可达"
        }
    }

    private static func appVersionText() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (build \(build))"
    }

    private static func describe(options: AVAudioSession.CategoryOptions) -> String {
        var names = ["raw=\(options.rawValue)"]
        if options.contains(.mixWithOthers) { names.append("mixWithOthers") }
        if options.contains(.duckOthers) { names.append("duckOthers") }
        if options.contains(.defaultToSpeaker) { names.append("defaultToSpeaker") }
        return names.joined(separator: " ")
    }

    private static func footprintMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }

    private static func diskMB() -> (free: Int, total: Int) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        ) else { return (0, 0) }
        let free = Int((values.volumeAvailableCapacityForImportantUsage ?? 0) / 1024 / 1024)
        let total = Int((values.volumeTotalCapacity ?? 0) / 1024 / 1024)
        return (free, total)
    }

    // MARK: - 时间

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - 最小 STORED zip（不引入第三方依赖）

    private static func zip(entries: [(name: String, data: Data)], date: Date) -> Data {
        var archive = Data()
        var central = Data()
        let stamp = dosStamp(date)

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(archive.count)
            let size = UInt32(entry.data.count)

            archive.appendUInt32(0x0403_4b50)
            archive.appendUInt16(20)
            archive.appendUInt16(0x0800)
            archive.appendUInt16(0)
            archive.appendUInt16(stamp.time)
            archive.appendUInt16(stamp.date)
            archive.appendUInt32(crc)
            archive.appendUInt32(size)
            archive.appendUInt32(size)
            archive.appendUInt16(UInt16(nameData.count))
            archive.appendUInt16(0)
            archive.append(nameData)
            archive.append(entry.data)

            central.appendUInt32(0x0201_4b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0x0800)
            central.appendUInt16(0)
            central.appendUInt16(stamp.time)
            central.appendUInt16(stamp.date)
            central.appendUInt32(crc)
            central.appendUInt32(size)
            central.appendUInt32(size)
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(offset)
            central.append(nameData)
        }

        let centralOffset = UInt32(archive.count)
        let centralSize = UInt32(central.count)
        archive.append(central)
        archive.appendUInt32(0x0605_4b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt32(centralSize)
        archive.appendUInt32(centralOffset)
        archive.appendUInt16(0)
        return archive
    }

    private static func dosStamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let comps = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = max(1980, comps.year ?? 1980)
        let month = min(max(1, comps.month ?? 1), 12)
        let day = min(max(1, comps.day ?? 1), 31)
        let time = UInt16(
            ((comps.hour ?? 0) << 11) | ((comps.minute ?? 0) << 5) | ((comps.second ?? 0) / 2)
        )
        let dateValue = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (time, dateValue)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - 脱敏

    private nonisolated enum Redaction {
        private static let sensitiveKeys: [String] = [
            "cookie", "set-cookie", "xsec_token", "xsec_source", "csrf", "csrf_token",
            "csrftoken", "sessionid", "web_session", "sess", "auth", "access_token",
            "refresh_token", "token", "st", "ticket", "sign", "signature", "_signature",
            "w_rid", "x-xsrf-token", "xsrf-token", "authorization",
        ]
        private static let safeValues: Set<String> = ["有", "无", "空", "是", "否", "未知"]

        static func clean(_ text: String) -> String {
            var result = maskKeyValues(text)
            result = maskLongTokens(result)
            if result.count > 900 {
                result = String(result.prefix(900)) + " …<截断>"
            }
            return result
        }

        /// 落盘用：成功/状态事件去掉响应体预览，错误事件保留（截断）以便看服务端原文。
        static func diskSafe(level: String, detail: String) -> String {
            let trimmed = level == "ERR" ? detail : stripBodyPreview(detail)
            if trimmed.count > 600 {
                return String(trimmed.prefix(600)) + " …<截断>"
            }
            return trimmed
        }

        private static func stripBodyPreview(_ detail: String) -> String {
            guard let arrow = detail.range(of: " → ") else { return detail }
            let afterArrow = detail[arrow.upperBound...]
            guard let bodyStart = afterArrow.firstIndex(where: { $0 == "{" || $0 == "[" || $0 == "<" }) else {
                return detail
            }
            let kept = detail[..<bodyStart].trimmingCharacters(in: .whitespaces)
            return kept + " <响应体不落盘>"
        }

        private static func maskKeyValues(_ text: String) -> String {
            var ranges: [Range<String.Index>] = []
            for key in sensitiveKeys {
                var searchStart = text.startIndex
                while searchStart < text.endIndex,
                      let found = text.range(
                        of: key,
                        options: [.caseInsensitive],
                        range: searchStart..<text.endIndex
                      ) {
                    let afterKey = found.upperBound
                    if found.lowerBound > text.startIndex {
                        let previous = text[text.index(before: found.lowerBound)]
                        if previous.isLetter || previous.isNumber || previous == "_" {
                            searchStart = afterKey
                            continue
                        }
                    }
                    var separatorIndex = afterKey
                    while separatorIndex < text.endIndex, text[separatorIndex] == " " {
                        separatorIndex = text.index(after: separatorIndex)
                    }
                    // JSON: `"xsec_token":"..."`，键后面先有一个引号，再是冒号。
                    if separatorIndex < text.endIndex,
                       text[separatorIndex] == "\"" || text[separatorIndex] == "'" {
                        separatorIndex = text.index(after: separatorIndex)
                        while separatorIndex < text.endIndex, text[separatorIndex] == " " {
                            separatorIndex = text.index(after: separatorIndex)
                        }
                    }
                    guard separatorIndex < text.endIndex else { break }
                    let separator = text[separatorIndex]
                    guard separator == "=" || separator == ":" else {
                        searchStart = afterKey
                        continue
                    }
                    var valueStart = text.index(after: separatorIndex)
                    while valueStart < text.endIndex, text[valueStart] == " " {
                        valueStart = text.index(after: valueStart)
                    }
                    if valueStart < text.endIndex,
                       text[valueStart] == "\"" || text[valueStart] == "'" {
                        valueStart = text.index(after: valueStart)
                    }
                    var valueEnd = valueStart
                    while valueEnd < text.endIndex, !isValueDelimiter(text[valueEnd]) {
                        valueEnd = text.index(after: valueEnd)
                    }
                    var finalEnd = valueEnd
                    // `Authorization: Bearer <token>`：空格后的 JWT 也一起盖掉。
                    if key == "authorization", text[valueStart..<valueEnd].lowercased() == "bearer" {
                        var tokenStart = valueEnd
                        while tokenStart < text.endIndex, text[tokenStart] == " " {
                            tokenStart = text.index(after: tokenStart)
                        }
                        var tokenEnd = tokenStart
                        while tokenEnd < text.endIndex, !isValueDelimiter(text[tokenEnd]) {
                            tokenEnd = text.index(after: tokenEnd)
                        }
                        if tokenEnd > tokenStart { finalEnd = tokenEnd }
                    }
                    let value = text[valueStart..<finalEnd]
                    if !isSafeDescriptor(value), finalEnd > valueStart {
                        ranges.append(valueStart..<finalEnd)
                    }
                    searchStart = finalEnd
                }
            }
            guard !ranges.isEmpty else { return text }

            let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
            var merged: [Range<String.Index>] = []
            for range in sorted {
                if let last = merged.last, range.lowerBound < last.upperBound {
                    if range.upperBound > last.upperBound {
                        merged[merged.count - 1] = last.lowerBound..<range.upperBound
                    }
                } else {
                    merged.append(range)
                }
            }
            var result = text
            for range in merged.reversed() {
                let length = result.distance(from: range.lowerBound, to: range.upperBound)
                result.replaceSubrange(range, with: "<redacted len=\(length)>")
            }
            return result
        }

        private static func maskLongTokens(_ text: String) -> String {
            var result = ""
            result.reserveCapacity(text.count)
            var run = ""

            func flush() {
                guard !run.isEmpty else { return }
                if isLikelyToken(run) {
                    result += "<redacted len=\(run.count)>"
                } else {
                    result += run
                }
                run.removeAll(keepingCapacity: true)
            }

            for character in text {
                if isTokenCharacter(character) {
                    run.append(character)
                } else {
                    flush()
                    result.append(character)
                }
            }
            flush()
            return result
        }

        private static func isLikelyToken(_ run: String) -> Bool {
            guard run.count >= 24 else { return false }
            if run.allSatisfy({ $0.isHexDigit }) { return true }
            guard run.count >= 32 else { return false }
            let hasUpper = run.contains { $0.isUppercase }
            let hasLower = run.contains { $0.isLowercase }
            let hasDigit = run.contains { $0.isNumber }
            return (hasUpper && hasLower && hasDigit) || (hasUpper && hasDigit) || (hasLower && hasDigit)
        }

        private static func isTokenCharacter(_ character: Character) -> Bool {
            // 不把 "/" 算进 token：否则 /web/book/chapter/e_xxx 这类长路径会被
            // 当成 base64 串整段替换，诊断里就看不到请求路径了。
            character.isLetter || character.isNumber || character == "+"
        }

        private static func isValueDelimiter(_ character: Character) -> Bool {
            character == " " || character == "\n" || character == "\t"
                || character == "," || character == ";" || character == "&"
                || character == "·" || character == "\"" || character == "'"
                || character == ")" || character == "]" || character == "}"
        }

        private static func isSafeDescriptor(_ value: Substring) -> Bool {
            if value.isEmpty { return true }
            if safeValues.contains(String(value)) { return true }
            if value.hasSuffix("字符") { return true }
            if value.count <= 5 && value.allSatisfy({ $0.isNumber }) { return true }
            return false
        }
    }
}

// MARK: - 设备型号（纯 UIKit 即可，不引入额外依赖）

private extension UIDevice {
    static var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? current.model : identifier
    }
}

// MARK: - zip 小端写入

private extension Data {
    nonisolated mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    nonisolated mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
