import Carbon
import Combine
import Foundation

/// A single shutdown request for the current FunNotch session.
@MainActor
final class ShutdownTimer: ObservableObject {
    static let shared = ShutdownTimer(requestShutdown: ShutdownTimer.sendShutdownEvent)
    static let maximumMinutes = 24 * 60

    enum State: Equatable {
        case idle
        case scheduled(ContinuousClock.Instant)
        case requested
        case failed(OSStatus)
    }

    @Published private(set) var state: State = .idle
    private let clock = ContinuousClock()
    private let requestShutdown: () -> OSStatus
    private var pending: Task<Void, Never>?

    init(requestShutdown: @escaping () -> OSStatus) {
        self.requestShutdown = requestShutdown
    }

    var isScheduled: Bool {
        if case .scheduled = state { return true }
        return false
    }

    func schedule(after seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0, seconds <= Double(Self.maximumMinutes * 60) else { return }
        pending?.cancel()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        state = .scheduled(deadline)
        pending = Task { [weak self, clock] in
            do { try await clock.sleep(until: deadline, tolerance: .zero) }
            catch { return }
            guard let self, !Task.isCancelled, self.state == .scheduled(deadline) else { return }
            self.pending = nil
            let status = self.requestShutdown()
            self.state = status == noErr ? .requested : .failed(status)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        state = .idle
    }

    func remainingSeconds(until deadline: ContinuousClock.Instant) -> Int {
        let remaining = clock.now.duration(to: deadline).components
        return max(0, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
    }

    /// The normal macOS session shutdown. Apps can cancel to protect unsaved
    /// documents. See Apple QA1134 for the system process target.
    private static func sendShutdownEvent() -> OSStatus {
        var systemProcess = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        var target = AEAddressDesc(descriptorType: OSType(typeNull), dataHandle: nil)
        let targetStatus = AECreateDesc(DescType(typeProcessSerialNumber), &systemProcess,
                                        MemoryLayout<ProcessSerialNumber>.size, &target)
        guard targetStatus == noErr else { return OSStatus(targetStatus) }
        defer { AEDisposeDesc(&target) }

        var event = AppleEvent(descriptorType: OSType(typeNull), dataHandle: nil)
        let status = AECreateAppleEvent(AEEventClass(kCoreEventClass), AEEventID(kAEShutDown), &target,
                                        AEReturnID(kAutoGenerateReturnID), AETransactionID(kAnyTransactionID), &event)
        guard status == noErr else { return OSStatus(status) }
        defer { AEDisposeDesc(&event) }
        return AESendMessage(&event, nil, AESendMode(kAENoReply | kAENeverInteract), kAEDefaultTimeout)
    }
}
