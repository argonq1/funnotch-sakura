import AppKit
import Combine
import Foundation

enum AlarmTone: String, CaseIterable, Identifiable {
    case glass = "Glass"
    case hero = "Hero"
    case ping = "Ping"
    case submarine = "Submarine"
    case tink = "Tink"

    var id: String { rawValue }

    func sound() -> NSSound? {
        NSSound(contentsOfFile: "/System/Library/Sounds/\(rawValue).aiff", byReference: true)
    }
}

@MainActor
final class AlarmManager: ObservableObject {
    static let shared = AlarmManager()

    @Published private(set) var deadline: Date?
    @Published private(set) var isRinging = false
    private var timer: Timer?
    private var stopRinging: Timer?
    private var sound: NSSound?

    func restore() {
        guard let date = Settings.shared.alarmDeadline else { return }
        if date.timeIntervalSinceNow > -300 {
            schedule(date)
        } else {
            Settings.shared.alarmDeadline = nil
        }
    }

    func set(time: Date) {
        guard let date = Self.nextOccurrence(of: time) else { return }
        schedule(date)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        Settings.shared.alarmDeadline = nil
        dismiss()
    }

    func preview(_ tone: AlarmTone) {
        guard !isRinging else { return }
        play(tone, repeats: false)
    }

    func dismiss() {
        stopRinging?.invalidate()
        stopRinging = nil
        sound?.stop()
        sound = nil
        isRinging = false
    }

    static func nextOccurrence(of time: Date, after now: Date = .now,
                               calendar: Calendar = .current) -> Date? {
        var match = calendar.dateComponents([.hour, .minute], from: time)
        match.second = 0
        return calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime)
    }

    private func schedule(_ date: Date) {
        timer?.invalidate()
        dismiss()
        deadline = date
        Settings.shared.alarmDeadline = date
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.ring() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func ring() {
        timer = nil
        deadline = nil
        Settings.shared.alarmDeadline = nil
        isRinging = true
        play(Settings.shared.alarmTone, repeats: true)

        let stop = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(stop, forMode: .common)
        stopRinging = stop

        FocusTabState.shared.page = .alarm
        if let model = NotchWindowManager.shared.activeViewModel {
            model.currentTab = .focus
            model.open()
        }
    }

    private func play(_ tone: AlarmTone, repeats: Bool) {
        sound?.stop()
        let next = tone.sound()
        next?.loops = repeats
        sound = next
        if next?.play() != true { NSSound.beep() }
    }
}
