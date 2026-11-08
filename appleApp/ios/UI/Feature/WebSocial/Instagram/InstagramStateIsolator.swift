import Foundation
import SQLite3
import WebKit

enum InstagramStateIsolator: @unchecked Sendable {
    static let quarantineEpoch = 5
    static let quarantinePendingKey = "flare.instagram.quarantine.pending"

    private static let epochKey = "flare.instagram.quarantine.epoch"
    private static let forceKey = "flare.instagram.quarantine.force"
    private static var defaults: UserDefaults { .standard }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var suppressed = false

        func isSuppressed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return suppressed
        }

        func setSuppressed(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            suppressed = value
        }
    }

    nonisolated static func shouldQuarantine(epoch: Int, force: Bool) -> Bool {
        force || epoch < quarantineEpoch
    }

    nonisolated(unsafe) private static let state = State()
    nonisolated(unsafe) private static var quarantineCompleted = true

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

    private nonisolated static func purgeInstagramState() {
        state.setSuppressed(true)
        quarantineCompleted = false

        purgeUserDefaults()
        purgeSharedHTTPCookies()
        purgeDatabase()

        defaults.set(quarantineEpoch, forKey: epochKey)
        defaults.set(false, forKey: forceKey)
        defaults.set(true, forKey: quarantinePendingKey)
        purgeWebsiteData()
    }

    nonisolated static func clearQuarantinePendingOnFullUI() {
        guard quarantineCompleted else { return }
        clearQuarantinePending()
    }

    private nonisolated static func purgeUserDefaults() {
        defaults.removeObject(forKey: "instagram.cookie")
        defaults.removeObject(forKey: "instagram.username")
    }

    private nonisolated static func purgeSharedHTTPCookies() {
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
            PRAGMA wal_checkpoint(TRUNCATE);
            """
        )
    }

    private nonisolated static func purgeDatabase() {
        guard let root = applicationSupportDirectory() else { return }
        let directory = root.appendingPathComponent("databases", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("app.db", isDirectory: false).path
        guard FileManager.default.fileExists(atPath: path) else { return }
        purgeDatabase(at: path)
    }

    private nonisolated static func purgeWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let cookieStore = store.httpCookieStore
        cookieStore.getAllCookies { cookies in
            for cookie in cookies where isInstagramDomain(cookie.domain) {
                cookieStore.delete(cookie) {}
            }
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let matching = records.filter { isInstagramDomain($0.displayName) }
                if matching.isEmpty {
                    quarantineCompleted = true
                } else {
                    store.removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        for: matching
                    ) {
                        quarantineCompleted = true
                    }
                }
            }
        }
    }

    private nonisolated static func applicationSupportDirectory() -> URL? {
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

    private nonisolated static func isInstagramDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased()
        return normalized.contains("instagram.com")
            || normalized.contains("cdninstagram.com")
            || normalized.contains("facebook.com")
    }
}
