import Foundation

@main
enum ChessNavigationTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ value: Bool) {
            print("[\(value ? "PASS" : "FAIL")] \(name)")
            if !value { failures += 1 }
        }
        for destination in ChessDestination.allCases {
            check("\(destination.title) opens the official HTTPS site", ChessNavigation.isChess(destination.url))
        }
        check("practice starts against computer", ChessDestination.computer.url.path == "/play/computer")
        check("online has a separate explicit destination", ChessDestination.online.url.path == "/play/online")
        check("puzzles have a separate explicit destination", ChessDestination.puzzles.url.path == "/puzzles")
        for text in ["https://chess.com", "https://www.chess.com/login", "https://www.chess.com/game/live/123", "https://support.chess.com/"] {
            check("Chess.com navigation accepted: \(text)", ChessNavigation.canLoadInside(URL(string: text)!))
        }
        for text in ["https://chess.com.evil.example/", "https://fakechess.com/", "https://chess.com@evil.example/",
                     "https://name:password@www.chess.com/", "http://www.chess.com/", "file:///etc/passwd",
                     "javascript:alert(1)", "data:text/html,hello", "https://example.org/", "https://accounts.google.com.evil.example/"] {
            check("unsafe/external navigation kept out: \(text)", !ChessNavigation.canLoadInside(URL(string: text)!))
        }
        check("sign-in redirect can return to the embedded site", ChessNavigation.canLoadInside(URL(string: "https://accounts.google.com/o/oauth2/auth")!))
        check("sign-in provider is not mistaken for Chess.com", !ChessNavigation.isChess(URL(string: "https://accounts.google.com/")!))
        print(failures == 0 ? "All 22 chess navigation checks passed" : "Failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
