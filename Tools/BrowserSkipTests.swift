import Foundation

@main
enum BrowserSkipTests {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 4, args[1] == "--seek" {
            print(BrowserPlaybackScript.seek(to: Double(args[2]) ?? 0, expectedURL: args[3]))
            return
        }
        if args.count >= 4, args[1] == "--script" {
            print(BrowserSkipScript.command(next: args[2] == "next", expectedURL: args[3],
                historyURL: args.count > 4 ? args[4] : nil, selectors: [".next-button", ".previous-button"]))
            return
        }
        var failures = 0
        func check(_ name: String, _ value: Bool) {
            print("[\(value ? "PASS" : "FAIL")] \(name)"); if !value { failures += 1 }
        }
        let a = "https://www.youtube.com/watch?v=alpha", b = "https://www.youtube.com/watch?v=beta", c = "https://www.youtube.com/watch?v=gamma"
        var history = BrowserVideoHistory()
        history.record(a); history.record(a + "&t=10"); history.record(b)
        check("playhead URL changes do not create duplicate videos", history.urls.count == 2)
        check("previous finds the observed previous video", history.candidate(next: false) == a)
        history.record(a)
        check("returning preserves forward navigation", history.candidate(next: true) == b)
        history.cancel(); history.record(c)
        check("a new branch discards old forward history", history.urls == [a, c])
        check("the initial video has no invented previous", { var h = BrowserVideoHistory(); h.record(a); return h.candidate(next: false) == nil }())
        history.record("https://example.com/watch?v=unsafe")
        check("non-YouTube pages never enter video history", history.urls.count == 2)
        for i in 0..<70 { history.record("https://www.youtube.com/watch?v=video\(i)") }
        check("history is bounded", history.urls.count == 40)
        check("failed commands do not move the history cursor", { let old = history.index; _ = history.candidate(next: false); history.cancel(); return history.index == old }())
        check("a new video id confirms YouTube switching", BrowserSkipScript.hasChanged(before: "youtube:alpha", after: "youtube:beta"))
        check("the same video does not confirm switching", !BrowserSkipScript.hasChanged(before: "youtube:alpha", after: "youtube:alpha"))
        check("Apple Events error is not a successful switch", !BrowserSkipScript.hasChanged(before: "youtube:alpha", after: "error:12:disabled"))
        check("an unrelated page is not a successful switch", !BrowserSkipScript.hasChanged(before: "youtube:alpha", after: "https://example.com/|title"))
        check("missing response is not success", !BrowserSkipScript.hasChanged(before: "youtube:alpha", after: nil))
        check("metadata change can confirm a web music track", BrowserSkipScript.hasChanged(before: "https://open.spotify.com/|one", after: "https://open.spotify.com/|two"))
        print(failures == 0 ? "All 14 browser history/verification checks passed" : "Failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
