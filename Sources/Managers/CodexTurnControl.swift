import Darwin
import Foundation

/// One short-lived connection to the running desktop's local thread router.
/// Uses the same exact-turn interrupt request as Codex's own Stop button.
/// No helper server, account credentials, app restart or process signals.
enum CodexTurnControl {
    enum Failure: LocalizedError {
        case unavailable, unsafeEndpoint, timedOut, protocolError, rejected(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Codex недоступен. Открой приложение и повтори."
            case .unsafeEndpoint: return "Не удалось проверить локальное подключение Codex."
            case .timedOut: return "Codex не ответил. Проверь состояние чата и повтори."
            case .protocolError: return "Версия Codex не поддерживает эту команду. Открой чат и нажми Стоп в нём."
            case .rejected(let reason):
                if reason.contains("no-client") || reason.contains("client-not") {
                    return "Не найден работающий чат в Codex. Открой его и повтори."
                }
                if reason.contains("version") { return Failure.protocolError.errorDescription }
                return "Codex не принял остановку. Открой чат и проверь его состояние."
            }
        }
    }

    static var endpoint: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")
    }

    /// False means this exact turn has already ended or was replaced. Never
    /// retry against a newer turn: a stale click must not cancel the next reply.
    static func stop(threadID: String, turnID: String, endpoint: URL = endpoint) throws -> Bool {
        guard UUID(uuidString: threadID) != nil, !turnID.isEmpty, turnID.utf8.count <= 200 else {
            throw Failure.protocolError
        }
        let connection = try Connection(endpoint: endpoint)
        let initialized = try connection.request("initialize", params: ["clientType": "funnotch"], version: 0)
        guard let client = (initialized["result"] as? [String: Any])?["clientId"] as? String else {
            throw Failure.protocolError
        }
        connection.clientID = client
        let owner = try connection.request("thread-owner-discovery",
            params: ["hostId": "local", "conversationId": threadID], version: 1)
        guard let target = owner["handledByClientId"] as? String else { throw Failure.protocolError }
        let response = try connection.request("thread-follower-interrupt-turn",
            params: ["conversationId": threadID, "mode": "user-stop", "expectedTurnId": turnID],
            version: 4, target: target)
        guard let result = response["result"] as? [String: Any], result["ok"] as? Bool == true else {
            throw Failure.protocolError
        }
        guard let interrupted = result["interruptedTurnId"] as? String else { return false }
        guard interrupted == turnID else { throw Failure.protocolError }
        return true
    }

    private final class Connection {
        let fd: Int32
        var clientID = "pending"
        private let deadline = Date().addingTimeInterval(12)
        private let maxFrame = 16 * 1024 * 1024

        init(endpoint: URL) throws {
            var socketInfo = stat(), directoryInfo = stat()
            guard lstat(endpoint.path, &socketInfo) == 0 else { throw Failure.unavailable }
            guard lstat(endpoint.deletingLastPathComponent().path, &directoryInfo) == 0,
                  socketInfo.st_uid == getuid(), directoryInfo.st_uid == getuid(),
                  socketInfo.st_mode & S_IFMT == S_IFSOCK,
                  directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  socketInfo.st_mode & 0o077 == 0, directoryInfo.st_mode & 0o077 == 0 else {
                throw Failure.unsafeEndpoint
            }
            var address = sockaddr_un()
            let bytes = Array(endpoint.path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
            fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.unavailable }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            do {
                if result != 0 {
                    guard errno == EINPROGRESS else { throw Failure.unavailable }
                    try ready(POLLOUT)
                    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                        throw Failure.unavailable
                    }
                }
            } catch { Darwin.close(fd); throw error }
        }
        deinit { Darwin.close(fd) }

        func request(_ method: String, params: [String: Any], version: Int, target: String? = nil) throws -> [String: Any] {
            let id = UUID().uuidString
            var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": clientID,
                "method": method, "version": version, "params": params, "timeoutMs": 5000]
            if let target { message["targetClientId"] = target }
            try send(message)
            while true {
                let header = try receive(4)
                let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                guard length > 0, length <= maxFrame else { throw Failure.protocolError }
                let body = try receive(length)
                guard let reply = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    throw Failure.protocolError
                }
                // This client handles no incoming commands and retains no broadcasts.
                if reply["type"] as? String == "client-discovery-request", let requestID = reply["requestId"] as? String {
                    try send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
                }
                guard reply["type"] as? String == "response", reply["requestId"] as? String == id else { continue }
                guard reply["resultType"] as? String == "success" else {
                    throw Failure.rejected(reply["error"] as? String ?? "unknown")
                }
                guard reply["method"] as? String == method else { throw Failure.protocolError }
                return reply
            }
        }
        private func ready(_ eventMask: Int32) throws {
            let events = Int16(eventMask)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw Failure.timedOut }
                var item = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&item, 1, Int32(min(remaining * 1000, 12_000)))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw Failure.timedOut }
                if item.revents & events != 0 { return }
                throw Failure.unavailable
            }
        }
        private func send(_ object: [String: Any]) throws {
            let body = try JSONSerialization.data(withJSONObject: object)
            var length = UInt32(body.count).littleEndian
            let data = withUnsafeBytes(of: &length) { Data($0) } + body
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try ready(POLLOUT)
                    let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                    if count < 0, errno == EAGAIN || errno == EINTR { continue }
                    guard count > 0 else { throw Failure.unavailable }
                    offset += count
                }
            }
        }
        private func receive(_ length: Int) throws -> Data {
            var data = Data(count: length)
            try data.withUnsafeMutableBytes { raw in
                var offset = 0
                while offset < length {
                    try ready(POLLIN)
                    let count = Darwin.recv(fd, raw.baseAddress!.advanced(by: offset), length - offset, 0)
                    if count < 0, errno == EAGAIN || errno == EINTR { continue }
                    guard count > 0 else { throw Failure.unavailable }
                    offset += count
                }
            }
            return data
        }
    }
}
