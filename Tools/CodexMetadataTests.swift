import Foundation
import SQLite3

@main
enum CodexMetadataTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("funnotch-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func check(_ title: String, _ passed: Bool) {
            print("[\(passed ? "PASS" : "FAIL")] \(title)")
            if !passed { failures += 1 }
        }
        let id = "00000000-0000-4000-8000-000000000001"
        let other = "00000000-0000-4000-8000-000000000002"
        let index = root.appendingPathComponent("session_index.jsonl")
        let records: [[String: String]] = [
            ["id": id, "thread_name": "Old chat name"],
            ["id": id, "thread_name": "Renamed chat"],
            ["id": other, "thread_name": "Index title"],
        ]
        let text = try records.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\nnot valid json\n"
        try text.write(to: index, atomically: true, encoding: .utf8)
        var catalog = CodexThreadCatalog.read(from: root)
        check("the newest index entry wins after a rename", catalog.title(for: id) == "Renamed chat")
        check("a missing database falls back to the title index", catalog.title(for: other) == "Index title")
        check("an unknown chat has no invented title", catalog.title(for: "missing") == nil)

        func create(_ path: URL, sql: String) {
            var db: OpaquePointer?
            precondition(sqlite3_open(path.path, &db) == SQLITE_OK)
            precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
        }
        let db = root.appendingPathComponent("state_5.sqlite")
        create(db, sql: """
            CREATE TABLE threads(id TEXT, rollout_path TEXT, name TEXT, title TEXT, cwd TEXT, archived INTEGER);
            INSERT INTO threads VALUES('\(id)', '/tmp/sessions/2025/01/01/rollout-old-\(id).jsonl', 'Настоящее имя чата', 'Raw first user message', '/tmp/My Project', 0);
            INSERT INTO threads VALUES('\(other)', '/tmp/other.jsonl', '', 'Raw prompt', '/tmp', 1);
            """)
        let before = try Data(contentsOf: db)
        catalog = CodexThreadCatalog.read(from: root)
        check("the desktop chat name takes priority over the first user message", catalog.title(for: id) == "Настоящее имя чата")
        check("empty database names fall back to the renamed index title", catalog.title(for: other) == "Index title")
        check("rollouts from old creation dates remain discoverable", catalog.threads[id]?.rolloutPath.contains("2025/01/01") == true)
        check("archived chats remain identifiable for exclusion", catalog.threads[other]?.archived == true)
        check("the working directory is retained as metadata", catalog.threads[id]?.cwd == "/tmp/My Project")
        check("catalog access does not modify the source database", try Data(contentsOf: db) == before)
        check("the UUID is extracted from a normal rollout filename", CodexThreadCatalog.sessionID(from: URL(fileURLWithPath: "/tmp/rollout-2026-11-03T12-01-00-\(id).jsonl")) == id)
        check("an invalid rollout name is not mistaken for a thread UUID", CodexThreadCatalog.sessionID(from: URL(fileURLWithPath: "/tmp/not-a-rollout.jsonl")) == nil)
        check("multiline chat names become a single readable line", CodexThreadCatalog.cleanTitle("  Сделать\n\t змейку  ") == "Сделать змейку")
        check("blank names fall back instead of drawing an empty label", CodexThreadCatalog.cleanTitle(" \n\t") == nil)
        check("very long fallback titles are bounded", CodexThreadCatalog.cleanTitle(String(repeating: "a", count: 1000))?.count == 300)

        let oldRoot = root.appendingPathComponent("older-schema")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        create(oldRoot.appendingPathComponent("state_4.sqlite"), sql: "CREATE TABLE threads(id TEXT, rollout_path TEXT, title TEXT); INSERT INTO threads VALUES('\(id)', '/tmp/old.jsonl', 'Legacy title');")
        check("older schemas without a name column still work", CodexThreadCatalog.read(from: oldRoot).title(for: id) == "Legacy title")
        create(oldRoot.appendingPathComponent("state_10.sqlite"), sql: "CREATE TABLE threads(id TEXT, rollout_path TEXT, name TEXT); INSERT INTO threads VALUES('\(id)', '/tmp/new.jsonl', 'New database');")
        check("database versions are ordered numerically", CodexThreadCatalog.read(from: oldRoot).title(for: id) == "New database")
        print(failures == 0 ? "All Codex metadata checks passed" : "Codex metadata failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
