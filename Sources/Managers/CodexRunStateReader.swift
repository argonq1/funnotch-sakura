import Foundation

/// Only lifecycle markers are retained; message bodies are discarded.
enum CodexRunStateReader {
    struct State: Equatable, Sendable {
        let working: Bool
        let since: Date
        var turnID: String? = nil
        var interrupted = false
        var waitingReason: String? = nil
        var waitingCallID: String? = nil
        var failure: String? = nil
    }
    private struct Cache {
        var offset: UInt64
        var partial: Data
        var state: State?
        var modified: Date?
        var droppingPartial = false
    }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Cache] = [:]
    private static let markers = ["task_started", "task_complete", "turn_aborted", "request_user_input", "request_permissions", "function_call_output", "task_failed", "approval_request", "user_message"].map { Data($0.utf8) }

    static func latest(in data: Data, previous: State? = nil) -> State? {
        var resolvedCalls = Set<String>()
        for line in data.split(separator: 10).reversed() {
            guard markers.contains(where: { line.range(of: $0) != nil }),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let event = payload["type"] as? String,
                  let timestamp = object["timestamp"] as? String else { continue }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else { continue }
            let attribution = payload["turn_attribution"] as? [String: Any]
            let turnID = payload["turn_id"] as? String ?? attribution?["turn_id"] as? String ?? previous?.turnID
            if object["type"] as? String == "response_item" {
                if event == "function_call_output", let callID = payload["call_id"] as? String {
                    resolvedCalls.insert(callID)
                    if previous?.waitingCallID == callID {
                        return State(working: true, since: date, turnID: turnID)
                    }
                }
                if event == "function_call", let name = payload["name"] as? String,
                   name.contains("request_user_input") || name.contains("request_permissions") {
                    let callID = payload["call_id"] as? String
                    if let callID, resolvedCalls.contains(callID) { continue }
                    return State(working: true, since: date, turnID: turnID,
                                 waitingReason: name.contains("permissions") ? "Нужно разрешение" : "Нужен ответ",
                                 waitingCallID: callID)
                }
                continue
            }
            guard object["type"] as? String == "event_msg" else { continue }
            switch event {
            case "task_started", "task_complete", "turn_aborted", "task_failed":
                return State(working: event == "task_started", since: date, turnID: turnID,
                             interrupted: event == "turn_aborted",
                             failure: event == "task_failed" ? "Задача завершилась с ошибкой" : nil)
            case "approval_request", "request_user_input":
                return State(working: true, since: date, turnID: turnID, waitingReason: "Нужен ответ")
            case "user_message" where previous?.waitingReason != nil:
                return State(working: true, since: date, turnID: turnID)
            default: continue
            }
        }
        return nil
    }

    static func read(_ url: URL) -> State? {
        lock.lock(); defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }
        let modified = attrs[.modificationDate] as? Date
        if let old = cache[url.path], old.offset == size, old.modified == modified { return old.state }
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        var state: State?
        var partial = Data()
        var droppingPartial = false
        let maxRecord = 1_048_576
        if let old = cache[url.path], old.offset <= size, old.offset > 0,
           !(old.offset == size && old.modified != modified) {
            try? file.seek(toOffset: old.offset)
            state = old.state; partial = old.partial; droppingPartial = old.droppingPartial
            var offset = old.offset
            // A burst of tool output is streamed in bounded chunks, never read
            // as one large allocation. Oversized unfinished records are skipped.
            while offset < size {
                guard var more = try? file.read(upToCount: Int(min(131_072, size - offset))), !more.isEmpty else { break }
                offset += UInt64(more.count)
                if droppingPartial {
                    guard let nl = more.firstIndex(of: 10) else { continue }
                    more = Data(more.suffix(from: more.index(after: nl))); droppingPartial = false
                }
                let joined = partial + more
                if let nl = joined.lastIndex(of: 10) {
                    state = latest(in: joined.prefix(through: nl), previous: state) ?? state
                    partial = Data(joined.suffix(from: joined.index(after: nl)))
                } else { partial = joined }
                if partial.count > maxRecord { partial = Data(); droppingPartial = true }
            }
        } else {
            // Work backwards until the most recent start or completion. A long
            // tool call may have no writes for minutes; that is still working.
            var end = size
            var remainder = Data()
            var first = true
            while end > 0 {
                let start = end > 262_144 ? end - 262_144 : 0
                try? file.seek(toOffset: start)
                var chunk = ((try? file.read(upToCount: Int(end - start))) ?? Data()) + remainder
                if first {
                    if let nl = chunk.lastIndex(of: 10) {
                        partial = Data(chunk.suffix(from: chunk.index(after: nl)))
                        chunk = Data(chunk.prefix(through: nl))
                    } else {
                        partial = start == 0 ? chunk : Data()
                        droppingPartial = start > 0
                        chunk = Data()
                    }
                    first = false
                }
                let firstNewline = chunk.firstIndex(of: 10)
                let complete = start == 0 ? chunk : firstNewline.map { Data(chunk.suffix(from: chunk.index(after: $0))) } ?? Data()
                if let found = latest(in: complete) { state = found; break }
                remainder = firstNewline.map { Data(chunk.prefix(through: $0)) } ?? chunk
                if remainder.count > maxRecord { remainder = Data() }
                end = start
            }
        }
        if cache.count > 300 { cache.removeAll() }
        cache[url.path] = Cache(offset: size, partial: partial, state: state, modified: modified, droppingPartial: droppingPartial)
        return state
    }
}
