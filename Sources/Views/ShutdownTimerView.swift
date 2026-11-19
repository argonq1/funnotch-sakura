import SwiftUI

struct ShutdownTimerView: View {
    let back: () -> Void

    @ObservedObject private var timer = ShutdownTimer.shared
    @State private var minutes = "30"
    private let presets = [15, 30, 60, 120]
    private var selectedMinutes: Int? {
        guard let value = Int(minutes.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...ShutdownTimer.maximumMinutes).contains(value) else { return nil }
        return value
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.system(size: 43, weight: .medium))
                    if let status {
                        Image(systemName: status.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NotchPalette.secondaryText)
                            .help(status.label)
                            .accessibilityLabel(status.label)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Выключение Mac")

                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                        .modifier(NotchHoverHighlight(radius: 14))
                        .contentShape(Circle())
                }
                .buttonStyle(NotchPressStyle())
                .help("Назад к таймеру")
                .accessibilityLabel("Назад к таймеру")
                .padding(12)
            }
            .modifier(NotchSurface(radius: 19, opacity: 0.065, tint: .white))

            Group {
                switch timer.state {
                case let .scheduled(deadline):
                    VStack(alignment: .leading, spacing: 8) {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(TimerManager.clock(Double(timer.remainingSeconds(until: deadline))))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .accessibilityLabel("Время до выключения")
                        }
                        action("Отменить выключение", symbol: "xmark", primary: false) { timer.cancel() }
                    }
                case .idle, .requested, .failed:
                    durationControls
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
    }

    private var status: (symbol: String, label: String)? {
        switch timer.state {
        case .idle: return nil
        case .scheduled: return ("clock.badge.checkmark", "Запланировано")
        case .requested: return ("checkmark.circle", "Запрос передан macOS")
        case let .failed(code): return ("exclamationmark.triangle", "Ошибка macOS \(code)")
        }
    }

    private var durationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    Button { minutes = String(preset) } label: {
                        Text(String(format: "%d:%02d", preset / 60, preset % 60))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(selectedMinutes == preset ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .background(selectedMinutes == preset ? Color(white: 0.82) : .white.opacity(0.08),
                                        in: Capsule())
                            .modifier(NotchHoverHighlight(tint: selectedMinutes == preset ? .black : .white, radius: 12))
                            .contentShape(Capsule())
                    }.buttonStyle(NotchPressStyle()).accessibilityLabel("\(preset) мин")
                }
            }
            HStack(spacing: 6) {
                TextField("00", text: $minutes)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .frame(width: 68, height: 24)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(.white.opacity(0.17), lineWidth: 0.75)
                        .allowsHitTesting(false))
                    .help("От 1 до 1440 минут")
                    .accessibilityLabel("Через сколько минут выключить Mac")
                Text("min").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    .accessibilityHidden(true)
            }
            action("Запланировать выключение", symbol: "clock.badge.checkmark", primary: true) {
                if let selectedMinutes { timer.schedule(after: Double(selectedMinutes * 60)) }
            }
            .disabled(selectedMinutes == nil)
            .opacity(selectedMinutes == nil ? 0.45 : 1)
        }
    }

    private func action(_ title: String, symbol: String, primary: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 29)
                .foregroundStyle(primary ? .black : .white)
                .background(primary ? .white : .white.opacity(0.12), in: Capsule())
                .modifier(NotchHoverHighlight(tint: primary ? .black : .white, radius: 14.5))
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}
