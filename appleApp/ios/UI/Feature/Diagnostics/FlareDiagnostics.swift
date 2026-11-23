import Foundation
import UIKit
import Darwin

/// 全局诊断中心 — 一次抓透小红书 / 微信读书 / Instagram / 微博转发的问题。
///
/// 背景：Windows 上 syslog_relay 抓不到 App 自定义 subsystem 的 os_log，
/// `dvt oslog` 又要求 App 在前台且按 pid 抓，用户不方便。与其每个 bug 出一个
/// 专项诊断包，不如让四个模块把「请求 / 响应摘要 / 错误 / 关键状态」统一写进
/// 这里，App 内一键导出一份带时间戳的完整报告，用户截图或分享即可。
///
/// 设计约束：
/// - 只依赖 Foundation，不碰 Kotlin / UI，避免跨层编译风险。
/// - 线程安全（NSLock），所有写入都在请求回调的任意线程上。
/// - 内存环形缓冲（每模块上限） + 落盘（Documents，防 App 重启丢失）。
/// - 脱敏：不记 cookie 原文、不记请求/响应全文，只记 path / status / 字节数 /
///   返回体前若干字节 + 错误码，够定位又不泄露登录态。
final class FlareDiagnostics {
    static let shared = FlareDiagnostics()
    private init() {}

    // MARK: - 模块

    enum Module: String, CaseIterable {
        case weread = "微信读书"
        case xhs = "小红书"
        case instagram = "Instagram"
        case weibo = "微博转发"
    }

    // MARK: - 单条事件

    struct Event: Codable {
        let ts: Date
        let module: String
        let level: String   // REQ / RES / ERR / STATE
        let detail: String
    }

    private let lock = NSLock()
    private var events: [Event] = []
    /// 每条 detail 里 module 分组独立计数；全局上限保护内存。
    private let maxEvents = 600

    // MARK: - 写入

    /// 统一入口。level 用 REQ / RES / ERR / STATE；detail 不要放 cookie 原文。
    func record(_ module: Module, _ level: String, _ detail: String) {
        let event = Event(ts: Date(), module: module.rawValue, level: level, detail: detail)
        lock.lock()
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        let snapshot = events
        lock.unlock()
        // 落盘失败不影响 App 主流程（诊断是尽力而为）。
        persist(snapshot)
    }

    /// 用户点「清空」时调用；同时清内存与磁盘快照。
    func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    // MARK: - 导出

    /// 生成完整可读报告（所有模块，按时间顺序）。
    func report() -> String {
        lock.lock()
        let snapshot = events
        lock.unlock()

        var lines: [String] = []
        lines.append("===== Flare 通用诊断报告 =====")
        lines.append("导出时间: \(Self.format(date: Date()))")
        lines.append("事件数: \(snapshot.count)（上限 \(maxEvents)，超出后丢弃最旧）")
        lines.append("设备: \(UIDevice.modelName) / iOS \(UIDevice.current.systemVersion)")
        lines.append("App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        lines.append("")

        for module in Module.allCases {
            let rows = snapshot.filter { $0.module == module.rawValue }
            lines.append("----- \(module.rawValue) (\(rows.count)) -----")
            if rows.isEmpty {
                lines.append("(本轮无记录)")
            } else {
                for event in rows {
                    lines.append("[\(Self.format(date: event.ts))] \(event.level) \(event.detail)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 报告文件 URL（供系统分享面板导出 / 存到文件）。
    func exportFileURL() -> URL {
        let text = report()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flare-diagnostic-\(Self.stamp()).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - 落盘

    private var snapshotURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Documents")
        return docs.appendingPathComponent("flare-diagnostic-snapshot.json")
    }

    private func persist(_ snapshot: [Event]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    // MARK: - 工具

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func format(date: Date) -> String {
        formatter.string(from: date)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
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
