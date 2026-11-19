//
//  FocusView.swift
//  FunNotch
//
//  Countdown and scheduled shutdown in the notch’s timer tab.
//
//  The dial is the control as well as the display. While nothing is running
//  it can be dragged round like a kitchen timer to set the length (once round
//  is an hour, and it winds on past that), and clicking the middle starts,
//  pauses and resumes.
//

import AppKit
import SwiftUI

@MainActor
final class FocusTabState: ObservableObject {
    static let shared = FocusTabState()

    enum Page { case countdown, shutdown, alarm }
    @Published var page: Page = .countdown

    private init() {}
}

enum ClockPalette {
    static let timer = Color(white: 0.88)
    static let rest = Color(red: 0.38, green: 0.9, blue: 0.66)
    static let alarm = Color.white
}

struct FocusView: View {
    /// On the home screen the tab is a tile, and may be given far less room.
    var isTile = false

    @ObservedObject private var state = FocusTabState.shared

    var body: some View {
        switch isTile ? .countdown : state.page {
        case .countdown:
            countdown
        case .shutdown:
            ShutdownTimerView { state.page = .countdown }.padding(.top, 6)
        case .alarm:
            AlarmView { state.page = .countdown }.padding(.top, 6)
        }
    }

    private var countdown: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let dial = max(0, min(size.height - (isTile ? 4 : 20), size.width - 8, 124))

            Group {
                if size.width >= 560 && !isTile {
                    HStack(spacing: 12) {
                        HStack(spacing: 14) {
                            TimeDial(size: dial)
                            TimerControls()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .modifier(NotchSurface(radius: 19, opacity: 0.065, tint: ClockPalette.timer))

                        ClockDestinations { state.page = $0 }
                        .frame(width: min(224, size.width * 0.35))
                    }
                } else if size.width >= 300 {
                    HStack(alignment: .center, spacing: 14) {
                        TimeDial(size: dial)
                        TimerControls(compact: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    TimeDial(size: dial)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .leading)
        }
        .padding(.top, isTile ? 0 : 6)
    }
}

private struct ClockDestinations: View {
    let open: (FocusTabState.Page) -> Void
    @ObservedObject private var shutdown = ShutdownTimer.shared
    @ObservedObject private var alarm = AlarmManager.shared

    var body: some View {
        VStack(spacing: 8) {
            ClockDestinationButton(symbol: shutdown.isScheduled ? "clock.badge.checkmark" : "power",
                                   hint: "Выключение Mac", active: shutdown.isScheduled) { open(.shutdown) }
            ClockDestinationButton(symbol: alarm.isRinging ? "bell.badge.fill" : "alarm",
                                   title: "Alarm", hint: "Alarm",
                                   active: alarm.deadline != nil || alarm.isRinging) { open(.alarm) }
        }
    }
}

private struct ClockDestinationButton: View {
    let symbol: String
    var title: String? = nil
    let hint: String
    let active: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
    private var tint: Color {
        active || isHovering ? .white : Color(white: 0.82)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 23, weight: .medium))
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                shape.fill(LinearGradient(
                    colors: [
                        Color(white: isHovering ? 0.28 : 0.19),
                        Color(white: isHovering ? 0.16 : 0.11),
                        Color(white: 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(tint.opacity(isHovering ? 0.43 : 0.19), lineWidth: 0.75)
                .allowsHitTesting(false))
            .contentShape(shape)
        }
        .buttonStyle(NotchPressStyle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        .help(hint)
        .accessibilityLabel(hint)
        .accessibilityValue(active ? "Активно" : "Не запланировано")
    }

}

// MARK: - Dial

/// How the dial presents the current countdown state.
private struct DialReading {
    /// How far round the current lap the arc reaches, 0 to 1.
    var fraction: Double
    /// Whole laps already wound, drawn as a full ring underneath.
    var laps = 0
    var tint: Color
    var text: String
    var symbol: String
    /// Whether dragging round the dial sets a length.
    var isAdjustable = false
    var pulses = false
}

private struct TimeDial: View {
    let size: CGFloat

    @ObservedObject private var timer = TimerManager.shared
    @EnvironmentObject private var settings: Settings

    /// Laps wound on during the current drag, and where the pointer last was,
    /// so crossing twelve o'clock can add or take off an hour.
    @State private var dragLaps: Int?
    @State private var lastFraction: Double = 0
    @State private var isHovering = false
    @State private var ringing = false

    private var ring: CGFloat { max(size * 0.065, 5) }

    var body: some View {
        let reading = self.reading
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [reading.tint.opacity(isHovering ? 0.16 : 0.09), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .padding(ring * 1.2)

            DialTicks(inset: ring + 4)

            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: ring)

            if reading.laps > 0 {
                Circle()
                    .stroke(reading.tint.opacity(0.32), lineWidth: ring)
            }

            Circle()
                .trim(from: 0, to: max(reading.fraction, 0.0001))
                .stroke(
                    AngularGradient(
                        colors: [reading.tint.opacity(0.58), reading.tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * max(reading.fraction, 0.02))
                    ),
                    style: StrokeStyle(lineWidth: ring, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .opacity(reading.fraction > 0.0005 || reading.laps > 0 ? 1 : 0)

            knob(reading)

            centre(reading)
        }
        .frame(width: size, height: size)
        .scaleEffect(ringing ? 1.035 : 1)
        .contentShape(Circle())
        .gesture(adjust, including: reading.isAdjustable ? .all : .none)
        .onTapGesture { tap() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .onChange(of: reading.pulses) { _, pulses in
            ring(pulses)
        }
        .onAppear { ring(reading.pulses) }
        .help(helpText)
    }

    // MARK: Pieces

    private func knob(_ reading: DialReading) -> some View {
        let radius = (size - ring) / 2
        let angle = reading.fraction * 2 * .pi - .pi / 2
        let visible = reading.isAdjustable || (reading.fraction > 0.001 && reading.fraction < 0.999)
        let side = reading.isAdjustable ? ring * 1.9 : ring * 0.8
        return Circle()
            .fill(reading.isAdjustable ? Color.white : Color.white.opacity(0.95))
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .overlay {
                if reading.isAdjustable {
                    Circle().fill(reading.tint).frame(width: side * 0.38, height: side * 0.38)
                }
            }
            .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            .opacity(visible ? 1 : 0)
            .scaleEffect(reading.isAdjustable && isHovering ? 1.12 : 1)
    }

    private func centre(_ reading: DialReading) -> some View {
        VStack(spacing: size * 0.012) {
            Image(systemName: reading.symbol)
                .font(.system(size: max(size * 0.085, 8), weight: .semibold))
                .foregroundStyle(reading.tint)
                .symbolEffect(.bounce, value: ringing)
            Text(reading.text)
                .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                .contentTransition(.numericText(countsDown: true))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

        }
        .frame(width: size - ring * 4)
        .animation(.easeOut(duration: 0.2), value: reading.text)
    }

    // MARK: Reading

    private var reading: DialReading {
        let tint = timer.finished ? ClockPalette.alarm : ClockPalette.timer
        if timer.finished {
            return DialReading(
                fraction: 1, tint: tint, text: "00:00",
                symbol: "bell.fill", pulses: true
            )
        }
        if timer.countdownIsSet {
            return DialReading(
                fraction: timer.duration > 0 ? timer.remaining / timer.duration : 0,
                tint: tint,
                text: TimerManager.clock(timer.remaining),
                symbol: timer.isCountdownRunning ? "timer" : "pause.fill"
            )
        }
        let (laps, fraction) = Self.wound(timer.draft / 3600)
        return DialReading(
            fraction: fraction, laps: laps, tint: tint,
            text: TimerManager.clock(timer.draft),
            symbol: "timer",
            isAdjustable: true
        )
    }

    /// Splits hours into laps round the dial and how far into the next one.
    /// Exactly on the hour reads as a full ring, not an empty one.
    static func wound(_ hours: Double) -> (Int, Double) {
        let laps = Int(hours)
        let fraction = hours - Double(laps)
        if fraction < 0.0001, laps > 0 { return (laps - 1, 1) }
        return (laps, fraction)
    }

    private var helpText: String {
        if timer.finished { return "Нажми, чтобы закрыть" }
        if timer.countdownIsSet { return timer.isCountdownRunning ? "Нажми для паузы" : "Нажми, чтобы продолжить" }
        return "Поверни, чтобы задать время · нажми, чтобы начать"
    }

    private func tap() {
        if timer.finished {
            timer.acknowledge()
        } else if timer.countdownIsSet {
            timer.toggleCountdown()
        } else {
            timer.startDraft()
        }
    }

    /// Dragging round the ring, like winding a kitchen timer.
    private var adjust: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let dx = value.location.x - size / 2
                let dy = value.location.y - size / 2
                guard hypot(dx, dy) > size * 0.16 else { return }
                var fraction = atan2(dx, -dy) / (2 * .pi)
                if fraction < 0 { fraction += 1 }

                if dragLaps == nil {
                    dragLaps = currentLaps
                    lastFraction = fraction
                }
                var laps = dragLaps ?? 0
                if lastFraction > 0.75, fraction < 0.25 { laps += 1 }
                if lastFraction < 0.25, fraction > 0.75 { laps -= 1 }
                dragLaps = laps
                lastFraction = fraction
                set(hours: Double(laps) + fraction)
            }
            .onEnded { _ in dragLaps = nil }
    }

    private var currentLaps: Int { Self.wound(timer.draft / 3600).0 }

    private func set(hours: Double) {
        let minutes = min(max((hours * 60).rounded(), 1), TimerManager.maximumDraft / 60)
        let seconds = minutes * 60
        guard seconds != timer.draft else { return }
        timer.draft = seconds
        tick()
    }

    /// A detent under the finger on a Force Touch trackpad.
    private func tick() {
        guard settings.enableHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func ring(_ pulses: Bool) {
        guard pulses else {
            withAnimation(.easeOut(duration: 0.2)) { ringing = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
            ringing = true
        }
    }
}

/// Minute marks round the inside of the ring, every fifth one longer.
private struct DialTicks: View {
    let inset: CGFloat

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = size.width / 2 - inset
            for index in 0 ..< 60 {
                let major = index % 5 == 0
                let length: CGFloat = major ? 4 : 2
                let angle = CGFloat(index) / 60 * 2 * .pi - .pi / 2
                let dx: CGFloat = cos(angle)
                let dy: CGFloat = sin(angle)
                var path = Path()
                path.move(to: CGPoint(x: centre.x + dx * outer, y: centre.y + dy * outer))
                path.addLine(to: CGPoint(x: centre.x + dx * (outer - length), y: centre.y + dy * (outer - length)))
                context.stroke(path, with: .color(.white.opacity(major ? 0.26 : 0.1)),
                               style: StrokeStyle(lineWidth: major ? 1.2 : 0.8, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Timer

private struct TimerControls: View {
    var compact = false

    @ObservedObject private var timer = TimerManager.shared

    private let presets: [TimeInterval] = [60, 180, 300, 600, 900, 1800]

    var body: some View {
        if timer.finished {
            finished
        } else if timer.countdownIsSet {
            running
        } else {
            idle
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClockButton(title: "Старт", symbol: "play.fill", style: .primary, tint: ClockPalette.timer) {
                    timer.startDraft()
                }
                StepButton(symbol: "minus", help: "Убавить минуту") { timer.addTime(-60) }
                StepButton(symbol: "plus", help: "Добавить минуту") { timer.addTime(60) }
                Spacer(minLength: 4)
                recentTimers
            }

            HStack(spacing: 4) {
                ForEach(compact ? Array(presets.prefix(4)) : presets, id: \.self) { seconds in
                    PresetChip(title: "\(Int(seconds) / 60)", help: "Запустить на \(Int(seconds) / 60) мин") {
                        timer.start(seconds: seconds)
                    }
                }
                Text("min")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NotchPalette.secondaryText)
                    .accessibilityHidden(true)

            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClockButton(
                    title: timer.isCountdownRunning ? "Пауза" : "Продолжить",
                    symbol: timer.isCountdownRunning ? "pause.fill" : "play.fill",
                    style: .primary,
                    tint: ClockPalette.timer
                ) {
                    timer.toggleCountdown()
                }
                ClockButton(title: "1 мин", symbol: "plus", style: .secondary) { timer.addTime(60) }
                ClockButton(title: "Сброс", symbol: "xmark", style: .destructive) {
                    timer.resetCountdown()
                }
            }
            ProgressLine(progress: timer.progress, tint: ClockPalette.timer)
                .frame(height: 4)
                .frame(maxWidth: 240)
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClockButton(title: "Готово", symbol: "checkmark", style: .primary, tint: ClockPalette.alarm) {
                    timer.acknowledge()
                }
                ClockButton(title: "1 мин", symbol: "plus", style: .secondary) { timer.addTime(60) }
                ClockButton(title: "Снова", symbol: "arrow.counterclockwise", style: .secondary) {
                    timer.start(seconds: max(timer.duration, 60))
                }
            }
        }
    }

    @ViewBuilder
    private var recentTimers: some View {
        if !compact, !timer.recentDurations.isEmpty {
            Menu {
                ForEach(timer.recentDurations, id: \.self) { seconds in
                    Button(TimerManager.clock(seconds)) { timer.start(seconds: seconds) }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Недавние таймеры")
            .accessibilityLabel("Недавние таймеры")
        }
    }
}

// MARK: - Controls

/// Tinted pill buttons, in the style of the Clock app: a wash of the colour
/// behind a label in the colour itself.
private struct ClockButton: View {
    enum Style { case primary, secondary, destructive }

    let title: String
    let symbol: String
    var style: Style = .secondary
    var tint: Color = .white
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: style == .primary ? 44 : 28, height: 28)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .help(title)
        .accessibilityLabel(title)
        .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .primary: return .black
        case .secondary: return .white.opacity(isHovering ? 1 : 0.85)
        case .destructive: return .white.opacity(isHovering ? 1 : 0.72)
        }
    }

    private var background: Color {
        switch style {
        case .primary: return isHovering ? .white : tint
        case .secondary: return .white.opacity(isHovering ? 0.16 : 0.09)
        case .destructive: return .white.opacity(isHovering ? 0.15 : 0.05)
        }
    }
}

/// Shrinks a touch while held, so a click is felt as well as seen.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct StepButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 25, height: 25)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .help(help)
    }
}

private struct PresetChip: View {
    let title: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.75))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(isHovering ? 0.15 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .help(help)
    }
}

private struct ProgressLine: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.6), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.width * progress, proxy.size.height))
            }
        }
    }
}
