//
//  TimerManager.swift
//  FunNotch
//
//  Countdown timers.
//
//  Deliberately separate from Focus. A focus session is a commitment with
//  consequences — sites blocked, apps hidden, a length you agreed to. A timer
//  is the opposite: start it, stop it, change your mind, run it for eleven
//  seconds. Sharing state between the two would make both worse.
//

import AppKit
import Combine
import Foundation

@MainActor
final class TimerManager: ObservableObject {
    static let shared = TimerManager()

    // MARK: Countdown state

    /// Seconds left on the countdown.
    @Published private(set) var remaining: TimeInterval = 0
    /// What the countdown was set to, so the ring knows how full to be.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isCountdownRunning = false
    /// Set when a countdown reaches zero, cleared when it is acknowledged or
    /// restarted, so the view can make some noise about it.
    @Published private(set) var finished = false
    /// What the dial is set to while no countdown is running: dragging the
    /// dial or picking a preset changes it, and Start runs it.
    @Published var draft: TimeInterval = Settings.shared.timerLastDuration

    private var ticker: Timer?
    /// Wall-clock deadline rather than counting ticks down: a timer that loses
    /// a second every time the machine is busy is not a timer.
    private var deadline: Date?
    private init() {}

    /// Anything going on at all, for the quick-action tint.
    var isActive: Bool { countdownIsSet }

    /// A countdown that is running, paused part way, or has just gone off.
    var countdownIsSet: Bool { isCountdownRunning || remaining > 0 || finished }

    var endDate: Date? { isCountdownRunning ? deadline : nil }

    // MARK: - Countdown

    func start(seconds: TimeInterval) {
        let seconds = max(seconds, 1)
        duration = seconds
        remaining = seconds
        deadline = Date().addingTimeInterval(seconds)
        finished = false
        isCountdownRunning = true
        remember(seconds)
        startTicking()
    }

    /// Runs whatever the dial is set to.
    func startDraft() {
        start(seconds: draft)
    }

    func addTime(_ seconds: TimeInterval) {
        if finished {
            // "+1 min" on a timer that has gone off starts a fresh minute.
            start(seconds: seconds)
            return
        }
        guard countdownIsSet else {
            draft = min(max(draft + seconds, 60), Self.maximumDraft)
            return
        }
        if isCountdownRunning, let deadline {
            let moved = deadline.addingTimeInterval(seconds)
            self.deadline = moved
            remaining = max(moved.timeIntervalSinceNow, 0)
        } else {
            remaining = max(remaining + seconds, 0)
        }
        duration = max(duration + seconds, remaining)
    }

    func pauseCountdown() {
        guard isCountdownRunning else { return }
        remaining = max(deadline?.timeIntervalSinceNow ?? 0, 0)
        deadline = nil
        isCountdownRunning = false
        stopTickingIfIdle()
    }

    func resumeCountdown() {
        guard !isCountdownRunning, remaining > 0 else { return }
        deadline = Date().addingTimeInterval(remaining)
        isCountdownRunning = true
        startTicking()
    }

    func toggleCountdown() {
        if isCountdownRunning { pauseCountdown() } else { resumeCountdown() }
    }

    func resetCountdown() {
        isCountdownRunning = false
        finished = false
        deadline = nil
        remaining = 0
        duration = 0
        stopTickingIfIdle()
    }

    func acknowledge() {
        finished = false
        duration = 0
    }

    // MARK: - Ticking

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.015
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTickingIfIdle() {
        guard !isCountdownRunning else { return }
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isCountdownRunning, let deadline else { return }
        remaining = max(deadline.timeIntervalSinceNow, 0)
        if remaining <= 0 { complete() }
    }

    private func complete() {
        isCountdownRunning = false
        deadline = nil
        remaining = 0
        finished = true
        stopTickingIfIdle()
        NSSound(named: "Glass")?.play()
        // Bring the notch out so the alert is seen, not just heard.
        FocusTabState.shared.page = .countdown
        NotchWindowManager.shared.broadcast { model in
            model.currentTab = .focus
            model.open()
        }
    }

    // MARK: - Recent lengths

    /// The dial goes round once an hour and can be wound up to three.
    static let maximumDraft: TimeInterval = 3 * 3600

    /// Remembers a length so it can be offered again. The presets are always
    /// there, so only the lengths that are not presets are worth listing.
    private func remember(_ seconds: TimeInterval) {
        guard previewRecent == nil else { return }
        let settings = Settings.shared
        settings.timerLastDuration = seconds
        var recent = settings.timerRecentDurations.filter { abs($0 - seconds) > 0.5 }
        recent.insert(seconds, at: 0)
        settings.timerRecentDurations = Array(recent.prefix(6))
    }

    // MARK: - Preview

    /// Poses a countdown part of the way through. Nothing ticks, so the
    /// snapshot does not move underneath the renderer.
    func injectPreviewCountdown(
        duration: TimeInterval, remaining: TimeInterval, finished: Bool = false, running: Bool = true
    ) {
        self.duration = duration
        self.remaining = finished ? 0 : remaining
        self.finished = finished
        isCountdownRunning = running && !finished
        deadline = isCountdownRunning ? Date().addingTimeInterval(remaining) : nil
    }

    /// Clears everything the renderer posed.
    func clearPreview() {
        resetCountdown()
        previewRecent = nil
    }

    /// Set by the snapshot renderer so a screenshot does not show the real
    /// list.
    var previewRecent: [TimeInterval]?

    var recentDurations: [TimeInterval] {
        previewRecent ?? Settings.shared.timerRecentDurations
    }

    // MARK: - Formatting

    /// `mm:ss`, growing to `h:mm:ss` only when there are hours to show.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// A length for a button: "90 s", "5 min", "1 h 30".
    nonisolated static func shortLength(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total % 60 != 0, total < 600 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest)"
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return max(min(1 - remaining / duration, 1), 0)
    }
}
