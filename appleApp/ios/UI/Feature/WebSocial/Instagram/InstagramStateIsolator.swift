import Foundation
import SQLite3
import WebKit

nonisolated enum InstagramStateIsolator: @unchecked Sendable {
    static let quarantineEpoch = 5
    static let quarantinePendingKey = "flare.instagram.quarantine.pending"

    private static let epochKey = "flare.instagram.quarantine.epoch"
    private static let forceKey = "flare.instagram.quarantine.force"
    private static var defaults: UserDefaults { .standard }

    nonisolated private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var suppressed = false

        nonisolated func isSuppressed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return suppressed
        }

        nonisolated func setSuppressed(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            suppressed = value
        }
    }

    nonisolated static func shouldQuarantine(epoch: Int, force: Bool) -> Bool {
        force || epoch < quarantineEpoch
    }

    private static let state = State()

    /// 清理（异步删 WKWebsiteDataStore）和「主界面已出现」这两件事谁先到不确定，
    /// 只有两者都完成后才能清掉 pending 标记。
    ///
    /// 之前用一个裸 `Bool`，`markFullUIShown()` 通常在清理回调之前就执行了，
    /// `guard quarantineCompleted` 直接早退，pending 永远留着；于是之后每次冷启动
    /// 都会重新跑一遍 `purgeInstagramState()`，把 DbAccount 里的 Instagram 账号
    /// 删掉一次 —— 表现就是「每次打开都提示 Instagram 登录已失效」、
    /// 「设置里登录成功但标签页里没有这个账号」。
    nonisolated private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var purgeCompleted = true
        private var fullUIShown = false

        nonisolated func beginPurge() {
            lock.lock()
            defer { lock.unlock() }
            purgeCompleted = false
            fullUIShown = false
        }

        /// 返回 true 表示主界面已经出现过，可以清 pending。
        nonisolated func completePurge() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            purgeCompleted = true
            return fullUIShown
        }

        /// 返回 true 表示清理已经跑完，可以清 pending。
        nonisolated func markFullUIShown() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            fullUIShown = true
            return purgeCompleted
        }
    }

    nonisolated private static let progress = Progress()

    nonisolated static var needsQuarantine: Bool {
        shouldQuarantine(
            epoch: defaults.integer(forKey: epochKey),
            force: defaults.bool(forKey: forceKey)
        ) || defaults.bool(forKey: quarantinePendingKey)
    }

    nonisolated static var suppressAdoptionThisLaunch: Bool {
        state.isSuppressed()
    }

    nonisolated static func allowAdoptionThisLaunch() {
        state.setSuppressed(false)
    }

    nonisolated static func requestQuarantineOnNextLaunch() {
        defaults.set(true, forKey: forceKey)
    }

    nonisolated static func clearQuarantinePending() {
        defaults.removeObject(forKey: quarantinePendingKey)
    }

    @discardableResult
    nonisolated static func quarantineIfNeeded() -> Bool {
        guard needsQuarantine else { return false }
        purgeInstagramState()
        return true
    }

    nonisolated private static func purgeInstagramState() {
        state.setSuppressed(true)
        progress.beginPurge()

        purgeUserDefaults()
        purgeSharedHTTPCookies()
        purgeDatabase()

        defaults.set(quarantineEpoch, forKey: epochKey)
        defaults.set(false, forKey: forceKey)
        defaults.set(true, forKey: quarantinePendingKey)
        purgeWebsiteData()
    }

    nonisolated static func clearQuarantinePendingOnFullUI() {
        if progress.markFullUIShown() {
            clearQuarantinePending()
        }
    }

    nonisolated private static func purgeUserDefaults() {
        defaults.removeObject(forKey: "instagram.cookie")
        defaults.removeObject(forKey: "instagram.username")
    }

    nonisolated private static func purgeSharedHTTPCookies() {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where isInstagramDomain(cookie.domain) {
            storage.deleteCookie(cookie)
        }
    }

    nonisolated static func executeSQL(at path: String, _ sql: String) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else {
            sqlite3_close(database)
            return
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    nonisolated static func purgeDatabase(at path: String) {
        executeSQL(
            at: path,
            """
            DELETE FROM DbAccount
            WHERE platform_type = 'Instagram'
               OR account_key LIKE '%instagram.com';
            """
        )
        // 任何平台都可能留下半截 JSON（写入时被杀进程 / 覆盖安装）。这种行会在
        // Kotlin 侧 decode 时抛异常，而异常发生在协程里就是整个进程 abort ——
        // 也就是「登录一次以后再也打不开」。顺手一起清掉，只清坏行。
        executeSQL(
            at: path,
            """
            DELETE FROM DbAccount
            WHERE json_valid(credential_json) = 0;
            """
        )
        executeSQL(at: path, "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    nonisolated private static func purgeDatabase() {
        guard let root = applicationSupportDirectory() else { return }
        let directory = root.appendingPathComponent("databases", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("app.db", isDirectory: false).path
        guard FileManager.default.fileExists(atPath: path) else { return }
        purgeDatabase(at: path)
    }

    nonisolated private static func purgeWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let cookieStore = store.httpCookieStore
        // 兜底：WK 的两个回调在坏状态（数据库损坏 / WebKit 进程卡死）下可能永远不返回。
        // 之前 pending 标记就永远清不掉，于是每次冷启动都重新删一次 Instagram 账号，
        // 表现是「登录成功但标签页里没有账号」「每次都提示登录已失效」。
        // 这里最多等 10 秒，超时也当作清理完成，保证只隔离一次。
        let fallback = DispatchWorkItem {
            _ = progress.completePurge()
            clearQuarantinePending()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: fallback)
        cookieStore.getAllCookies { cookies in
            for cookie in cookies where isInstagramDomain(cookie.domain) {
                cookieStore.delete(cookie) {}
            }
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let matching = records.filter { isInstagramDomain($0.displayName) }
                if matching.isEmpty {
                    fallback.cancel()
                    if progress.completePurge() {
                        clearQuarantinePending()
                    }
                } else {
                    store.removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        for: matching
                    ) {
                        fallback.cancel()
                        if progress.completePurge() {
                            clearQuarantinePending()
                        }
                    }
                }
            }
        }
    }

    nonisolated private static func applicationSupportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    #if DEBUG
    nonisolated static func seedCorruptStateForTesting() {
        defaults.set("sessionid=bad-value\ninvalid-cookie", forKey: "instagram.cookie")
        defaults.set("broken-user", forKey: "instagram.username")
        defaults.set(0, forKey: epochKey)
        defaults.set(true, forKey: quarantinePendingKey)
        if let cookie = HTTPCookie(properties: [
            .domain: ".instagram.com",
            .path: "/",
            .name: "sessionid",
            .value: "bad-value",
        ]) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
        guard let root = applicationSupportDirectory() else { return }
        let directory = root.appendingPathComponent("databases", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("app.db", isDirectory: false).path
        executeSQL(
            at: path,
            """
            CREATE TABLE IF NOT EXISTS DbAccount (
                account_key TEXT NOT NULL PRIMARY KEY,
                credential_json TEXT NOT NULL,
                platform_type TEXT NOT NULL,
                last_active INTEGER NOT NULL,
                sort_id INTEGER NOT NULL DEFAULT 0
            );
            INSERT OR REPLACE INTO DbAccount
                (account_key, credential_json, platform_type, last_active, sort_id)
            VALUES
                ('bad-user@instagram.com', '{broken-json', 'Instagram', 1, 0),
                ('keep-user@mastodon.social', '{\"ok\":true}', 'Mastodon', 2, 1);
            """
        )
    }
    #endif

    #if DEBUG
    nonisolated static func isInstagramDomainForTesting(_ domain: String) -> Bool {
        isInstagramDomain(domain)
    }
    #endif

    nonisolated private static func isInstagramDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased()
        return normalized.contains("instagram.com")
            || normalized.contains("cdninstagram.com")
    }
}
