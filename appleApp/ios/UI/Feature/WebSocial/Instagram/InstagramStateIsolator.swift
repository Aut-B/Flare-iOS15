import Foundation
import SQLite3
import WebKit

nonisolated enum InstagramStateIsolator: @unchecked Sendable {
    static let quarantineEpoch = 5
    static let quarantinePendingKey = "flare.instagram.quarantine.pending"

    private static let epochKey = "flare.instagram.quarantine.epoch"
    private static let forceKey = "flare.instagram.quarantine.force"
    private static let cookieKey = "instagram.cookie"
    private static let usernameKey = "instagram.username"
    private static var defaults: UserDefaults { .standard }

    nonisolated private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var suppressed = false
        private var verificationScheduled = false
        /// 每次 purge 都 +1。异步 WK 回调拿到的是旧快照，回来时代次变了
        /// 就必须丢弃，否则刚登录的新会话会被旧快照里的「无会话」判死。
        private var generation = 0

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

        nonisolated func beginVerification() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !verificationScheduled else { return false }
            verificationScheduled = true
            return true
        }

        nonisolated func currentGeneration() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return generation
        }

        nonisolated func advanceGeneration() {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
        }

        nonisolated func isCurrent(_ token: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return generation == token
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
        /// 每轮 purge 的编号。早先那轮的 10 秒兜底回调可能在下一轮 purge
        /// 开始后才回来；没有编号会把新一轮的 pending 提前清掉。
        private var generation = 0

        nonisolated func beginPurge() -> Int {
            lock.lock()
            defer { lock.unlock() }
            generation += 1
            purgeCompleted = false
            fullUIShown = false
            return generation
        }

        /// 返回 true 表示主界面已经出现过，可以清 pending。
        nonisolated func completePurge(_ token: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard token == generation else { return false }
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
        let forced = defaults.bool(forKey: forceKey)
        guard forced || needsQuarantine else { return false }
        // force 是用户 / 崩溃兜底明确要求隔离。它必须最优先：不能再从
        // 任何仓库里把会话捡回来，否则点「清掉 Instagram 登录」后
        // 冷启动又恢复成同一个坏状态。
        if forced {
            purgeInstagramState()
            return true
        }
        // 旧版本留下的 epoch / pending 只说明「迁移没跑完」，不说明当前 cookie
        // 有问题。共享仓库里还有可用会话时先捡回来，不能因为一个旧标记就
        // 把登录态清掉，否则用户每次冷启动都得重登一次 Instagram。
        if acceptPersistedSession() { return false }
        // URLSession 仓库没有不代表网页仓库没有：IG 网页版仍登录着时，
        // 会话在 `WKWebsiteDataStore.default()` 里。先异步读一次：有就落盘，
        // 没有也只结掉旧迁移标记，绝不删 DbAccount。
        recoverWebKitSessionIfNeeded()
        return false
    }

    nonisolated private static func acceptPersistedSession() -> Bool {
        guard !defaults.bool(forKey: forceKey) else { return false }
        guard !defaults.bool(forKey: IGSession.loggedOutKey) else { return false }
        if let raw = defaults.string(forKey: cookieKey),
            IGSession.hasUsableSession(raw)
        {
            guard persistSession(raw) else { return false }
            markMigrationComplete()
            return true
        }
        guard let cookies = HTTPCookieStorage.shared.cookies else { return false }
        let targets = cookies.filter { isInstagramDomain($0.domain) }
        let header = IGSession.header(from: targets, domainSuffix: "instagram.com")
        guard IGSession.hasUsableSession(header) else { return false }
        syncToSharedStorage(targets)
        guard persistSession(header) else { return false }
        markMigrationComplete()
        return true
    }

    nonisolated private static func recoverWebKitSessionIfNeeded() {
        guard state.beginVerification() else { return }
        let generation = state.currentGeneration()
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                DispatchQueue.main.async {
                    // purge 之后回来的旧快照直接作废，别把清理后的新状态再删一遍。
                    guard state.isCurrent(generation) else { return }
                    // 异步回调期间可能又收到一次强制隔离请求；force 仍然优先。
                    guard !defaults.bool(forKey: forceKey) else {
                        purgeInstagramState()
                        return
                    }
                    // 回调等待期间 Bridge / Store 可能已经同步了有效会话。
                    // 先接受它，不能拿「刚才 WK 里没有」的旧结论去 purge。
                    if IGSession.hasUsableSession(defaults.string(forKey: cookieKey) ?? ""),
                        acceptPersistedSession()
                    {
                        return
                    }
                    guard !defaults.bool(forKey: IGSession.loggedOutKey) else {
                        // 用户已经主动退出：只把旧迁移标记结掉，不能再删
                        // DbAccount；Kotlin 里可能还有别的 IG 账号。
                        markMigrationComplete()
                        return
                    }
                    let targets = cookies.filter { isInstagramDomain($0.domain) }
                    let header = IGSession.header(from: targets, domainSuffix: "instagram.com")
                    if IGSession.hasUsableSession(header) {
                        syncToSharedStorage(targets)
                        if persistSession(header) {
                            markMigrationComplete()
                            return
                        }
                    }
                    // 非强制迁移走到这里说明原生仓库里确实没有会话，但
                    // Kotlin 的 DbAccount 可能还有一份有效凭证，稍后才会经
                    // Bridge 同步过来。这里绝不能 purge：删掉 DbAccount 就
                    // 把用户逼回登录页，正是 r3 真机重登的根因。只结掉迁移
                    // 标记，等 Bridge / 登录页把会话送进来。
                    markMigrationComplete()
                }
            }
        }
    }

    /// 只写会话本身，不碰 force / pending。强制隔离期间返回 false，
    /// 由调用方继续走 purge。
    @discardableResult
    nonisolated private static func persistSession(_ raw: String) -> Bool {
        guard !defaults.bool(forKey: forceKey) else { return false }
        // 老版本可能用换行分隔 cookie。清洗只删控制字符，直接用它会把
        // 多条 cookie 粘成一个坏值；这里先还原成正常分隔符。
        let header = IGSession.normalizeCookieHeader(raw)
        guard IGSession.hasUsableSession(header) else { return false }
        defaults.set(header, forKey: cookieKey)
        defaults.set(false, forKey: IGSession.loggedOutKey)
        return true
    }

    /// 非强制迁移成功后才允许清 pending / 提升 epoch。
    nonisolated private static func markMigrationComplete() {
        guard !defaults.bool(forKey: forceKey) else { return }
        defaults.set(quarantineEpoch, forKey: epochKey)
        clearQuarantinePending()
        // 迁移结束，允许 Bridge / 登录页同步新会话。
        state.setSuppressed(false)
    }

    nonisolated private static func syncToSharedStorage(_ cookies: [HTTPCookie]) {
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    nonisolated private static func purgeInstagramState() {
        state.advanceGeneration()
        state.setSuppressed(true)
        let purgeToken = progress.beginPurge()

        purgeUserDefaults()
        purgeSharedHTTPCookies()
        purgeDatabase()

        defaults.set(quarantineEpoch, forKey: epochKey)
        defaults.set(false, forKey: forceKey)
        defaults.set(true, forKey: quarantinePendingKey)
        purgeWebsiteData(purgeToken)
    }

    nonisolated static func clearQuarantinePendingOnFullUI() {
        if progress.markFullUIShown() {
            clearQuarantinePending()
        }
    }

    nonisolated private static func purgeUserDefaults() {
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: usernameKey)
        // 隔离就是「这次必须重新登录」。不写这个标记的话，Store 初始化时
        // 可能抢在 WK 异步删除前把同一个坏会话又 adopt 回来。
        defaults.set(true, forKey: IGSession.loggedOutKey)
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

    nonisolated private static func purgeWebsiteData(_ token: Int) {
        let store = WKWebsiteDataStore.default()
        let cookieStore = store.httpCookieStore
        // 兜底：WK 的两个回调在坏状态（数据库损坏 / WebKit 进程卡死）下可能永远不返回。
        // 之前 pending 标记就永远清不掉，于是每次冷启动都重新删一次 Instagram 账号，
        // 表现是「登录成功但标签页里没有账号」「每次都提示登录已失效」。
        // 这里最多等 10 秒，超时也当作清理完成，保证只隔离一次。
        let fallback = DispatchWorkItem {
            if progress.completePurge(token) {
                clearQuarantinePending()
            }
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
                    if progress.completePurge(token) {
                        clearQuarantinePending()
                    }
                } else {
                    store.removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        for: matching
                    ) {
                        fallback.cancel()
                        if progress.completePurge(token) {
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
        defaults.set("sessionid=bad-value\ninvalid-cookie", forKey: cookieKey)
        defaults.set("broken-user", forKey: usernameKey)
        defaults.set(true, forKey: IGSession.loggedOutKey)
        // `quarantineIfNeeded()` 只在 forced 分支 purge。测试种子必须把
        // force 打开，否则坏 DbAccount 行和共享仓库里的坏 sessionid 都会
        // 留到第二次冷启动，Kotlin decode 半截 JSON 时直接 abort。
        defaults.set(true, forKey: forceKey)
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
        // `graph.facebook.com` 是 Instagram 登录链路的一部分：cookie 从它下发，
        // WKWebsiteDataStore 里的记录也记在它名下。早先这里漏了它，
        // 隔离之后那条 cookie 还活着，下次冷启动又被捡回来继续用 -> 照样崩。
        return normalized.contains("instagram.com")
            || normalized.contains("cdninstagram.com")
            || normalized.contains("facebook.com")
    }
}
