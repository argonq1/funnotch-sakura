import Foundation
import CoreGraphics

/// Leaving starts one grace period; movement outside must not postpone closing.
struct HoverDismissal {
    let gracePeriod: TimeInterval
    private(set) var deadline: TimeInterval?

    init(gracePeriod: TimeInterval = 0.4) { self.gracePeriod = gracePeriod }

    mutating func update(isInside: Bool, now: TimeInterval) {
        if isInside { deadline = nil }
        else if deadline == nil { deadline = now + gracePeriod }
    }

    mutating func reset() { deadline = nil }

    func shouldDismiss(at now: TimeInterval) -> Bool {
        deadline.map { now >= $0 } ?? false
    }

    static func contains(_ point: CGPoint, in regions: [CGRect]) -> Bool {
        regions.contains { !$0.isEmpty && $0.insetBy(dx: -6, dy: -6).contains(point) }
    }
}
