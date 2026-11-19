//
//  OpenNotchView.swift
//  FunNotch
//
//  The expanded panel: a header that straddles the camera housing, then either
//  the home view (player, agenda, mirror) or the shelf.
//

import AppKit
import SwiftUI

struct OpenNotchView: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(spacing: 0) {
            NotchHeader()
                .frame(height: max(viewModel.closedNotchSize.height, 30))

            Group {
                switch viewModel.currentTab {
                case .home:
                    NotchHomeView()
                case .shelf:
                    ShelfView()
                case .clipboard:
                    ClipboardView()
                case .focus:
                    FocusView()
                case .notes:
                    NotchHomeView()
                case .game:
                    // Belt and braces: the tab is already gone from the header
                    // during a session, but nothing should be able to land here
                    // and start a game anyway.
                    if FocusManager.shared.isActive {
                        GameBlockedDuringFocus()
                    } else {
                        GameView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .modifier(NotchReveal())
        }
        // Generous insets so nothing runs into the rounded corners.
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .animation(.notchContent, value: viewModel.currentTab)
    }
}

/// Stands in for the game while a focus session is running.
private struct GameBlockedDuringFocus: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @ObservedObject private var focus = FocusManager.shared

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
            Text("Not while you're focusing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("The games come back in \(focus.compactRemainingText).")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Button("Take me to the timer") {
                FocusTabState.shared.page = .countdown
                withAnimation(.notchContent) { viewModel.currentTab = .focus }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Header row. The middle is left empty so nothing ever hides behind the camera.
struct NotchHeader: View {
    @EnvironmentObject private var viewModel: NotchViewModel
    @EnvironmentObject private var settings: Settings
    @ObservedObject private var calendar = CalendarManager.shared
    @ObservedObject private var focus = FocusManager.shared
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Self.tabSpacing) {
                ForEach(availableTabs) { tab in
                    TabChip(
                        tab: tab,
                        selection: selection,
                        isSelected: viewModel.currentTab == tab,
                        width: Self.tabWidth(
                            count: availableTabs.count, cutoutWidth: viewModel.closedNotchSize.width
                        )
                    ) {
                        withAnimation(.notchContent) { viewModel.currentTab = tab }
                    }
                }
            }
            .padding(3)
            .modifier(NotchSurface(radius: 14, tint: .white))
            .frame(maxWidth: .infinity, alignment: .leading)

            if !viewModel.usesPhysicalCutout {
                Color.clear.frame(width: viewModel.closedNotchSize.width)
            }

            HStack(spacing: 6) {
                Spacer(minLength: 0)

                if viewModel.showsCodexMenu && !viewModel.usesPhysicalCutout {
                    ActiveCodexBadge()
                } else if settings.showBatteryIndicator && !viewModel.showsCodexMenu {
                    BatteryPill()
                }

                // Sits beside the gear: the home screen is the thing you are
                // looking at when you decide you want it rearranged, so the way
                // to rearrange it belongs here rather than three levels into
                // Settings.
                HStack(spacing: 2) {
                    HoverButton(systemName: "square.grid.2x2", size: 13, padding: 5) {
                        CustomizeWindowController.shared.show(tab: .home)
                        viewModel.close()
                    }
                    .help("Настроить чёлку")
                    .accessibilityLabel("Настроить чёлку")

                    HoverButton(systemName: "gearshape", size: 13, padding: 5) {
                        SettingsWindowController.shared.show()
                        viewModel.close()
                    }
                    .help("Настройки")
                    .accessibilityLabel("Настройки")
                }
                .padding(.horizontal, 3)
                .modifier(NotchSurface(radius: 12, opacity: 0.06, tint: .white))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    static let tabSpacing: CGFloat = 4

    /// Width of one tab button, chosen so every tab fits on its side of the
    /// camera. They used to size themselves, and seven of them ran past the
    /// edge of the cutout: the last one, Game, sat under the camera housing
    /// where it could not be seen or clicked.
    static func tabWidth(count: Int, cutoutWidth: CGFloat) -> CGFloat {
        // The space left of the cutout, less a margin so nothing hugs the
        // camera's edge.
        let side = (openNotchSize.width - 44 - cutoutWidth) / 2 - 8
        let tabs = CGFloat(max(count, 1))
        return max(min(34, (side - (tabs - 1) * tabSpacing) / tabs), 20)
    }

    private var availableTabs: [NotchTab] {
        NotchTab.allCases.filter { tab in
            switch tab {
            case .shelf: return settings.shelfEnabled
            case .clipboard: return settings.clipboardHistoryEnabled
            case .notes: return false
            // A focus session is a promise not to get distracted, and a game in
            // the notch is the most distracting thing in here.
            case .game: return !FocusManager.shared.isActive
            default: return true
            }
        }
    }
}

private struct TabChip: View {
    let tab: NotchTab
    let selection: Namespace.ID
    let isSelected: Bool
    let width: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: tab.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? .white : NotchPalette.secondaryText)
            .frame(width: width)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    Capsule()
                        .fill(SakuraTheme.selectedTab)
                        .overlay(Capsule().strokeBorder(SakuraTheme.accent.opacity(0.31), lineWidth: 0.75))
                        .matchedGeometryEffect(id: "selected-tab", in: selection)
                } else if isHovering { Capsule().fill(.white.opacity(0.08)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Home

struct NotchHomeView: View {
    var body: some View {
        HomeGridView()
    }
}

struct AlbumArtwork: View {
    @ObservedObject private var music = MusicManager.shared
    @EnvironmentObject private var settings: Settings
    @State private var isHovering = false

    private let side = MusicPlayerImageSizes.size.opened.width

    var body: some View {
        Button {
            music.openPlayingApp()
        } label: {
            ZStack {
                if let artwork = music.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.6))
                }

                if isHovering {
                    Color.black.opacity(0.45)
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.opened))
            .overlay(
                RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.opened)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .disabled(music.track.bundleIdentifier == nil)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .overlay(alignment: .bottomTrailing) {
            if let icon = music.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: 5, y: 5)
                    .shadow(radius: 2)
            }
        }
    }
}

struct PlayerControls: View {
    @ObservedObject private var music = MusicManager.shared
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if music.track.isEmpty {
                emptyState
            } else {
                MarqueeText(text: music.track.title, font: .system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                MarqueeText(text: music.track.artist, font: .system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))

                if music.track.hasTiming {
                    scrubber
                } else {
                    noTimingHint
                }
                transport
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing playing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var hintText: String {
        if music.isNowPlayingDeprecated, settings.mediaController == .nowPlaying {
            return "macOS no longer exposes system-wide Now Playing. Pick Music or Spotify in Settings."
        }
        return "Start playing something in \(settings.mediaController.rawValue)."
    }

    /// Shown instead of the scrubber when the backend cannot report a
    /// position — a browser tab whose page we are not allowed to query. It
    /// stays on one line and leads somewhere, rather than being a paragraph of
    /// instructions sitting permanently under every track.
    @ViewBuilder
    private var noTimingHint: some View {
        if !settings.showPageAccessHint {
            // Switched off in settings: leave the space blank rather than
            // repeating something the user has already said they know about.
            Color.clear.frame(height: 20)
        } else if music.activeControllerType == .browser {
            Button {
                SettingsWindowController.shared.show(tab: .media)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("Turn on page access for progress")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        } else {
            Text("No position reported")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 6)
        }
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            NotchSlider(
                value: Binding(
                    get: { music.displayedElapsed },
                    set: { music.displayedElapsed = $0 }
                ),
                range: 0 ... max(music.track.duration, 1),
                color: sliderColor,
                height: 4,
                isEnabled: music.track.duration > 0,
                onEditingChanged: { editing in
                    music.isScrubbing = editing
                    if !editing {
                        music.seek(to: music.displayedElapsed)
                    }
                }
            )
            .frame(height: 12)

            HStack {
                Text(music.displayedElapsed.playbackTimestamp)
                Spacer()
                Text(max(music.track.duration - music.displayedElapsed, 0).playbackTimestamp)
            }
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 2)
    }

    private var sliderColor: Color {
        settings.sliderColor.resolved(albumArt: music.artworkColor, accent: settings.accentColor)
    }

    private var transport: some View {
        HStack(spacing: 2) {
            if settings.showShuffleAndRepeat {
                HoverButton(
                    systemName: "shuffle",
                    size: 12,
                    padding: 5,
                    isActive: music.track.isShuffled,
                    tint: settings.accentColor
                ) { music.toggleShuffle() }
            }

            Spacer(minLength: 0)

            HoverButton(systemName: "backward.fill", size: 14, padding: 6) {
                music.previousTrack()
            }

            HoverButton(
                systemName: music.isPlaying ? "pause.fill" : "play.fill",
                size: 18,
                padding: 7
            ) { music.togglePlayPause() }

            HoverButton(systemName: "forward.fill", size: 14, padding: 6) {
                music.nextTrack()
            }

            Spacer(minLength: 0)

            if settings.showShuffleAndRepeat {
                HoverButton(
                    systemName: music.track.repeatMode.symbol,
                    size: 12,
                    padding: 5,
                    isActive: music.track.repeatMode != .off,
                    tint: settings.accentColor,
                    badge: music.track.repeatMode.badge
                ) { music.cycleRepeat() }
            }
        }
    }
}

// MARK: - Mirror

struct MirrorPane: View {
    @ObservedObject private var webcam = WebcamManager.shared
    @EnvironmentObject private var settings: Settings

    var body: some View {
        Group {
            if webcam.isRunning {
                CameraPreview(session: webcam.session)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    VStack(spacing: 5) {
                        Image(systemName: webcam.hasCamera ? "web.camera" : "video.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(webcam.hasCamera ? "Mirror" : "No camera")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(mirrorShape)
        .overlay(mirrorShape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        .onAppear { webcam.start() }
        .onDisappear { webcam.stop() }
    }

    private var mirrorShape: AnyShape {
        settings.mirrorShape == .circle
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 12))
    }
}
