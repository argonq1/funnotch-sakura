import SwiftUI

/// A short, event-driven animation. The model releases it after one flight.
struct CodexCompletionFlight: View {
    static let duration = 3.2
    let announcement: AgentSessionsManager.Announcement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Snapshot rendering samples the visible hold rather than the final fade.
    static var previewTime: Double = 1

    var body: some View {
        Group {
            if Motion.snapshotMode {
                drawn(at: Self.previewTime)
            } else {
                IntroTimeline(duration: Self.duration) { time in
                    drawn(at: time)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((announcement.session.wasInterrupted ? "Остановлено" : "Завершено")
                            + " · " + announcement.session.name)
    }

    private func drawn(at time: Double) -> some View {
        let entry = Motion.easeOut(Motion.progress(time, duration: 0.22))
        let exit = Motion.easeInOut(Motion.progress(time, delay: 2.7, duration: 0.5))
        let travel = reduceMotion ? 1 : Motion.spring(time, response: 0.48, damping: 0.74)
        let visibility = entry * (1 - exit)
        let scale = reduceMotion ? 1 : (0.28 + 0.72 * travel) * (1 - 0.2 * exit)
        let x = 48 + (reduceMotion ? 0 : 6 * travel)
        let y = 13 + 51 * travel - (reduceMotion ? 0 : 12 * exit)
        let stroke = reduceMotion ? 1 : Motion.easeOut(Motion.progress(time, delay: 0.23, duration: 0.32))

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [SakuraTheme.selectedTab, SakuraTheme.base],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NotchPalette.rim, lineWidth: 0.7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SakuraTheme.accent.opacity(0.16), lineWidth: 1)
                }
                .overlay {
                    if announcement.session.wasInterrupted || announcement.session.failure != nil {
                        Image(systemName: announcement.session.failure == nil ? "pause.fill" : "exclamationmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                    } else {
                        Path { path in
                            path.move(to: CGPoint(x: 11, y: 20))
                            path.addLine(to: CGPoint(x: 17, y: 26))
                            path.addLine(to: CGPoint(x: 30, y: 13))
                        }
                        .trim(from: 0, to: stroke)
                        .stroke(.white.opacity(0.96), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(width: 40, height: 40)
                .scaleEffect(scale)
                .opacity(visibility)
                .position(x: x, y: y)
        }
        .frame(width: 96, height: 112)
    }
}
