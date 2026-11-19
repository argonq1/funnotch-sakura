//
//  SystemActivityMonitor.swift
//  FunNotch
//
//  Whether anyone is actually looking at the screen.
//
//  Polling a browser for what it is playing costs Apple Events in both
//  processes. Doing that every couple of seconds behind a lock screen is pure
//  waste, and it is exactly the sort of thing that makes a small utility show
//  up in the battery menu.
//

import AppKit
import Combine
import Foundation

@MainActor
final class SystemActivityMonitor: ObservableObject {
    static let shared = SystemActivityMonitor()

    /// True when the screen is locked, the display has slept, or the machine is
    /// going to sleep — anything that means the notch is not being watched.
    @Published private(set) var isIdle = false

    /// The same flag, readable from the polling code without hopping to the
    /// main actor. Only ever written on the main queue, and a stale read costs
    /// at most one extra poll.
    nonisolated(unsafe) private(set) static var isScreenIdle = false

    private var observers: [Any] = []
    private enum InactiveReason: Hashable { case display, sleep, lock, session }
    private var inactiveReasons = Set<InactiveReason>()

    private init() {}

    func start() {
        guard observers.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, reason: .display, idle: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, reason: .display, idle: false)
        observe(workspace, NSWorkspace.willSleepNotification, reason: .sleep, idle: true)
        observe(workspace, NSWorkspace.didWakeNotification, reason: .sleep, idle: false)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, reason: .session, idle: true)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, reason: .session, idle: false)

        // The lock screen is not a notification AppKit publishes; it comes over
        // the distributed centre, under a name Apple has never documented but
        // which every screen-lock-aware app on macOS relies on.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), reason: .lock, idle: true)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), reason: .lock, idle: false)

        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { setIdle(true, for: .display) }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if session[kCGSessionOnConsoleKey as String] as? Bool == false { setIdle(true, for: .session) }
            if session["CGSSessionScreenIsLocked"] as? Bool == true { setIdle(true, for: .lock) }
        }
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
    }

    private func observe(_ centre: NotificationCenter, _ name: Notification.Name, reason: InactiveReason, idle: Bool) {
        let observer = centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setIdle(idle, for: reason) }
        }
        observers.append(observer)
    }

    private func setIdle(_ idle: Bool, for reason: InactiveReason) {
        if idle { inactiveReasons.insert(reason) }
        else { inactiveReasons.remove(reason) }
        let inactive = !inactiveReasons.isEmpty
        guard isIdle != inactive else { return }
        Self.isScreenIdle = inactive
        isIdle = inactive
        DiagnosticLog.write("power", inactive ? "screen off, backing off polling" : "screen on, resuming")
    }
}
