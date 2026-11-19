//
//  PreviewRenderer.swift
//  FunNotch
//
//  Development aid: `FunNotch --render-preview <directory>` renders each
//  notch state to a PNG and exits, so layout can be checked without screen
//  recording permission.
//

import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func homeDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-home-preview"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    static func renderHome(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Motion.snapshotMode = true
        PixelWeatherView.frozenTime = 1000.4
        HomeLayout.filmTiles = HomeLayout.default
        WeatherManager.shared.injectPreviewConditions(temperatureCelsius: 6, weatherCode: 3, isDay: false, placeName: "Минск")
        func next(_ index: Int) {
            guard index < 4 else { HomeLayout.filmTiles = nil; NSApp.terminate(nil); return }
            var track = sampleTrack()
            if index != 1 {
                track.title = "Ночной город — прогулка под дождём"
                track.artist = "Urban Walks"
                track.sourceName = "YouTube"
                track.pageURL = URL(string: "https://www.youtube.com/watch?v=preview123")
                track.duration = index == 3 ? 0 : 728
                track.artwork = syntheticVideoArtwork()
            }
            if index == 2 { MusicManager.shared.clearPreviewTrack() }
            else { MusicManager.shared.injectPreviewTrack(track) }
            let model = NotchViewModel(screen: NSScreen.main)
            model.previewOpen(); model.currentTab = .home
            let root = ContentView().environmentObject(model).environmentObject(Settings.shared)
            render(root: root, to: directory.appendingPathComponent(["home-youtube", "home-music", "home-idle", "home-no-timing"][index] + ".png")) { next(index + 1) }
        }
        next(0)
    }

    private static func syntheticVideoArtwork() -> NSImage {
        let size = NSSize(width: 320, height: 180)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: 4); transform.concat()
        NSGradient(colors: [.init(srgbRed: 0.08, green: 0.10, blue: 0.24, alpha: 1),
                            .init(srgbRed: 0.28, green: 0.12, blue: 0.25, alpha: 1)])?.draw(in: NSRect(origin: .zero, size: size), angle: 80)
        for i in 0 ..< 12 {
            let x = CGFloat(i * 29), height = CGFloat(25 + (i * 37) % 70)
            NSColor(srgbRed: 0.03, green: 0.04, blue: 0.08, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 58, width: 24, height: height)).fill()
            NSColor.systemOrange.withAlphaComponent(0.6).setFill()
            for y in stride(from: 65, through: Int(58 + height - 8), by: 12) {
                NSBezierPath(rect: NSRect(x: x + 6, y: CGFloat(y), width: 3, height: 5)).fill()
            }
        }
        NSColor(srgbRed: 0.04, green: 0.055, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 58)).fill()
        for i in 0 ..< 10 {
            NSColor.systemPink.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(i * 35), y: 12, width: 5, height: 38)).fill()
        }
        let text: NSString = "NIGHT WALK"
        text.draw(at: NSPoint(x: 16, y: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .heavy), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 1280, height: 720))
        image.addRepresentation(bitmap)
        return image
    }

    /// Returns the output directory if the app was launched in preview mode.
    static func requestedDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-preview"),
              index + 1 < arguments.count
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func gameDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-game-preview"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func agentDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-agent-preview"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func activeAgentsDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-active-agents-preview"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    static func renderActiveAgents(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Motion.snapshotMode = true
        let settings = Settings.shared
        let saved = (settings.agentActivityEnabled, settings.idleWidgetsEnabled, settings.idleLeftWidgets, settings.idleRightWidgets)
        settings.agentActivityEnabled = true
        let now = Date()
        let names = ["Flappy Bird и чёлка", "Проверить курсовую работу", "Обновить таблицу расходов"]
        let sessions = names.enumerated().map { i, name in
            AgentSessionsManager.Session(id: "preview-codex-\(i)", agent: .codex, name: name, project: i == 0 ? "Mac" : "Документы",
                status: .working, statusSince: now.addingTimeInterval(-Double(100 + i * 30)),
                turnStartedAt: now.addingTimeInterval(-Double(100 + i * 30)), lastTurnDuration: nil, startedAt: now, pid: nil, host: .codexApp,
                activeTurnID: "preview-turn-\(i)")
        }
        AgentSessionsManager.shared.injectPreviewSessions(sessions)
        func next(_ index: Int) {
            guard index < 3 else {
                settings.agentActivityEnabled = saved.0; settings.idleWidgetsEnabled = saved.1
                settings.idleLeftWidgets = saved.2; settings.idleRightWidgets = saved.3
                NSApp.terminate(nil); return
            }
            if index == 2 {
                let recent = ["Настроить медиаплеер", "Проверить нагрузку на Mac", "Обновить гонки"].enumerated().map { i, name in
                    AgentSessionsManager.Session(id: "preview-codex-recent-\(i)", agent: .codex,
                        name: name, project: "Mac", status: .idle, statusSince: now.addingTimeInterval(-Double(60 + i * 40)),
                        turnStartedAt: nil, lastTurnDuration: 180, startedAt: now, pid: nil, host: .codexApp,
                        wasInterrupted: i == 1)
                }
                var active = sessions
                active[2].status = .waiting("Нужен ответ")
                AgentSessionsManager.shared.injectPreviewSessions(active + recent)
                render(root: ActiveCodexList(), size: CGSize(width: 340, height: 307),
                       appearance: NSAppearance(named: .darkAqua), to: directory.appendingPathComponent("codex-active-list.png")) { next(index + 1) }
                return
            }
            settings.idleWidgetsEnabled = index == 0
            settings.idleLeftWidgets = [.clock]; settings.idleRightWidgets = [.battery]
            let model = NotchViewModel(screen: NSScreen.main)
            model.setPreviewMusicActivity(false)
            model.setPreviewFocusActivity(false)
            model.setPreviewAgentActivity(AgentActivity(active: 3, waiting: false, codexNames: names))
            if index == 1 { model.previewOpen() }
            let root = ContentView().environmentObject(model).environmentObject(settings)
            render(root: root, to: directory.appendingPathComponent(index == 0 ? "codex-closed-cutout.png" : "codex-open-header.png")) {
                next(index + 1)
            }
        }
        next(0)
    }

    static func renderCodexAnnouncement(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Motion.snapshotMode = true
        AgentSessionsManager.shared.injectPreview(.finished(194), name: "Змейка и уведомления", agent: .codex, broadcast: false)
        guard let announcement = AgentSessionsManager.shared.announcement else { NSApp.terminate(nil); return }
        let frames: [(name: String, time: Double)] = [
            ("codex-check-launch", 0.12),
            ("codex-check-arrive", 0.4),
            ("codex-check-hold", 1),
            ("codex-check-exit", 3.05)
        ]
        func next(_ index: Int) {
            guard frames.indices.contains(index) else {
                CodexCompletionFlight.previewTime = 1
                NSApp.terminate(nil)
                return
            }
            CodexCompletionFlight.previewTime = frames[index].time
            let model = NotchViewModel(screen: NSScreen.main)
            model.showAgentAnnouncement(announcement, duration: 4)
            let root = ContentView().environmentObject(model).environmentObject(Settings.shared)
            render(root: root, to: directory.appendingPathComponent(frames[index].name + ".png")) { next(index + 1) }
        }
        next(0)
    }

    static func renderGame(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Motion.snapshotMode = true
        func next(_ index: Int) {
            guard index < 8 else { NSApp.terminate(nil); return }
            let tracks: [DriftTrack] = [.sunset, .city, .sunset, .rain, .rain, .city, .sunset, .sunset]
            let cars: [DriftCar] = [.vector, .vector, .inferno, .violet, .ghost, .gold, .inferno, .inferno]
            DriftGame.shared.preview(track: tracks[index], car: cars[index], ready: index == 0,
                                     over: index == 5, paused: index == 4,
                                     highBeam: index >= 6, outsideLane: index == 7)
            let model = NotchViewModel(screen: NSScreen.main)
            model.previewOpen()
            model.currentTab = .game
            let root = ContentView().environmentObject(model).environmentObject(Settings.shared)
            render(root: root, to: directory.appendingPathComponent(["drift-ready", "drift-city", "drift-sunset",
                   "drift-rain", "drift-paused", "drift-over", "drift-high-beam", "drift-outer-lane"][index] + ".png")) {
                next(index + 1)
            }
        }
        next(0)
    }

    /// Puts back any preference a scene changed. Preview mode runs in its own
    /// process but writes to the same defaults the real app reads.
    private static var restoreSettings: (() -> Void)?

    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Entrances are drawn finished: the capture cannot wait for them.
        Motion.snapshotMode = true
        // And the weather is drawn at a known moment rather than whenever.
        PixelWeatherView.frozenTime = 1000.4

        let settings = Settings.shared
        let saved = (
            idle: settings.idleWidgetsEnabled,
            idleLeft: settings.idleLeftWidgets,
            idleRight: settings.idleRightWidgets,
            mediaDisplay: settings.closedMediaDisplay,
            game: settings.selectedGame,
            skin: settings.dinoSkin
        )
        restoreSettings = {
            settings.idleWidgetsEnabled = saved.idle
            settings.idleLeftWidgets = saved.idleLeft
            settings.idleRightWidgets = saved.idleRight
            settings.closedMediaDisplay = saved.mediaDisplay
            settings.selectedGame = saved.game
            settings.dinoSkin = saved.skin
        }

        // The render process has no location permission, so without this every
        // home-screen scene shows "Weather needs location access" instead of
        // the screen a real user sees. In-memory only; nothing touches disk.
        WeatherManager.shared.injectPreviewConditions(
            temperatureCelsius: 21, weatherCode: 0, isDay: true, placeName: "Cupertino"
        )

        let screen = NSScreen.main
        var scenes: [(name: String, configure: (NotchViewModel) -> Void)] = []

        scenes.append(("closed-idle", { _ in }))

        scenes.append(("closed-music", { viewModel in
            MusicManager.shared.injectPreviewTrack(Self.sampleTrack())
            viewModel.refreshPreviewMusicActivity()
        }))

        scenes.append(("closed-hud-battery", { viewModel in
            viewModel.expandingView = SneakPeek(show: true, type: .battery, value: 0.8, icon: "battery.100.bolt")
        }))

        // The renderer owns its own view model, so drive the strip directly
        // rather than through the manager's broadcast.
        scenes.append(("closed-hud-volume", { viewModel in
            HUDManager.shared.injectPreview(.volume, value: 0.62)
            viewModel.expandingView = SneakPeek(
                show: true, type: .hud, value: 0.62, icon: HUDManager.Kind.volume.symbol
            )
        }))

        scenes.append(("closed-hud-brightness", { viewModel in
            HUDManager.shared.injectPreview(.brightness, value: 0.38)
            viewModel.expandingView = SneakPeek(
                show: true, type: .hud, value: 0.38, icon: HUDManager.Kind.brightness.symbol
            )
        }))

        scenes.append(("closed-peek-music", { viewModel in
            MusicManager.shared.injectPreviewTrack(Self.sampleTrack())
            viewModel.refreshPreviewMusicActivity()
            viewModel.sneakPeek = SneakPeek(show: true, type: .music)
        }))

        scenes.append(("open-home", { viewModel in
            MusicManager.shared.injectPreviewTrack(Self.sampleTrack())
            viewModel.refreshPreviewMusicActivity()
            viewModel.previewOpen()
        }))

        scenes.append(("open-shelf", { viewModel in
            viewModel.previewOpen()
            ShelfManager.shared.injectPreviewItems([
                "Q3-notes.pdf", "mockup-v4.png", "budget.xlsx",
                "Screenshot 2026-09-20 at 09.41.02.png", "contract-draft.pdf",
                "logo-export.svg",
            ])
            viewModel.currentTab = .shelf
        }))

        scenes.append(("closed-dropzone", { viewModel in
            viewModel.dragDetectorTargeting = true
        }))

        scenes.append(("closed-focus", { viewModel in
            MusicManager.shared.injectPreviewTrack(Self.sampleTrack())
            viewModel.refreshPreviewMusicActivity()
            FocusManager.shared.injectPreviewSession(minutes: 25, elapsedFraction: 0.35)
            viewModel.refreshPreviewFocusActivity()
        }))

        scenes.append(("island-closed", { viewModel in
            viewModel.previewForceIsland = true
            viewModel.closedNotchSize = CGSize(
                width: Settings.shared.islandWidth,
                height: 32 + Settings.shared.islandTopGap
            )
        }))

        scenes.append(("island-open", { viewModel in
            viewModel.previewForceIsland = true
            viewModel.closedNotchSize = CGSize(
                width: Settings.shared.islandWidth,
                height: 32 + Settings.shared.islandTopGap
            )
            viewModel.previewOpen()
        }))

        scenes.append(("open-timer", { viewModel in
            FocusManager.shared.clearPreviewSession()
            viewModel.setPreviewFocusActivity(false)
            TimerManager.shared.previewRecent = [720, 2700, 90, 5400]
            TimerManager.shared.injectPreviewCountdown(duration: 600, remaining: 372)
            FocusTabState.shared.page = .countdown
            viewModel.previewOpen()
            viewModel.currentTab = .focus
        }))

        scenes.append(("open-timer-idle", { viewModel in
            TimerManager.shared.resetCountdown()
            TimerManager.shared.draft = 1500
            FocusTabState.shared.page = .countdown
            viewModel.previewOpen()
            viewModel.currentTab = .focus
        }))

        scenes.append(("open-timer-done", { viewModel in
            TimerManager.shared.injectPreviewCountdown(duration: 300, remaining: 0, finished: true)
            FocusTabState.shared.page = .countdown
            viewModel.previewOpen()
            viewModel.currentTab = .focus
        }))

        scenes.append(("open-clipboard", { viewModel in
            ClipboardManager.shared.injectPreviewEntries([
                (.text("https://developer.apple.com/documentation/appkit/nspasteboard"), "Safari"),
                (.text("git rebase -i origin/main"), "Terminal"),
                (.files([URL(fileURLWithPath: "/Users/me/Desktop/Screenshot.png")]), "Finder"),
                (.text("Remember to pick up the dry cleaning before six"), "Notes"),
                (.text("swift build -c release"), "Terminal"),
            ])
            viewModel.previewOpen()
            viewModel.currentTab = .clipboard
        }))

        scenes.append(("closed-screenshot", { viewModel in
            FocusManager.shared.clearPreviewSession()
            viewModel.setPreviewFocusActivity(false)
            ScreenshotWatcher.shared.injectPreviewCatch("Screenshot 2026-08-01 at 10.24.11.png")
            viewModel.expandingView = SneakPeek(
                show: true, type: .screenshot, value: 1, icon: "camera.viewfinder"
            )
        }))

        scenes.append(("closed-bluetooth", { viewModel in
            FocusManager.shared.clearPreviewSession()
            viewModel.setPreviewFocusActivity(false)
            BluetoothMonitor.shared.injectPreviewChange(
                name: "AirPods Pro", connected: true, battery: 0.82
            )
            viewModel.expandingView = SneakPeek(
                show: true, type: .bluetooth, value: 0.82, icon: "airpods.pro"
            )
        }))

        scenes.append(("closed-widgets", { viewModel in
            let settings = Settings.shared
            settings.idleWidgetsEnabled = true
            settings.idleLeftWidgets = [.clock]
            settings.idleRightWidgets = [.battery]
            MusicManager.shared.injectPreviewTrack(TrackInfo())
            viewModel.setPreviewMusicActivity(false)
        }))

        scenes.append(("open-neon-drift", { viewModel in
            DriftGame.shared.preview(track: .city, car: .vector)
            viewModel.previewOpen()
            viewModel.currentTab = .game
        }))

        scenes.append(("closed-music-and-widgets", { viewModel in
            let settings = Settings.shared
            settings.idleWidgetsEnabled = true
            settings.idleLeftWidgets = [.clock]
            settings.idleRightWidgets = [.battery]
            settings.closedMediaDisplay = .mediaAndWidgets
            MusicManager.shared.injectPreviewTrack(Self.sampleTrack())
            viewModel.refreshPreviewMusicActivity()
        }))

        scenes.append(("closed-music-widgets-only", { viewModel in
            let settings = Settings.shared
            settings.idleWidgetsEnabled = true
            settings.idleLeftWidgets = [.clock]
            settings.idleRightWidgets = [.battery]
            settings.closedMediaDisplay = .widgetsOnly
            MusicManager.shared.injectPreviewTrack(Self.sampleTrack())
            viewModel.refreshPreviewMusicActivity()
        }))

        scenes.append(("closed-widgets-many", { viewModel in
            let settings = Settings.shared
            settings.idleWidgetsEnabled = true
            settings.idleLeftWidgets = [.clock, .weather]
            settings.idleRightWidgets = [.cpu, .memory, .battery]
            MusicManager.shared.injectPreviewTrack(TrackInfo())
            viewModel.setPreviewMusicActivity(false)
        }))

        scenes.append(("closed-download", { viewModel in
            viewModel.expandingView = SneakPeek(
                show: true, type: .download, value: 1, icon: "arrow.down.circle.fill"
            )
        }))

        // The home screen leads with the weather whenever media is idle, which
        // is what the site shows too — but the render process never has
        // location permission, so the forecast is injected. Nothing here
        // touches disk: `conditions` is in-memory only.
        // open-home already covers the default clear-day state. This one is
        // here to show the pixel scene changes with the forecast.
        scenes.append(("open-weather-rain", { viewModel in
            MusicManager.shared.clearPreviewTrack()
            viewModel.refreshPreviewMusicActivity()
            WeatherManager.shared.injectPreviewConditions(
                temperatureCelsius: 11, weatherCode: 63, isDay: true, placeName: "London"
            )
            viewModel.previewOpen()
            viewModel.currentTab = .home
        }))

        // MARK: Live activities

        scenes.append(("closed-hud-muted", { viewModel in
            MusicManager.shared.clearPreviewTrack()
            viewModel.setPreviewMusicActivity(false)
            HUDManager.shared.injectPreview(.volume, value: 0.4, muted: true)
            viewModel.expandingView = SneakPeek(
                show: true, type: .hud, value: 0, icon: HUDManager.Kind.volume.mutedSymbol
            )
        }))

        scenes.append(("closed-hud-backlight", { viewModel in
            viewModel.expandingView = SneakPeek(
                show: true, type: .hud, value: 0.7, icon: HUDManager.Kind.keyboardBacklight.symbol
            )
        }))

        scenes.append(("closed-agent-started", { viewModel in
            AgentSessionsManager.shared.injectPreview(.started, broadcast: false)
            viewModel.expandingView = SneakPeek(show: true, type: .agent)
        }))

        scenes.append(("closed-agent-finished", { viewModel in
            AgentSessionsManager.shared.injectPreview(.finished(194), broadcast: false)
            viewModel.expandingView = SneakPeek(show: true, type: .agent)
        }))

        scenes.append(("closed-agent-waiting", { viewModel in
            AgentSessionsManager.shared.injectPreview(.needsInput("permission prompt"), broadcast: false)
            viewModel.expandingView = SneakPeek(show: true, type: .agent)
        }))

        // Beside the clock and battery, a working agent is a small light.
        scenes.append(("closed-agent-light", { viewModel in
            let settings = Settings.shared
            settings.idleWidgetsEnabled = true
            settings.idleLeftWidgets = [.clock]
            settings.idleRightWidgets = [.battery]
            AgentSessionsManager.shared.injectPreviewSessions(Array(Self.sampleSessions().prefix(1)) + [Self.sampleSessions()[3]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 2, waiting: false))
        }))

        // With nothing else there, it takes both wings.
        scenes.append(("closed-agent-wings", { viewModel in
            Settings.shared.idleWidgetsEnabled = false
            AgentSessionsManager.shared.injectPreviewSessions([Self.sampleSessions()[0]])
            viewModel.setPreviewAgentActivity(AgentActivity(active: 1, waiting: false))
        }))

        scenes.append(("closed-focus-banner", { viewModel in
            AgentSessionsManager.shared.injectPreviewSessions([])
            viewModel.setPreviewAgentActivity(AgentActivity())
            FocusManager.shared.injectPreviewSession(minutes: 25, elapsedFraction: 0.02)
            viewModel.expandingView = SneakPeek(show: true, type: .focus, value: 0, icon: "cup.and.saucer.fill")
        }))

        scenes.append(("open-shutdown-timer", { viewModel in
            viewModel.previewOpen()
            viewModel.currentTab = .focus
            FocusTabState.shared.page = .shutdown
        }))

        scenes.append(("open-alarm", { viewModel in
            viewModel.previewOpen()
            viewModel.currentTab = .focus
            FocusTabState.shared.page = .alarm
        }))

        // Scenes are rendered one at a time: several of them configure shared
        // singletons, so running them concurrently would let the last one win.
        renderSequentially(scenes, index: 0, screen: screen, directory: directory)
    }

    private static func renderSequentially(
        _ scenes: [(name: String, configure: (NotchViewModel) -> Void)],
        index: Int,
        screen: NSScreen?,
        directory: URL
    ) {
        guard index < scenes.count else {
            FocusTabState.shared.page = .countdown
            restoreSettings?()
            FocusManager.shared.clearPreviewSession()
            TimerManager.shared.clearPreview()
            renderExtras(into: directory) {
                NSApp.terminate(nil)
            }
            return
        }

        let scene = scenes[index]
        let viewModel = NotchViewModel(screen: screen)
        scene.configure(viewModel)

        let root = ContentView()
            .environmentObject(viewModel)
            .environmentObject(Settings.shared)

        render(root: root, to: directory.appendingPathComponent("\(scene.name).png")) {
            renderSequentially(scenes, index: index + 1, screen: screen, directory: directory)
        }
    }

    // MARK: Tiles and windows

    /// Every weather scene as the pane shows it, with a filmstrip of its
    /// motion underneath, and the collapsed-notch icons. Drawn straight to
    /// images: the weather is a pure function of time, so no window is needed
    /// and no animation has to be waited for.
    private static func renderWeatherSheets(into directory: URL) {
        let variants: [(name: String, scene: WeatherScene, code: Int, night: Bool, celsius: Double)] = [
            ("clear-day", .clearDay, 0, false, 24),
            ("clear-night", .clearNight, 0, true, 14),
            ("cloudy-day", .cloudy, 3, false, 17),
            ("cloudy-night", .cloudy, 3, true, 11),
            ("fog", .fog, 45, false, 9),
            ("drizzle", .drizzle, 53, false, 12),
            ("rain", .rain, 63, false, 11),
            ("rain-night", .rain, 63, true, 9),
            ("storm", .storm, 95, true, 16),
            ("snow-day", .snow, 73, false, -2),
            ("snow-night", .snow, 73, true, -6),
        ]
        let size = CGSize(width: 420, height: 100)
        let saved = PixelWeatherView.frozenTime

        for variant in variants {
            var start = 1000.4
            var step = 0.25
            if variant.scene == .storm, let strike = PixelWeatherView.nextStrike(after: 1000) {
                start = strike - 0.08
                step = 0.08
            } else if variant.scene == .clearNight, let meteor = PixelWeatherView.nextMeteor(after: 1000) {
                start = meteor - 0.15
                step = 0.15
            }
            let times = (0 ..< 4).map { start + Double($0) * step }

            WeatherManager.shared.injectPreviewConditions(
                temperatureCelsius: variant.celsius, weatherCode: variant.code,
                isDay: !variant.night, placeName: "Cupertino"
            )
            PixelWeatherView.frozenTime = times[1]

            let sheet = VStack(alignment: .leading, spacing: 8) {
                WeatherPane()
                    .frame(width: size.width, height: size.height)
                ForEach(times, id: \.self) { time in
                    PixelWeatherView(scene: variant.scene, isNight: variant.night, time: time)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(10)
            .background(Color.black)
            .environment(\.colorScheme, .dark)

            writeImage(sheet, scale: 2, to: directory.appendingPathComponent("weather-\(variant.name).png"))
        }

        // The collapsed-notch icons, eight times life size so each cell shows.
        let icons = HStack(spacing: 6) {
            ForEach([WeatherScene.clearDay, .clearNight, .cloudy, .fog, .drizzle, .rain, .storm, .snow], id: \.self) { scene in
                PixelWeatherIcon(scene: scene)
                    .padding(3)
                    .background(Color.black)
            }
        }
        .padding(4)
        .background(Color(white: 0.2))
        PixelWeatherView.frozenTime = 1000.1
        writeImage(icons, scale: 8, to: directory.appendingPathComponent("weather-icons.png"))

        PixelWeatherView.frozenTime = saved
        WeatherManager.shared.injectPreviewConditions(
            temperatureCelsius: 21, weatherCode: 0, isDay: true, placeName: "Cupertino"
        )
    }

    private static func writeImage(_ view: some View, scale: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }

    /// The Agents tile on its own, and every page of the two windows.
    private static func renderExtras(into directory: URL, completion: @escaping () -> Void) {
        renderWeatherSheets(into: directory)
        var jobs: [(name: String, size: CGSize, dark: Bool, make: () -> AnyView)] = []

        jobs.append(("tile-agents", CGSize(width: 300, height: 128), true, {
            AgentSessionsManager.shared.injectPreviewSessions(Self.sampleSessions())
            return AnyView(
                AgentSessionsTile()
                    .frame(width: 270, height: 100)
                    .padding(14)
                    .background(Color.black)
            )
        }))
        jobs.append(("tile-agents-compact", CGSize(width: 270, height: 74), true, {
            AnyView(
                HomePanelChrome { AgentSessionsTile(compact: true) }
                    .frame(width: 240, height: 46)
                    .padding(14)
                    .background(Color.black)
            )
        }))
        jobs.append(("tile-agents-empty", CGSize(width: 300, height: 128), true, {
            AgentSessionsManager.shared.injectPreviewSessions([])
            return AnyView(
                AgentSessionsTile()
                    .frame(width: 270, height: 100)
                    .padding(14)
                    .background(Color.black)
            )
        }))

        jobs.append(("tile-focus-medium", CGSize(width: 390, height: 190), true, {
            FocusManager.shared.previewHistory = Self.sampleFocusHistory()
            TimerManager.shared.injectPreviewCountdown(duration: 600, remaining: 372)
            FocusTabState.shared.page = .countdown
            return AnyView(
                FocusView(isTile: true)
                    .environmentObject(Settings.shared)
                    .frame(width: 352, height: 150)
                    .padding(19)
                    .background(Color.black)
            )
        }))
        jobs.append(("tile-focus-narrow", CGSize(width: 160, height: 190), true, {
            AnyView(
                FocusView(isTile: true)
                    .environmentObject(Settings.shared)
                    .frame(width: 118, height: 150)
                    .padding(19)
                    .background(Color.black)
            )
        }))

        for tab in SettingsTab.allCases {
            jobs.append(("settings-\(tab.rawValue)", CGSize(width: 820, height: 640), false, {
                if tab == .agents { AgentSessionsManager.shared.injectPreviewSessions(Self.sampleSessions()) }
                SettingsNavigation.shared.tab = tab
                return AnyView(SettingsView().environmentObject(Settings.shared))
            }))
        }
        for tab in CustomizeTab.allCases {
            jobs.append(("customize-\(tab.rawValue)", CGSize(width: 1010, height: 720), true, {
                CustomizeNavigation.shared.tab = tab
                return AnyView(CustomizeView(onDone: {}))
            }))
        }

        func next(_ index: Int) {
            guard index < jobs.count else {
                completion()
                return
            }
            let job = jobs[index]
            render(
                root: job.make(),
                size: job.size,
                appearance: NSAppearance(named: job.dark ? .darkAqua : .aqua),
                to: directory.appendingPathComponent("\(job.name).png")
            ) {
                next(index + 1)
            }
        }
        next(0)
    }

    /// An invented week of focus: a few good days, one off, a streak running
    /// into today.
    static func sampleFocusHistory() -> (seconds: [String: Int], sessions: [String: Int]) {
        let minutes = [95, 0, 50, 140, 75, 110, 40]
        var seconds: [String: Int] = [:]
        var sessions: [String: Int] = [:]
        let today = Calendar.current.startOfDay(for: Date())
        for (back, value) in minutes.reversed().enumerated() {
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: today) else { continue }
            let key = FocusManager.dayKey(day)
            seconds[key] = value * 60
            sessions[key] = value / 25
        }
        return (seconds, sessions)
    }

    /// Made-up sessions: one working, one waiting on a permission prompt, one
    /// that finished, and a second working one.
    static func sampleSessions() -> [AgentSessionsManager.Session] {
        let now = Date()
        func make(
            _ id: String, _ name: String, _ project: String,
            _ status: AgentSessionsManager.Status, since: TimeInterval, turn: TimeInterval?,
            last: TimeInterval? = nil, agent: AgentSessionsManager.Agent = .claude
        ) -> AgentSessionsManager.Session {
            AgentSessionsManager.Session(
                id: id, agent: agent, name: name, project: project, status: status,
                statusSince: now.addingTimeInterval(-since),
                turnStartedAt: turn.map { now.addingTimeInterval(-$0) },
                lastTurnDuration: last, startedAt: now.addingTimeInterval(-3600),
                pid: nil, host: .claudeApp
            )
        }
        return [
            make("a", "Notch animations", "FunNotch", .working, since: 134, turn: 134),
            make("b", "Release notes", "FunNotch", .waiting("permission prompt"), since: 12, turn: 75),
            make("c", "Fix the shelf drop", "FunNotch", .idle, since: 240, turn: 700, last: 460),
            make("d", "Website copy", "Website", .working, since: 42, turn: 42),
        ]
    }

    private static func sampleTrack() -> TrackInfo {
        var track = TrackInfo()
        track.title = "Everything In Its Right Place"
        track.artist = "Radiohead"
        track.album = "Kid A"
        track.duration = 251
        track.elapsed = 84
        track.isPlaying = true
        track.isShuffled = true
        track.repeatMode = .all
        track.artwork = syntheticArtwork()
        return track
    }

    /// Stand-in album art so colour sampling and layout can be checked.
    private static func syntheticArtwork() -> NSImage {
        let size = CGSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.36, blue: 0.20, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.12, blue: 0.55, alpha: 1),
        ])
        gradient?.draw(in: CGRect(origin: .zero, size: size), angle: 55)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: CGRect(x: 110, y: 110, width: 80, height: 80)).fill()
        image.unlockFocus()
        return image
    }

    private static func render(
        root: some View,
        size: CGSize = windowSize,
        appearance: NSAppearance? = nil,
        to url: URL,
        completion: @escaping () -> Void
    ) {
        let hosting = NSHostingView(rootView: AnyView(root))
        // As the real windows: SwiftUI sets the minimum, the window the size.
        hosting.sizingOptions = [.minSize]
        hosting.frame = CGRect(origin: .zero, size: size)

        // A real (offscreen) window makes SwiftUI lay out and draw for real.
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -8000, y: -8000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)
        window.orderFront(nil)

        // Give SwiftUI a couple of run loop turns to settle animations.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            hosting.layoutSubtreeIfNeeded()
            guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                completion()
                return
            }
            hosting.cacheDisplay(in: hosting.bounds, to: representation)
            if let data = representation.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
            window.orderOut(nil)
            completion()
        }
    }
}

extension NotchViewModel {
    /// Opens without animation, for snapshots.
    func previewOpen() {
        setPreviewState(.open)
    }

    func refreshPreviewMusicActivity() {
        setPreviewMusicActivity(true)
    }

    func refreshPreviewFocusActivity() {
        setPreviewFocusActivity(FocusManager.shared.isActive)
    }
}
