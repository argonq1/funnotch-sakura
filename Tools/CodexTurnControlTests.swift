import Foundation

/// Driver used by TestCodexTurnControl.py's isolated local router fixtures.
@main
enum CodexTurnControlTests {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--live-probe" {
            do {
                // Deliberately impossible turn id: exercises the real desktop
                // handler's stale-turn guard without stopping any current work.
                let result = try CodexTurnControl.stop(threadID: args[2], turnID: "funnotch-probe-no-such-turn")
                print(result ? "FAIL: probe interrupted a turn" : "PASS: desktop rejected stale turn without cancellation")
                exit(result ? 1 : 0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        guard args.count == 4 else { exit(2) }
        do {
            let result = try CodexTurnControl.stop(threadID: "00000000-0000-4000-8000-000000000001",
                turnID: "turn-visible-at-click", endpoint: URL(fileURLWithPath: args[1]))
            let outcome = result ? "stopped" : "stale"
            guard outcome == args[2] else { print("FAIL: expected \(args[2]), got \(outcome)"); exit(1) }
        } catch {
            guard args[2] == "error" else { print("FAIL: \(error)"); exit(1) }
        }
        print("PASS: \(args[3])")
    }
}
