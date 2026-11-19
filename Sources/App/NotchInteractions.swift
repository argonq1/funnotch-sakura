import AppKit
import Carbon

/// Uses native trackpad events and a registered hot key, with no idle timer.
@MainActor
final class NotchInteractions {
    static let shared = NotchInteractions()
    private var monitors: [Any] = []
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var consumed = false
    private var lastGesture: TimeInterval = 0

    func start() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.scroll(event) == true ? nil : event }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.scroll(event) }
        }) { monitors.append(monitor) }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated {
                guard let model = NotchWindowManager.shared.activeViewModel else { return }
                NotificationCenter.default.post(name: .toggleCodexMenuRequested, object: model.screenIdentifier)
            }
            return noErr
        }, 1, &event, nil, &handler)
        let id = EventHotKeyID(signature: 0x464E4344, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { DiagnosticLog.write("shortcut", "Could not register Control-Option-C: \(result)") }
    }

    private func scroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if event.phase == .began || now - lastGesture > 0.4 {
            horizontal = 0
            vertical = 0
            consumed = false
        }
        lastGesture = now
        guard !consumed, let controller = NotchWindowManager.shared.controllers.first(where: { $0.containsHoverPoint(NSEvent.mouseLocation) }) else { return false }
        let model = controller.viewModel
        guard !model.pinnedOpen, !model.dragDetectorTargeting else { return false }
        horizontal += event.scrollingDeltaX
        vertical += event.scrollingDeltaY
        if abs(vertical) > 42 && abs(vertical) > abs(horizontal) * 1.5 {
            if vertical < 0 && model.notchState == .closed { model.open(); consumed = true }
            else if vertical > 0 && model.notchState == .open { model.close(); consumed = true }
        } else if abs(horizontal) > 52 && abs(horizontal) > abs(vertical) * 1.5,
                  model.notchState == .open, model.currentTab == .home {
            let rect = controller.hoverRect
            let point = NSEvent.mouseLocation
            guard point.y < rect.maxY - 60, point.y > rect.minY + 35,
                  point.x < rect.maxX - 175 else { return false }
            if horizontal < 0 { MusicManager.shared.nextTrack() }
            else { MusicManager.shared.previousTrack() }
            consumed = true
        }
        return consumed
    }
}
