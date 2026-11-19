import AppKit
import SwiftUI

/// A native poster player on Home. The browser owns video playback; the
/// notch holds one bounded still image and the existing transport controls.
struct HomeMediaPlayer: View {
    let availableWidth: CGFloat
    var availableHeight: CGFloat = 96
    /// A nonzero width opts into the full Home poster and its right overlay.
    var sidebarWidth: CGFloat = 0
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var settings = Settings.shared
    private var narrow: Bool { availableWidth < 280 }
    private var hasTrack: Bool { !music.track.isEmpty }
    private var accent: Color { hasTrack ? music.artworkColor : .white.opacity(0.4) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasTrack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.track.title)
                        .font(.system(size: sidebarWidth > 0 ? 14 : 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(sidebarWidth > 0 ? 1 : 2).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(music.track.title)
                    if !music.track.artist.isEmpty {
                        Text(music.track.artist)
                            .font(.system(size: 10))
                            .foregroundStyle(NotchPalette.secondaryText)
                            .lineLimit(1)
                    }
                }.padding(.trailing, sidebarWidth > 0 ? sidebarWidth + 12 : 0)
                Spacer(minLength: 0)
                if sidebarWidth == 0 {
                    transport.overlay(alignment: .trailing) { sourceButton }
                }
                timeline.padding(.top, sidebarWidth > 0 ? 6 : 4)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "music.note")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(SakuraTheme.accent)
                        .frame(width: 38, height: 38)
                        .modifier(NotchSurface(radius: 13))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, sidebarWidth)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Пока ничего не играет")
            }
        }
        .padding(.horizontal, sidebarWidth > 0 ? 14 : 8)
        .padding(.vertical, sidebarWidth > 0 ? 12 : 5)
        .frame(width: availableWidth, height: availableHeight)
        .background { poster }
        .overlay {
            if hasTrack && sidebarWidth > 0 { transport }
        }
        .overlay(alignment: .bottomTrailing) {
            if sidebarWidth > 0 {
                sourceButton.padding(.trailing, 14).padding(.bottom, 30)
            }
        }
        .overlay(alignment: .topTrailing) {
            if sidebarWidth > 0 {
                HomePlayerSidebar().frame(width: sidebarWidth)
                    .padding(.top, 12).padding(.trailing, 14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(NotchPalette.rim, lineWidth: 0.7).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Плеер на главной")
    }

    private var poster: some View {
        ZStack {
            SakuraTheme.panel
            if hasTrack, let image = music.artwork {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: availableWidth, height: availableHeight)
                    .clipped()
                    .accessibilityLabel("Превью: \(music.track.title)")
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.76), location: 0),
                    .init(color: .black.opacity(0.54), location: 0.22),
                    .init(color: .clear, location: 0.49),
                    .init(color: .clear, location: 0.69),
                    .init(color: .black.opacity(0.70), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            } else {
                SakuraBlossoms(width: min(availableWidth * 0.75, 440), height: availableHeight, opacity: 0.65)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                LinearGradient(colors: [SakuraTheme.accent.opacity(0.08), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.allowsHitTesting(false)
    }

    private var transport: some View {
        HStack(spacing: sidebarWidth > 0 ? 16 : 6) {
            playerButton("gobackward.10", "Назад на 10 секунд", size: 15) { music.seek(by: -10) }
                .disabled(!canSeek).opacity(canSeek ? 1 : 0.3)
            if !narrow {
                playerButton("backward.end.fill", "Предыдущий трек", size: 18) { music.previousTrack() }
                    .disabled(music.isSkipping || !music.track.capabilities.contains(.previous))
            }
            playerButton(music.isPlaying ? "pause.fill" : "play.fill", music.isPlaying ? "Пауза" : "Воспроизвести", size: 24, prominent: true) { music.togglePlayPause() }
                .disabled(!music.track.capabilities.contains(.playPause))
            if !narrow {
                playerButton("forward.end.fill", "Следующий трек", size: 18) { music.nextTrack() }
                    .disabled(music.isSkipping || !music.track.capabilities.contains(.next))
            }
            playerButton("goforward.10", "Вперёд на 10 секунд", size: 15) { music.seek(by: 10) }
                .disabled(!canSeek).opacity(canSeek ? 1 : 0.3)
        }
        .padding(.horizontal, sidebarWidth > 0 ? 10 : 0)
        .padding(.vertical, sidebarWidth > 0 ? 4 : 0)
        .background {
            if sidebarWidth > 0 {
                Capsule().fill(.black.opacity(0.22))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            }
        }
        .frame(maxWidth: .infinity).disabled(!hasTrack)
    }

    private var sourceButton: some View {
        HStack(spacing: 4) {
            MediaSourceMenu()
            AudioOutputMenu()
            if music.track.isYouTube {
                Button { music.openPlayingApp() } label: {
                    YouTubeMark().frame(width: 18, height: 12.5)
                        .frame(width: 23, height: 23).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Открыть YouTube")
                    .accessibilityLabel("Открыть ролик в YouTube")
            } else {
                Button { music.openPlayingApp() } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8)).frame(width: 23, height: 23).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Открыть источник").accessibilityLabel("Открыть источник")
            }
        }
    }
    private var canSeek: Bool { music.track.hasTiming && music.track.capabilities.contains(.seek) && !music.isSkipping }
    private func playerButton(_ symbol: String, _ title: String, size: CGFloat, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        let diameter: CGFloat = sidebarWidth > 0 ? (prominent ? 46 : 32) : (prominent ? 30 : 23)
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: sidebarWidth > 0 ? size : size * 0.7, weight: .semibold))
                .offset(x: symbol == "play.fill" ? 1 : 0)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: diameter, height: diameter)
                .background {
                    if prominent { Circle().fill(NotchPalette.selection) }
                }
                .modifier(NotchHoverHighlight(tint: prominent ? .black : .white, radius: diameter / 2))
                .contentShape(Circle())
        }.buttonStyle(NotchPressStyle()).help(title).accessibilityLabel(title)
    }
    @ViewBuilder private var timeline: some View {
        if music.isSkipping {
            Image(systemName: "ellipsis")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).frame(height: 12)
                .accessibilityLabel("Переключаю")
        } else if let error = music.commandError {
            Button { SettingsWindowController.shared.show(tab: .media) } label: {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }.buttonStyle(.plain).frame(height: 12).help(error).accessibilityLabel(error)
        } else if canSeek {
            HStack(spacing: 5) {
                Text(music.displayedElapsed.playbackTimestamp)
                NotchSlider(value: Binding(get: { music.displayedElapsed }, set: { music.displayedElapsed = $0 }),
                    range: 0 ... max(1, music.track.duration), color: settings.sliderColor.resolved(albumArt: accent, accent: settings.accentColor),
                    height: 3, onEditingChanged: { editing in
                        music.isScrubbing = editing
                        if !editing { music.seek(to: music.displayedElapsed) }
                    })
                    .accessibilityLabel("Позиция воспроизведения")
                    .accessibilityValue(music.displayedElapsed.playbackTimestamp)
                    .accessibilityAdjustableAction { direction in
                        if direction == .increment { music.seek(by: 10) }
                        else if direction == .decrement { music.seek(by: -10) }
                    }
                Text(music.track.duration.playbackTimestamp)
            }.font(.system(size: 8)).monospacedDigit().foregroundStyle(.white.opacity(0.76)).frame(height: 12)
        } else if hasTrack && music.activeControllerType == .browser && settings.showPageAccessHint {
            Button { SettingsWindowController.shared.show(tab: .media) } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }.buttonStyle(.plain).frame(height: 12)
                .help("Для кнопок и перемотки нужен доступ к странице")
                .accessibilityLabel("Настроить доступ к странице")
        } else {
            Color.clear.frame(height: 12)
        }
    }
}

/// Small native vector mark; no downloaded image or extra media process.
private struct YouTubeMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(Color(red: 1, green: 0, blue: 0))
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: 7.1, y: 3.1))
                    path.addLine(to: CGPoint(x: 12.3, y: 6.25))
                    path.addLine(to: CGPoint(x: 7.1, y: 9.4))
                    path.closeSubpath()
                }.fill(.white)
            }
            .accessibilityHidden(true)
    }
}

private struct HomePlayerSidebar: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            WeatherPane(compact: true, integrated: true).frame(height: 46)
            HomeSystemStatsLine()
        }
        .padding(7).background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NotchPalette.rim, lineWidth: 0.5))
    }
}

/// Reuses the existing three-second sampler. No charts or extra frame timer.
private struct HomeSystemStatsLine: View {
    @ObservedObject private var stats = SystemStatsManager.shared
    @EnvironmentObject private var viewModel: NotchViewModel
    @State private var hovering = false
    var body: some View {
        Button {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
                ?? URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            viewModel.close()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").foregroundStyle(.white.opacity(0.55))
                Text(stats.cpuText).foregroundStyle(.white.opacity(0.9))
                Text("·").foregroundStyle(.white.opacity(0.35))
                Image(systemName: "memorychip").foregroundStyle(.white.opacity(0.55))
                Text(stats.memoryText).foregroundStyle(.white.opacity(0.9))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced)).monospacedDigit()
            .padding(.horizontal, 7).frame(minHeight: 24)
            .background(.black.opacity(hovering ? 0.68 : 0.52), in: Capsule())
            .overlay(Capsule().strokeBorder(NotchPalette.rim, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .help("Открыть Мониторинг системы")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Открыть Мониторинг системы. CPU \(stats.cpuText), память \(stats.memoryText)")
        .onAppear { stats.addSubscriber() }
        .onDisappear { stats.removeSubscriber() }
    }
}
