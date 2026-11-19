import Foundation

@main
enum CodexRunStateTests {
    static func main() throws {
        var failures = 0
        func check(_ text: String, _ value: Bool) {
            print("[\(value ? "PASS" : "FAIL")] \(text)")
            if !value { failures += 1 }
        }
        func event(_ type: String, time: String = "2026-11-03T10:11:00.123Z") -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"\(time)\",\"payload\":{\"type\":\"\(type)\"}}\n"
        }
        check("task_started marks a chat as working", CodexRunStateReader.latest(in: Data(event("task_started").utf8))?.working == true)
        check("task_complete marks a chat as finished", CodexRunStateReader.latest(in: Data(event("task_complete").utf8))?.working == false)
        check("an aborted turn is no longer working", CodexRunStateReader.latest(in: Data(event("turn_aborted").utf8))?.working == false)
        check("aborted and completed outcomes are distinct", CodexRunStateReader.latest(in: Data(event("turn_aborted").utf8))?.interrupted == true
              && CodexRunStateReader.latest(in: Data(event("task_complete").utf8))?.interrupted == false)
        let withTurn = "{\"type\":\"event_msg\",\"timestamp\":\"2026-11-03T10:11:00Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-current\"}}\n"
        check("the exact active turn id is retained", CodexRunStateReader.latest(in: Data(withTurn.utf8))?.turnID == "turn-current")
        let attributed = withTurn.replacingOccurrences(of: "\"turn_id\":\"turn-current\"", with: "\"turn_attribution\":{\"turn_id\":\"turn-attributed\"}")
        check("attributed turn ids are supported", CodexRunStateReader.latest(in: Data(attributed.utf8))?.turnID == "turn-attributed")
        check("the most recent lifecycle event wins", CodexRunStateReader.latest(in: Data((event("task_complete") + event("task_started")).utf8))?.working == true)
        check("ordinary messages cannot create completion events", CodexRunStateReader.latest(in: Data(event("agent_message").utf8)) == nil)
        check("malformed records are ignored", CodexRunStateReader.latest(in: Data((event("task_started") + "broken line\n").utf8))?.working == true)
        func requestRecord(_ name: String, type: String = "function_call", id: String = "request-1") -> String {
            let object: [String: Any] = ["type": "response_item", "timestamp": "2026-11-03T10:12:00Z",
                "payload": ["type": type, "name": name, "call_id": id]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        let waitingRecord = requestRecord("functions.request_user_input")
        let waiting = CodexRunStateReader.latest(in: Data(waitingRecord.utf8))
        check("an explicit input request marks the chat as waiting", waiting?.waitingReason != nil && waiting?.working == true)
        let replyRecord = requestRecord("", type: "function_call_output")
        check("the matching tool reply clears waiting across incremental scans",
              CodexRunStateReader.latest(in: Data(replyRecord.utf8), previous: waiting)?.waitingReason == nil)
        check("a request already answered in the same batch does not remain waiting",
              CodexRunStateReader.latest(in: Data((event("task_started") + waitingRecord + replyRecord).utf8))?.waitingReason == nil)
        check("a failed task reports an error rather than successful completion",
              CodexRunStateReader.latest(in: Data(event("task_failed").utf8))?.failure != nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("flappy-codex-" + UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let noise = String(repeating: "{\"type\":\"response_item\",\"payload\":{}}\n", count: 24000)
        try (event("task_started") + noise).write(to: file, atomically: true, encoding: .utf8)
        check("a long turn remains active even with no recent start marker in the tail", CodexRunStateReader.read(file)?.working == true)
        check("an unchanged file preserves its active state across scans", CodexRunStateReader.read(file)?.working == true)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        let finish = event("task_complete")
        let cut = finish.index(finish.startIndex, offsetBy: 33)
        try handle.write(contentsOf: Data(finish[..<cut].utf8))
        check("a partially written event does not mark a turn finished", CodexRunStateReader.read(file)?.working == true)
        try handle.write(contentsOf: Data(finish[cut...].utf8)); try handle.close()
        check("a completion split across two scans is recognised", CodexRunStateReader.read(file)?.working == false)
        try event("task_started", time: "2026-11-03T11:00:00Z").write(to: file, atomically: true, encoding: .utf8)
        check("a replaced or truncated rollout is rescanned", CodexRunStateReader.read(file)?.working == true)
        check("timestamps without fractional seconds are supported", CodexRunStateReader.read(file)?.since == ISO8601DateFormatter().date(from: "2026-11-03T11:00:00Z"))
        let incomplete = FileManager.default.temporaryDirectory.appendingPathComponent("codex-partial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: incomplete) }
        try (event("task_started") + String(event("task_complete").dropLast())).write(to: incomplete, atomically: true, encoding: .utf8)
        check("the initial scan waits for a newline before accepting completion", CodexRunStateReader.read(incomplete)?.working == true)
        let writer = try FileHandle(forWritingTo: incomplete); try writer.seekToEnd()
        try writer.write(contentsOf: Data("\n".utf8))
        check("the initial partial record is completed on the next scan", CodexRunStateReader.read(incomplete)?.working == false)
        try writer.write(contentsOf: Data(String(repeating: "x", count: 3_000_000).utf8))
        check("an oversized incomplete tool record does not change chat status", CodexRunStateReader.read(incomplete)?.working == false)
        try writer.write(contentsOf: Data(("\n" + event("task_started")).utf8)); try writer.close()
        check("valid events after an oversized record remain discoverable", CodexRunStateReader.read(incomplete)?.working == true)
        print(failures == 0 ? "All Codex lifecycle checks passed" : "Lifecycle failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
