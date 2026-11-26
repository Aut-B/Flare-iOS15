import Foundation
import SQLite3
import XCTest

final class InstagramStateIsolatorTests: XCTestCase {
    // MARK: - 登录态判据

    func testUsableSessionRequiresRealSessionID() {
        XCTAssertTrue(IGSession.hasUsableSession("csrftoken=abc; sessionid=live-session"))
        XCTAssertFalse(IGSession.hasUsableSession(""))
        // 只有 `ds_user_id` / csrf 不算登录：服务端只认 `sessionid`。
        XCTAssertFalse(IGSession.hasUsableSession("csrftoken=abc; ds_user_id=42"))
        XCTAssertFalse(IGSession.hasUsableSession("sessionid="))
        XCTAssertFalse(IGSession.hasUsableSession("sessionid=   "))
    }

    func testDirtyCookieHeaderKeepsSessionIDAfterCleaning() {
        let dirty = "sessionid=live-session\nds_user_id=42\r\ncsrftoken=token"
        let header = IGSession.normalizeCookieHeader(dirty)
        XCTAssertFalse(header.contains("\n"))
        XCTAssertFalse(header.contains("\r"))
        XCTAssertTrue(header.unicodeScalars.allSatisfy { $0.isASCII })
        XCTAssertEqual(IGSession.value(inHeader: header, named: "sessionid"), "live-session")
        XCTAssertEqual(IGSession.value(inHeader: header, named: "csrftoken"), "token")
        XCTAssertTrue(IGSession.hasUsableSession(header))
    }

    func testSanitizeHeaderDropsControlCharactersButKeepsSession() {
        let safe = IGSession.sanitizeHeader("sessionid=live\u{7F}session\nfoo=bar")
        XCTAssertFalse(safe.contains("\n"))
        XCTAssertFalse(safe.contains("\u{7F}"))
        XCTAssertTrue(IGSession.hasUsableSession(safe))
    }

    func testHeaderFromCookiesKeepsOnlyFreshInstagramCookies() throws {
        let live = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: ".instagram.com",
                .path: "/",
                .name: "sessionid",
                .value: "live-session",
            ])
        )
        let expired = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: ".instagram.com",
                .path: "/",
                .name: "stale_sessionid",
                .value: "stale",
                .expires: Date(timeIntervalSinceNow: -3600),
            ])
        )
        let foreign = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: ".xiaohongshu.com",
                .path: "/",
                .name: "sessionid",
                .value: "xhs-session",
            ])
        )

        let header = IGSession.header(
            from: [live, expired, foreign],
            domainSuffix: "instagram.com"
        )
        XCTAssertEqual(IGSession.value(inHeader: header, named: "sessionid"), "live-session")
        XCTAssertNil(IGSession.value(inHeader: header, named: "stale_sessionid"))
        XCTAssertFalse(header.contains("xhs-session"))
        XCTAssertTrue(IGSession.hasUsableSession(header))
    }

    // MARK: - 提示判据

    func testLoginExpiryAndWindControlMessagesStayDistinct() {
        let expired = IGError.notLoggedIn
        XCTAssertTrue(expired.needLogin)
        XCTAssertTrue(expired.message.contains("重新登录"))

        // 首页还能刷时的点赞 / 评论被拒是风控，不能把用户踢回登录页。
        let denied = IGError.interactionDenied
        XCTAssertFalse(denied.needLogin)
        XCTAssertTrue(denied.message.contains("风控"))
        XCTAssertFalse(denied.message.contains("重新登录"))
        XCTAssertNotEqual(expired.message, denied.message)
    }

    func testQuarantineDecisionStateMachine() {
        XCTAssertTrue(
            InstagramStateIsolator.shouldQuarantine(epoch: 0, force: false)
        )
        XCTAssertTrue(
            InstagramStateIsolator.shouldQuarantine(epoch: 99, force: true)
        )
        XCTAssertFalse(
            InstagramStateIsolator.shouldQuarantine(
                epoch: InstagramStateIsolator.quarantineEpoch,
                force: false
            )
        )
    }

    func testInstagramDomainMatchingPreservesOtherWebData() {
        // graph.facebook.com 属于 Instagram 登录链路（cookie 从这里下发），
        // 隔离时不清它，坏 cookie 会活下来，下次冷启动照样崩。
        for domain in ["www.instagram.com", ".cdninstagram.com", "graph.facebook.com"] {
            XCTAssertTrue(InstagramStateIsolator.isInstagramDomainForTesting(domain))
        }
        for domain in ["xiaohongshu.com", "weread.qq.com", "mastodon.social"] {
            XCTAssertFalse(InstagramStateIsolator.isInstagramDomainForTesting(domain))
        }
    }

    func testPurgeOnlyDeletesInstagramAccounts() {
        let path = temporaryDatabasePath()
        InstagramStateIsolator.executeSQL(
            at: path,
            """
            CREATE TABLE DbAccount (
                account_key TEXT NOT NULL PRIMARY KEY,
                credential_json TEXT NOT NULL,
                platform_type TEXT NOT NULL,
                last_active INTEGER NOT NULL,
                sort_id INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO DbAccount VALUES
                ('ig-user@instagram.com', '{bad-json', 'Instagram', 1, 0),
                ('legacy-ig-user', '{bad-json', 'Instagram', 2, 1),
                ('legacy-ig-key@instagram.com', '{bad-json', 'LegacyInstagram', 5, 5),
                ('xhs-user@xiaohongshu.com', '{\"ok\":true}', 'Xiaohongshu', 3, 2),
                ('weread-user@weread.qq.com', '{\"ok\":true}', 'Weread', 4, 3),
                ('mastodon-user@mastodon.social', '{\"ok\":true}', 'Mastodon', 5, 4);
            """
        )

        InstagramStateIsolator.purgeDatabase(at: path)

        XCTAssertEqual(queryAccountKeys(at: path), [
            "xhs-user@xiaohongshu.com",
            "weread-user@weread.qq.com",
            "mastodon-user@mastodon.social",
        ])
    }

    private func temporaryDatabasePath() -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let path = directory.appendingPathComponent("app.db").path
        XCTAssertTrue(
            FileManager.default.createFile(atPath: path, contents: nil),
            "Could not create temporary SQLite database"
        )
        return path
    }

    private func queryAccountKeys(at path: String) -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT account_key FROM DbAccount ORDER BY sort_id",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement
        else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                keys.append(String(cString: text))
            }
        }
        return keys
    }
}
