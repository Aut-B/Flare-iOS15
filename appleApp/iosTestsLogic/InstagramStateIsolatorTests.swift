import SQLite3
import XCTest

final class InstagramStateIsolatorTests: XCTestCase {
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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("app.db").path
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
