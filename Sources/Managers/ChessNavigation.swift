import Foundation

enum ChessDestination: String, CaseIterable, Identifiable {
    case computer, online, puzzles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .computer: return "Боты"
        case .online: return "Онлайн"
        case .puzzles: return "Задачи"
        }
    }
    var url: URL {
        let path: String
        switch self {
        case .computer: path = "/play/computer"
        case .online: path = "/play/online"
        case .puzzles: path = "/puzzles"
        }
        return URL(string: "https://www.chess.com" + path)!
    }
}

enum ChessNavigation {
    static func isChess(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "chess.com" || host.hasSuffix(".chess.com")
    }
    static func canLoadInside(_ url: URL) -> Bool {
        if isChess(url) { return true }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return false }
        // Some sign-in methods redirect out and then back to Chess.com. They
        // run as normal WebKit pages; FunNotch never reads credentials/cookies.
        return ["accounts.google.com", "appleid.apple.com", "www.facebook.com"].contains(url.host?.lowercased() ?? "")
    }
}
