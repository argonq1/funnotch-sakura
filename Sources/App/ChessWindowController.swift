import AppKit
import SwiftUI

@MainActor
final class ChessWindowController: NSObject, NSWindowDelegate {
    static let shared = ChessWindowController()

    private let session = ChessWebSession()
    private var window: NSWindow?

    func show(on screen: NSScreen?) {
        let reopening = self.window != nil
        let window = self.window ?? makeWindow()
        if !window.isVisible || window.isMiniaturized {
            let target = screen ?? window.screen ?? NSScreen.main
            if let target {
                let keepSize = reopening && window.screen == target && target.visibleFrame.contains(window.frame)
                fit(window, in: target.visibleFrame, keepSize: keepSize)
            }
        }
        session.activate()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ChessPanel(session: session).preferredColorScheme(.dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Chess.com"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    private func fit(_ window: NSWindow, in visible: NSRect, keepSize: Bool) {
        let available = visible.insetBy(dx: 16, dy: 12)
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1240, height: 820))
        let size = CGSize(width: min(frame.width, available.width), height: min(frame.height, available.height))
        let content = window.contentRect(forFrameRect: CGRect(origin: .zero, size: size)).size
        window.contentMinSize = CGSize(width: min(780, content.width), height: min(480, content.height))
        guard !keepSize else { return }
        window.setFrame(CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                               width: size.width, height: size.height).integral, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        session.hide()
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { SettingsWindowController.refreshActivationPolicy(excluding: closing) }
    }
}
