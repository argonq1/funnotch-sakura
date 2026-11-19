import AppKit
import SwiftUI

/// Uses the existing local/global mouse stream, including the popover's window.
/// It adds no polling timer and runs only while this menu is presented.
@MainActor
final class CodexMenuHover: ObservableObject {
    @Published private(set) var dismissRequested = false
    weak var buttonView: NSView?
    weak var menuView: NSView?

    private let observerID = "codex-menu-" + UUID().uuidString
    private var dismissal = HoverDismissal()
    private var closeWork: DispatchWorkItem?
    private var generation = 0
    private var isWatching = false
    private var isEditing = false

    func setEditing(_ value: Bool) {
        isEditing = value
        if value {
            generation += 1
            closeWork?.cancel()
            closeWork = nil
            dismissal.reset()
        } else { sample(NSEvent.mouseLocation) }
    }

    func start() {
        stop()
        dismissRequested = false
        isWatching = true
        MouseTracker.shared.addMoveObserver(observerID) { [weak self] point in self?.sample(point) }
        sample(NSEvent.mouseLocation)
    }

    func stop() {
        isWatching = false
        generation += 1
        closeWork?.cancel(); closeWork = nil
        dismissal.reset()
        MouseTracker.shared.removeMoveObserver(observerID)
    }

    private func sample(_ point: CGPoint) {
        guard isWatching, !dismissRequested, !isEditing else { return }
        var regions: [CGRect] = []
        if let view = buttonView, let window = view.window {
            regions.append(window.convertToScreen(view.convert(view.bounds, to: nil)))
        }
        if let window = menuView?.window, window.isVisible { regions.append(window.frame) }
        let now = ProcessInfo.processInfo.systemUptime
        dismissal.update(isInside: HoverDismissal.contains(point, in: regions), now: now)
        guard let deadline = dismissal.deadline else {
            generation += 1
            closeWork?.cancel(); closeWork = nil
            return
        }
        if dismissal.shouldDismiss(at: now) {
            closeWork = nil
            dismissRequested = true
            return
        }
        guard closeWork == nil else { return }
        generation += 1
        let scheduledGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isWatching, self.generation == scheduledGeneration else { return }
            self.closeWork = nil
            // Recheck the actual pointer: it may have returned without a move
            // event reaching us while the native popover was being laid out.
            self.sample(NSEvent.mouseLocation)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now), execute: work)
    }
}

/// Keeps weak references to live views so screen coordinates stay correct
/// through layout, popover placement, display scaling and window movement.
struct CodexMenuHoverRegion: NSViewRepresentable {
    let hover: CodexMenuHover
    var isMenu = false

    func makeNSView(context: Context) -> NSView {
        let view = RegionView()
        attach(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { attach(view) }

    private func attach(_ view: NSView) {
        if isMenu { hover.menuView = view }
        else { hover.buttonView = view }
    }

    private final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
