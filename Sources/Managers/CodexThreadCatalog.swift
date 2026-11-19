import Foundation
import SQLite3

/// Reads only thread metadata. Conversation bodies and account credentials are not needed.
struct CodexThreadCatalog {
    struct Thread {
        let id: String
        let title: String
        let rolloutPath: String
        let cwd: String
        let archived: Bool
    }
    var threads: [String: Thread] = [:]
    var indexedTitles: [String: String] = [:]

    private struct CachedCatalog {
        var catalog = CodexThreadCatalog()
        var indexOffset: UInt64 = 0
        var partial = Data()
        var indexIdentity = ""
        var databaseStamp = ""
    }
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: CachedCatalog] = [:]

    static func read(from root: URL) -> Self {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var saved = cache[root.path] ?? CachedCatalog()
        let index = root.appendingPathComponent("session_index.jsonl")
        let attributes = (try? FileManager.default.attributesOfItem(atPath: index.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = String(describing: attributes[.systemFileNumber])
        if identity != saved.indexIdentity || size < saved.indexOffset {
            saved.indexOffset = 0
            saved.partial = Data()
            saved.catalog.indexedTitles = [:]
            saved.indexIdentity = identity
        }
        let previousOffset = saved.indexOffset
        if let file = try? FileHandle(forReadingFrom: index) {
            defer { try? file.close() }
            try? file.seek(toOffset: saved.indexOffset)
            while saved.indexOffset < size {
                guard let data = try? file.read(upToCount: Int(min(131_072, size - saved.indexOffset))), !data.isEmpty else { break }
                saved.indexOffset += UInt64(data.count)
                let joined = saved.partial + data
                let lines = joined.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropLast() where line.count <= 1_048_576 {
                    guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let id = row["id"] as? String,
                          let title = cleanTitle(row["thread_name"] as? String) else { continue }
                    saved.catalog.indexedTitles[id.lowercased()] = title
                }
                saved.partial = Data(lines.last ?? Data.SubSequence())
                if saved.partial.count > 1_048_576 { saved.partial.removeAll() }
            }
        }
        let databases = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        let stamp = databases.flatMap { [$0, URL(fileURLWithPath: $0.path + "-wal")] }.map { url in
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            return url.path + String(describing: attrs[.modificationDate]) + String(describing: attrs[.size])
        }.joined(separator: "|")
        if stamp != saved.databaseStamp || previousOffset != saved.indexOffset {
            for database in databases {
                if saved.catalog.readDatabase(database) {
                    saved.databaseStamp = stamp
                    break
                }
            }
        }
        if cache.count > 8 { cache.removeAll() }
        cache[root.path] = saved
        return saved.catalog
    }

    func title(for id: String) -> String? {
        threads[id.lowercased()]?.title ?? indexedTitles[id.lowercased()]
    }

    static func sessionID(from rollout: URL) -> String? {
        let suffix = String(rollout.deletingPathExtension().lastPathComponent.suffix(36))
        return UUID(uuidString: suffix) == nil ? nil : suffix.lowercased()
    }

    static func cleanTitle(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return clean.isEmpty ? nil : String(clean.prefix(300))
    }

    private mutating func readDatabase(_ url: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else { if let database { sqlite3_close(database) }; return false }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)

        var info: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK,
              let info else { return false }
        var columns = Set<String>()
        while sqlite3_step(info) == SQLITE_ROW {
            if let name = sqlite3_column_text(info, 1) { columns.insert(String(cString: name)) }
        }
        sqlite3_finalize(info)
        guard columns.contains("id"), columns.contains("rollout_path") else { return false }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let query = "SELECT id, rollout_path, \(column("name")), \(column("title")), \(column("cwd")), \(column("archived")) FROM threads"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        func string(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        var entries: [String: Thread] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let id = string(0)?.lowercased() {
                let title = Self.cleanTitle(string(2)) ?? indexedTitles[id] ?? Self.cleanTitle(string(3)) ?? "Codex"
                entries[id] = Thread(id: id, title: title, rolloutPath: string(1) ?? "", cwd: string(4) ?? "",
                                     archived: sqlite3_column_int(statement, 5) != 0)
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { return false }
        threads = entries
        return true
    }
}
