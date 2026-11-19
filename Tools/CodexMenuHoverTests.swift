import AppKit
import Foundation

// A local event source lets this probe exercise the production hover controller
// without moving the user's pointer or registering global monitors.
@MainActor final class MouseTracker {
    static let shared = MouseTracker()
    private var observers: [String: (CGPoint) -> Void] = [:]
    func addMoveObserver(_ id: String, _ observer: @escaping (CGPoint) -> Void) { observers[id] = observer }
    func removeMoveObserver(_ id: String) { observers.removeValue(forKey: id) }
    func move(_ point: CGPoint) { Array(observers.values).forEach { $0(point) } }
}

@main enum HoverProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let region = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = region
        let hover = CodexMenuHover(); hover.buttonView = region
        func wait() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        func check(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL \(message)"); exit(1) }
            print("PASS \(message)")
        }
        hover.start(); wait()
        check(hover.dismissRequested, "pointer-opened menu dismisses outside")
        hover.start(keyboard: true); wait()
        check(!hover.dismissRequested, "keyboard-opened menu waits for pointer entry")
        MouseTracker.shared.move(CGPoint(x: -9950, y: -9950))
        MouseTracker.shared.move(NSEvent.mouseLocation); wait()
        check(hover.dismissRequested, "keyboard-opened menu resumes hover dismissal after entry")
        hover.start(); hover.setEditing(true); wait()
        check(!hover.dismissRequested, "search editing holds menu open")
        hover.setEditing(false); wait()
        check(hover.dismissRequested, "ending editing resumes outside dismissal")
        hover.start(); hover.stop(); wait()
        check(!hover.dismissRequested, "stopping cancels pending dismissal")
    }
}
