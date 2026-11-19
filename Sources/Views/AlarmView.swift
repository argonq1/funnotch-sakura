import SwiftUI

struct AlarmView: View {
    let back: () -> Void

    @ObservedObject private var alarm = AlarmManager.shared
    @ObservedObject private var settings = Settings.shared
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 8) {
                    Image(systemName: alarm.isRinging ? "bell.badge.fill" : "alarm")
                        .font(.system(size: 40, weight: .medium))
                    Text("Alarm").font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                button("Back", "chevron.left", action: back).padding(12)
            }
            .modifier(NotchSurface(radius: 19, opacity: 0.065, tint: .white))

            VStack(spacing: 9) {
                if alarm.isRinging {
                    action("Stop", symbol: "bell.slash.fill") { alarm.dismiss() }
                } else if let deadline = alarm.deadline {
                    Text(deadline, style: .time)
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(Calendar.current.isDateInToday(deadline) ? "Today" : "Tomorrow")
                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondaryText)
                    soundPicker
                    action("Cancel", symbol: "xmark") { alarm.cancel() }
                } else {
                    HStack {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        Spacer(minLength: 0)
                    }
                    soundPicker
                    action("Set alarm", symbol: "bell.fill") { alarm.set(time: time) }
                }
            }
            .padding(.horizontal, 14)
            .frame(width: 270)
            .frame(maxHeight: .infinity)
            .modifier(NotchSurface(radius: 19, opacity: 0.12, tint: .white))
        }
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            if let deadline = alarm.deadline { time = deadline }
        }
    }

    private var soundPicker: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AlarmTone.allCases) { tone in
                    Button {
                        settings.alarmTone = tone
                    } label: {
                        if settings.alarmTone == tone { Label(tone.rawValue, systemImage: "checkmark") }
                        else { Text(tone.rawValue) }
                    }
                }
            } label: {
                Label(settings.alarmTone.rawValue, systemImage: "music.note")
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Alarm sound")
            .accessibilityValue(settings.alarmTone.rawValue)
            Spacer(minLength: 0)
            button("Preview sound", "speaker.wave.2") { alarm.preview(settings.alarmTone) }
        }
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.08), in: Circle())
                .modifier(NotchHoverHighlight(radius: 14))
                .contentShape(Circle())
        }
        .buttonStyle(NotchPressStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    private func action(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 29)
                .foregroundStyle(.black)
                .background(.white, in: Capsule())
                .modifier(NotchHoverHighlight(tint: .black, radius: 14.5))
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
    }
}
