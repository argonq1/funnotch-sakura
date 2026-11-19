import Foundation

@main
enum HoverDismissalTests {
    static func main() {
        var failures = 0
        func check(_ label: String, _ passed: Bool) {
            print("[\(passed ? "PASS" : "FAIL")] \(label)")
            if !passed { failures += 1 }
        }
        let button = CGRect(x: 100, y: 800, width: 150, height: 32)
        let menu = CGRect(x: 60, y: 350, width: 350, height: 440)
        let regions = [button, menu]
        check("the Codex button keeps the menu open", HoverDismissal.contains(CGPoint(x: 180, y: 810), in: regions))
        check("the entire chat menu keeps it open", HoverDismissal.contains(CGPoint(x: 390, y: 370), in: regions))
        check("the small arrow gap is forgiving", HoverDismissal.contains(CGPoint(x: 180, y: 795), in: regions))
        check("moving to another part of the screen leaves both regions", !HoverDismissal.contains(CGPoint(x: 700, y: 500), in: regions))
        check("an unmounted view cannot keep the menu open", !HoverDismissal.contains(.zero, in: [.zero]))

        var hover = HoverDismissal()
        hover.update(isInside: true, now: 10)
        check("hovering does not schedule dismissal", hover.deadline == nil && !hover.shouldDismiss(at: 100))
        hover.update(isInside: false, now: 20)
        check("leaving grants time to reach the popover", !hover.shouldDismiss(at: 20.2))
        let firstDeadline = hover.deadline
        hover.update(isInside: false, now: 20.3)
        check("continuous movement outside cannot postpone closing", hover.deadline == firstDeadline)
        check("the menu closes after the grace period", hover.shouldDismiss(at: 20.5))
        hover.update(isInside: true, now: 20.35)
        check("entering the chat list cancels a pending close", hover.deadline == nil && !hover.shouldDismiss(at: 21))
        hover.update(isInside: false, now: 22)
        check("leaving the list starts a new grace period", !hover.shouldDismiss(at: 22.2) && hover.shouldDismiss(at: 22.5))
        hover.reset()
        check("closing or reopening clears the old deadline", hover.deadline == nil && !hover.shouldDismiss(at: 100))
        exit(failures == 0 ? 0 : 1)
    }
}
