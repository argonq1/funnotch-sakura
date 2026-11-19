//
//  MusicManager.swift
//  FunNotch
//
//  Owns whichever media backend is active, publishes the current track to the
//  UI, and fires the "sneak peek" when the song changes.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MusicManager: ObservableObject {
    static let shared = MusicManager()

    @Published private(set) var track = TrackInfo()
    @Published private(set) var artwork: NSImage?
    /// Colours sampled from the artwork, used to tint the player.
    @Published private(set) var artworkColor: Color = .gray
    @Published private(set) var artworkSecondaryColor: Color = .gray
    /// Continuously updated playback position for the scrubber.
    @Published var displayedElapsed: TimeInterval = 0
    /// True while the user is dragging the scrubber, so updates do not fight them.
    @Published var isScrubbing = false
    @Published private(set) var commandError: String?
    @Published private(set) var isSkipping = false
    @Published private(set) var browserTabs: [BrowserTabChoice] = []
    @Published private(set) var availableSources: [MediaControllerType] = []
    private var tickInterval: TimeInterval = 0
    private var started = false

    private var controller: MediaController?
    private var sources: [MediaControllerType: MediaController] = [:]
    private var runningSources = Set<MediaControllerType>()
    private var latest: [MediaControllerType: TrackInfo] = [:]
    private var sourceActivity: [MediaControllerType: TimeInterval] = [:]
    private var tickTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackKey = ""
    private var lastArtworkPointer: NSImage?
    /// When the active backend first went quiet, for the re-pick above.
    private var lastSourceCheck = Date.distantPast

    private let settings = Settings.shared

    private init() {}

    /// True when MediaRemote is unusable on this OS, so the UI can explain why.
    var isNowPlayingDeprecated: Bool { NowPlayingController.isDeprecated }

    var isPlaying: Bool { track.isPlaying }

    /// Icon of the app the music is coming from, for the live activity.
    var sourceAppIcon: NSImage? {
        guard let identifier = track.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.publisher(for: .mediaControllerChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.activateController() }
            .store(in: &cancellables)

        // Apps launching or quitting can change which backend is usable.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.activateController() }
            .store(in: &cancellables)

        activateController()

        SystemActivityMonitor.shared.$isIdle.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCadence() }.store(in: &cancellables)
        updateCadence()
    }

    func updateCadence() {
        guard started else { return }
        let visible = NotchWindowManager.shared.viewModels.contains {
            $0.notchState == .open && $0.currentTab == .home && !$0.hiddenForFullscreen
        }
        let interval: TimeInterval = SystemActivityMonitor.isScreenIdle ? 30 : (visible && track.isPlaying ? 0.2 : 4)
        guard interval != tickInterval else { return }
        tickTimer?.invalidate()
        tickInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval > 1 ? 0.5 : 0.05
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard !SystemActivityMonitor.isScreenIdle else { return }
        if track.isPlaying, !isScrubbing,
           NotchWindowManager.shared.viewModels.contains(where: {
               $0.notchState == .open && $0.currentTab == .home && !$0.hiddenForFullscreen
           }) {
            let elapsed = track.interpolatedElapsed
            // Publish interpolated time only while a scrubber can use it.
            if abs(elapsed - displayedElapsed) > 0.05 {
                displayedElapsed = elapsed
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastSourceCheck) > 4 {
            lastSourceCheck = now
            activateController()
        }
    }

    // MARK: - Backend selection

    private func activateController() {
        for type in MediaControllerType.allCases {
            let source: MediaController
            if let existing = sources[type] { source = existing }
            else { source = makeController(for: type); sources[type] = source }
            let available = type == .browser ? BrowserMediaController.hasRunningBrowser : source.isAvailable
            if available, !runningSources.contains(type) {
                runningSources.insert(type)
                source.onUpdate = { [weak self] info in
                    MainActor.assumeIsolated { self?.receive(info, from: type) }
                }
                DiagnosticLog.write("media", "starting source: \(type.rawValue)")
                source.start()
            } else if !available, runningSources.remove(type) != nil {
                source.stop(); source.onUpdate = nil; latest[type] = nil; sourceActivity[type] = nil
            }
        }
        chooseSource()
    }

    private func makeController(for type: MediaControllerType) -> MediaController {
        switch type {
        case .nowPlaying:
            return NowPlayingController()
        case .appleMusic, .spotify:
            return ScriptedMediaController(type: type) ?? NowPlayingController()
        case .browser:
            let browser = BrowserMediaController()
            browser.onCommandFailure = { [weak self] message in
                MainActor.assumeIsolated { self?.commandError = message }
            }
            browser.onSkipPending = { [weak self] pending in
                MainActor.assumeIsolated { self?.isSkipping = pending }
            }
            browser.onTabsChanged = { [weak self] tabs in self?.browserTabs = tabs }
            return browser
        }
    }

    private func receive(_ info: TrackInfo, from type: MediaControllerType) {
        guard runningSources.contains(type) else { return }
        let old = latest[type]
        if old?.title != info.title || old?.artist != info.artist || old?.pageURL != info.pageURL || (info.isPlaying && old?.isPlaying != true) {
            sourceActivity[type] = Date.timeIntervalSinceReferenceDate
        }
        latest[type] = info
        chooseSource()
    }
    private func chooseSource() {
        let available = MediaControllerType.allCases.filter { latest[$0]?.isEmpty == false }
        if available != availableSources { availableSources = available }
        let snapshots = latest.map { MediaSourceSelection.Snapshot(type: $0.key, track: $0.value, activity: sourceActivity[$0.key] ?? 0) }
        let locked = MediaControllerType(rawValue: settings.lockedMediaSource)
        let selected: MediaControllerType?
        if let locked { selected = latest[locked]?.isEmpty == false ? locked : nil }
        else { selected = MediaSourceSelection.select(snapshots, current: controller?.type, preferred: settings.mediaController) }
        let previous = controller?.type
        controller = selected.flatMap { sources[$0] }
        if selected != previous { isSkipping = false; commandError = nil }
        if selected != previous { DiagnosticLog.write("media", "active source: \(selected?.rawValue ?? "none")") }
        if let selected, let info = latest[selected] {
            if info != track || info.timestamp != track.timestamp { handle(info) }
        }
        else if !track.isEmpty { handle(TrackInfo()) }
    }

    /// The backend actually in use, which can differ from the user's choice.
    var activeControllerType: MediaControllerType? { controller?.type }

    func selectSource(_ type: MediaControllerType?) {
        settings.lockedMediaSource = type?.rawValue ?? ""
        if type != .browser { (sources[.browser] as? BrowserMediaController)?.selectTab(nil) }
        activateController()
    }

    func selectBrowserTab(_ id: String) {
        settings.lockedMediaSource = MediaControllerType.browser.rawValue
        (sources[.browser] as? BrowserMediaController)?.selectTab(id)
        chooseSource()
    }

    func refreshSourceChoices() {
        activateController()
        (sources[.browser] as? BrowserMediaController)?.discoverTabs()
    }

    /// Forces an immediate re-read, used after a media key is pressed.
    func refreshNow() {
        controller?.refresh()
    }

    /// Installs a fixed track without touching any backend, for snapshots.
    func injectPreviewTrack(_ info: TrackInfo) {
        track = info
        updateCadence()
        displayedElapsed = info.elapsed
        artwork = info.artwork
        updateColors(from: info.artwork)
    }

    /// Moves an injected track's playhead and play state without re-reading
    /// its artwork, for the film renderer's frame-by-frame playback.
    func injectPreviewPlayback(elapsed: TimeInterval, isPlaying: Bool) {
        track.elapsed = elapsed
        track.isPlaying = isPlaying
        displayedElapsed = elapsed
    }

    /// Clears the injected track so a snapshot can show the idle home screen,
    /// which is where the weather lives.
    func clearPreviewTrack() {
        track = TrackInfo()
        displayedElapsed = 0
        artwork = nil
        updateColors(from: nil)
    }

    // MARK: - Incoming updates

    private func handle(_ info: TrackInfo) {
        let key = "\(info.title)|\(info.artist)|\(info.album)"
        let isNewTrack = !key.isEmpty && key != lastTrackKey && !info.title.isEmpty

        track = info
        if !isScrubbing {
            displayedElapsed = info.interpolatedElapsed
        }

        if info.artwork !== lastArtworkPointer {
            lastArtworkPointer = info.artwork
            artwork = info.artwork
            updateColors(from: info.artwork)
        }

        if isNewTrack {
            lastTrackKey = key
            announceTrackChange()
        } else if key.isEmpty {
            lastTrackKey = ""
        }
    }

    private func announceTrackChange() {
        guard settings.enableSneakPeek, track.isPlaying else { return }
        NotchWindowManager.shared.broadcast { viewModel in
            guard viewModel.notchState == .closed else { return }
            viewModel.showSneakPeek(type: .music)
        }
    }

    private func updateColors(from image: NSImage?) {
        guard let image else {
            artworkColor = .gray
            artworkSecondaryColor = .gray
            return
        }
        let colors = image.dominantColors()
        artworkColor = Color(nsColor: colors.primary)
        artworkSecondaryColor = Color(nsColor: colors.secondary)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard track.capabilities.contains(.playPause) else { return }
        controller?.togglePlayPause()
        // A blocked browser command must not pretend playback changed.
        if controller?.type != .browser {
            let elapsed = track.interpolatedElapsed
            track.isPlaying.toggle()
            track.timestamp = Date()
            track.elapsed = elapsed
            if !isScrubbing { displayedElapsed = elapsed }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.controller?.refresh()
        }
    }

    func nextTrack() {
        guard !isSkipping, track.capabilities.contains(.next) else { return }
        controller?.nextTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.controller?.refresh()
        }
    }

    func previousTrack() {
        guard !isSkipping, track.capabilities.contains(.previous) else { return }
        controller?.previousTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.controller?.refresh()
        }
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, track.hasTiming, !isSkipping, track.capabilities.contains(.seek) else { return }
        let target = min(track.duration, max(0, time))
        controller?.seek(to: target)
        track.elapsed = target; track.timestamp = Date(); displayedElapsed = target
        if let type = controller?.type { latest[type] = track }
    }

    func seek(by delta: TimeInterval) {
        guard delta.isFinite else { return }
        seek(to: track.interpolatedElapsed + delta)
    }

    func toggleShuffle() {
        controller?.toggleShuffle()
        track.isShuffled.toggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.controller?.refresh()
        }
    }

    func cycleRepeat() {
        controller?.cycleRepeat()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.controller?.refresh()
        }
    }

    /// Brings the playing app to the front, like clicking the artwork does.
    func openPlayingApp() {
        if let browser = controller as? BrowserMediaController, browser.revealActiveTab() { return }
        guard let identifier = track.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
