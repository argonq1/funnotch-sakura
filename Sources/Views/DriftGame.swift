import AppKit
import Combine
import SwiftUI

@MainActor
final class DriftGame: ObservableObject {
    static let shared = DriftGame()
    struct Trail { let x: Double; let distance: Double; let time: Double }
    private(set) var rules: DriftRules
    private(set) var car: DriftCar
    private(set) var trails: [Trail] = []
    private(set) var flash = 0.0
    struct Notice {
        let symbol: String
        let label: String
        let number: String?
    }
    private(set) var notice: Notice?
    private(set) var best = 0
    private var messageUntil = 0.0
    private var visible = false
    private var lastFrame: Date?
    private var timer: Timer?
    private var keys = Set<UInt16>()
    private var shiftHeld = false
    private var probeDriver = DriftTrafficDriver()
    private var dragTarget: Double?
    private var powerObserver: AnyCancellable?
    private var focusObserver: AnyCancellable?
    private var bankedCoins = 0
    private var lastSaveElapsed = 0.0
    private var accelerationUntil = 0.0
    private(set) var isPerformanceProbe = false
    var hasFrameTimer: Bool { timer != nil }
    var wallet: Int { Settings.shared.driftCoins + max(0, rules.coins - bankedCoins) }
    var track: DriftTrack { rules.track }
    var input: DriftRules.Input {
        let left = keys.contains(123) || keys.contains(0)
        let right = keys.contains(124) || keys.contains(2)
        let steer = (right ? 1.0 : 0) - (left ? 1.0 : 0)
        return DriftRules.Input(steer: steer, drift: keys.contains(49),
                                throttle: keys.contains(126) || keys.contains(13),
                                nitro: shiftHeld,
                                brake: keys.contains(1) || keys.contains(125),
                                targetX: left || right ? nil : dragTarget)
    }
    private init() {
        let settings = Settings.shared
        let track = DriftTrack(rawValue: settings.driftTrack) ?? .city
        rules = DriftRules(track: track); car = DriftCar(rawValue: settings.driftCar) ?? .vector
        best = settings.driftStreetBestScores[track.rawValue] ?? 0
        powerObserver = SystemActivityMonitor.shared.$isIdle.dropFirst().sink { [weak self] idle in
            guard let self else { return }
            if idle { self.pause() }
            self.updateTicker()
        }
        focusObserver = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] notification in
                guard notification.object is NotchPanel else { return }
                self?.pause()
            }
    }
    func open() { visible = true; lastFrame = nil; updateTicker() }
    func close() { pause(); visible = false; updateTicker() }
    func start() {
        objectWillChange.send()
        if rules.phase == .over {
            guard rules.crashAge > 0.65 else { return }
            restart()
        }
        if rules.phase == .finished { restart() }
        if rules.phase == .ready { accelerationUntil = rules.elapsed + 2.8 }
        rules.start(); lastFrame = nil; updateTicker()
    }
    func restart() {
        persist(); objectWillChange.send()
        rules = DriftRules(track: track); bankedCoins = 0; lastSaveElapsed = 0
        trails = []; flash = 0; notice = nil; lastFrame = nil
        clearInput(); updateTicker()
    }
    func pause() {
        accelerationUntil = 0
        objectWillChange.send(); rules.pause(); clearInput(); lastFrame = nil
        persist(); updateTicker()
    }
    func togglePause() { if rules.phase == .running { pause() } else if rules.phase == .paused { start() } }
    func select(track: DriftTrack) {
        guard track != self.track else { return }
        persist(); objectWillChange.send()
        rules = DriftRules(track: track); bankedCoins = 0; lastSaveElapsed = 0
        best = Settings.shared.driftStreetBestScores[track.rawValue] ?? 0
        trails = []; flash = 0; notice = nil; lastFrame = nil; clearInput()
        Settings.shared.driftTrack = track.rawValue; updateTicker()
    }
    func select(car: DriftCar) {
        objectWillChange.send(); self.car = car; Settings.shared.driftCar = car.rawValue
    }
    func flashHeadlights() {
        objectWillChange.send()
        switch rules.flashHeadlights() {
        case .yielded: announce("Машина уступает", symbol: "headlight.high.beam.fill")
        case .blocked: announce("Нет свободной полосы", symbol: "exclamationmark.triangle.fill")
        case .flashed: announce("Дальний свет", symbol: "headlight.high.beam.fill")
        case .unavailable: break
        }
    }
    func popExhaust() {
        guard rules.popExhaust() else { return }
        objectWillChange.send()
        announce("Выхлоп", symbol: "flame.fill")
        GameSound.shared.play(.exhaust)
    }
    func syncSound() {
        let audible = visible && rules.phase == .running && !SystemActivityMonitor.isScreenIdle
            && !isPerformanceProbe && !Motion.snapshotMode
        GameSound.shared.setStreetBeat(active: audible)
        let pulling = input.throttle && DriftRules.throttleAcceleration(at: rules.speedKPH) > 1
        GameSound.shared.setEngineAcceleration(active: audible && !rules.isBraking
            && (pulling || rules.isBoosting || rules.elapsed < accelerationUntil), boosting: rules.isBoosting)
    }
    func drag(to value: Double?) { dragTarget = value }
    func clearInput() {
        keys.removeAll()
        shiftHeld = false; dragTarget = nil
    }
    func handleKey(_ event: NSEvent) -> Bool {
        let shortcut = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        shiftHeld = !shortcut && event.modifierFlags.contains(.shift)
        if event.type == .flagsChanged { return !shortcut && (event.keyCode == 56 || event.keyCode == 60) }
        let down = event.type == .keyDown
        if !down { keys.remove(event.keyCode) }
        guard !shortcut else { return false }
        switch event.keyCode {
        case 0, 2, 123, 124, 49, 13, 126, 1, 125:
            if down { keys.insert(event.keyCode) }
            return true
        case 36:
            if down && !event.isARepeat { start() }
            return true
        case 35, 53:
            if down && !event.isARepeat { togglePause() }
            return true
        case 15:
            if down && !event.isARepeat { restart() }
            return true
        case 11: // B
            if down && !event.isARepeat { popExhaust() }
            return true
        case 3: // F
            if down && !event.isARepeat { flashHeadlights() }
            return true
        default: return false
        }
    }
    private func updateTicker() {
        let shouldTick = visible && !Motion.snapshotMode && !SystemActivityMonitor.isScreenIdle
            && (rules.phase == .running || (rules.phase == .over && rules.crashAge < 1.5))
        syncSound()
        if !shouldTick { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(to: Date()) }
        }
        ticker.tolerance = 0.0015
        RunLoop.main.add(ticker, forMode: .common); timer = ticker
    }
    func advance(to date: Date) {
        guard visible else { return }
        defer { lastFrame = date }
        guard let lastFrame else { return }
        objectWillChange.send()
        let dt = min(max(date.timeIntervalSince(lastFrame), 0), 0.05)
        var controls = input
        if isPerformanceProbe {
            controls = probeDriver.input(for: rules, delta: dt)
        }
        let wasBraking = rules.isBraking
        let events = rules.advance(by: dt, input: controls)
        if wasBraking && !rules.isBraking { accelerationUntil = rules.elapsed + 1.8 }
        flash = max(0, flash - dt * 2)
        if rules.isDrifting {
            trails.append(Trail(x: rules.playerX, distance: rules.distance, time: rules.elapsed))
        }
        trails.removeAll { rules.elapsed - $0.time > 1.1 }
        if trails.count > 72 { trails.removeFirst(trails.count - 72) }
        if rules.elapsed > messageUntil { notice = nil }
        best = max(best, rules.score)
        if !isPerformanceProbe {
            for event in events {
                switch event {
                case let .pickup(kind):
                    if kind != .coin { announce(kind.title, symbol: kind.symbol); GameSound.shared.play(.powerup) }
                    else { GameSound.shared.play(.coin) }
                case let .nearMiss(points): announce("Обгон вплотную", symbol: "arrow.up.right", number: "+\(points)"); GameSound.shared.play(.closeCall)
                case let .weave(points, streak): announce("Серия обгонов \(streak)", symbol: "arrow.up.right", number: "+\(points)"); GameSound.shared.play(.combo)
                case let .hit(damage):
                    flash = 1
                    announce("Столкновение", symbol: "heart.slash.fill", number: "−\(damage)")
                    GameSound.shared.play(.smash)
                case .shieldBreak: flash = 0.4; announce("Щит поглотил удар", symbol: "shield.slash.fill"); GameSound.shared.play(.shieldPop)
                case .crashed: clearInput(); persist(); GameSound.shared.play(.crash)
                case .finished: clearInput(); persist(); GameSound.shared.play(.milestone)
                case let .levelUp(level): announce("Новый уровень", symbol: "chevron.up", number: String(level)); GameSound.shared.play(.milestone)
                case .boost: GameSound.shared.play(.turbo)
                case .backfire: GameSound.shared.play(.exhaust)
                }
            }
            if rules.elapsed - lastSaveElapsed >= 10 { persist(); lastSaveElapsed = rules.elapsed }
        }
        updateTicker()
    }
    private func announce(_ text: String, symbol: String, number: String? = nil) {
        notice = Notice(symbol: symbol, label: text, number: number)
        messageUntil = rules.elapsed + 1.8
    }
    private func persist() {
        guard !isPerformanceProbe && !Motion.snapshotMode else { return }
        let settings = Settings.shared
        if rules.coins > bankedCoins { settings.driftCoins += rules.coins - bankedCoins; bankedCoins = rules.coins }
        if rules.score > (settings.driftStreetBestScores[track.rawValue] ?? 0) {
            var records = settings.driftStreetBestScores; records[track.rawValue] = rules.score; settings.driftStreetBestScores = records
        }
    }
    func preview(track: DriftTrack, car: DriftCar, ready: Bool = false, over: Bool = false,
                 paused: Bool = false, highBeam: Bool = false, outsideLane: Bool = false) {
        rules = DriftRules(track: track, seed: 42); self.car = car; trails = []; flash = 0; notice = nil
        if !ready {
            rules.stagePreview(over: over, boosting: track != .sunset, highBeam: highBeam,
                               outsideLane: outsideLane)
        }
        if paused { rules.pause() }
        best = 7_820
    }
    func startPerformanceProbe() {
        isPerformanceProbe = true; probeDriver = DriftTrafficDriver(); rules = DriftRules(track: .city, seed: 42); rules.start()
        objectWillChange.send(); lastFrame = nil; updateTicker()
    }
}

struct DriftGameView: View {
    @ObservedObject private var game = DriftGame.shared
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var viewModel: NotchViewModel
    @State private var showingGuide = false
    @State private var previousPin = false
    private var accent: Color { NotchPalette.accent }
    var body: some View {
        VStack(spacing: 5) {
            header
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    Canvas { context, size in
                        context.scaleBy(x: size.width / DriftRules.width, y: size.height / DriftRules.height)
                        DriftPainter(game: game).draw(in: &context)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        GameKeyboard.shared.takeFocus()
                        guard game.rules.phase == .running, proxy.size.width > 0 else { return }
                        let screenX = value.location.x * DriftRules.width / proxy.size.width
                        let lane = DriftProjection.playerLane(at: screenX, curve: game.rules.curve)
                        game.drag(to: min(0.9, max(-0.9, lane)))
                    }.onEnded { _ in game.drag(to: nil) })
                    .accessibilityLabel("Трасса Hellcat Afterdark. Очки: \(game.rules.score). Уровень: \(game.rules.level).")
                    .accessibilityHint("A и D — перестроение, W — газ, Shift — нитро, S — тормоз, пробел — дрифт, B — отстрел выхлопа")
                    if game.rules.phase == .running {
                        raceHUD.allowsHitTesting(false)
                    } else {
                        Color.black.opacity(0.24).allowsHitTesting(false)
                        card.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(NotchPalette.rim, lineWidth: 0.7).allowsHitTesting(false))
            }.aspectRatio(2.25, contentMode: .fit)
        }.padding(.top, 3)
        .onAppear {
            guard !Motion.snapshotMode else { return }
            game.open(); if !game.isPerformanceProbe { GameSound.shared.start(); game.syncSound() }
            GameKeyboard.shared.takeFocus()
            GameKeyboard.shared.install { game.handleKey($0) }
            DiagnosticLog.write("game", "neon drift shown")
        }
        .onDisappear {
            guard !Motion.snapshotMode else { return }
            game.close(); GameKeyboard.shared.remove(); GameSound.shared.stop()
            if showingGuide { viewModel.pinnedOpen = previousPin }
        }
        .onChange(of: showingGuide) { _, show in
            if show { previousPin = viewModel.pinnedOpen; viewModel.pinnedOpen = true; game.pause() }
            else { viewModel.pinnedOpen = previousPin }
        }
        .onChange(of: viewModel.hiddenForFullscreen) { _, hidden in
            if hidden { game.close() } else { game.open() }
        }
    }
    private var header: some View {
        HStack(spacing: 7) {
            NotchGamePicker()
            Menu {
                ForEach(DriftTrack.allCases) { track in
                    Button { game.select(track: track) } label: { Label(track.title + " · " + track.detail, systemImage: game.track == track ? "checkmark.circle.fill" : "map") }
                }
            } label: { pill("map.fill") }
                .menuStyle(.borderlessButton).fixedSize().help("Выбрать трассу")
            Menu {
                ForEach(DriftCar.allCases) { car in
                    Button { game.select(car: car) } label: { Label(car.title, systemImage: game.car == car ? "checkmark.circle.fill" : "car.side.fill") }
                }
            } label: { pill("car.side.fill") }
                .menuStyle(.borderlessButton).fixedSize().help("Hellcat SRT · шесть раскрасок")
            Spacer(minLength: 0)
            raceResources
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(game.rules.score.formatted()).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                Label(game.best.formatted(), systemImage: "trophy").font(.system(size: 8, weight: .medium)).foregroundStyle(NotchPalette.secondaryText)
            }
            control(settings.gameSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill", "Звук") {
                settings.gameSoundEnabled.toggle()
                if settings.gameSoundEnabled { GameSound.shared.start(); game.syncSound() } else { GameSound.shared.stop() }
            }
            control(game.rules.phase == .paused ? "play.fill" : "pause.fill",
                    game.rules.phase == .paused ? "Продолжить · P / Esc" : "Пауза · P / Esc") { game.togglePause() }
                .disabled(game.rules.phase != .running && game.rules.phase != .paused)
            control("arrow.counterclockwise", "Новый заезд · R") { game.restart() }
            control("questionmark", "Управление и бонусы") { showingGuide.toggle() }
                .popover(isPresented: $showingGuide) { guide.preferredColorScheme(.dark) }
        }.frame(height: 26)
    }
    private func pill(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 26, height: 25).modifier(NotchSurface(radius: 10))
    }
    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 25, height: 25)
                .modifier(NotchSurface(radius: 12))
                .modifier(NotchHoverHighlight())
        }.buttonStyle(NotchPressStyle()).help(label).accessibilityLabel(label)
    }
    private var raceResources: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .semibold)).foregroundStyle(accent)
                meter(game.rules.nitro / 100, tint: accent).frame(width: 44)
            }.help("Нитро \(Int(game.rules.nitro))%. Для включения нужно от \(Int(DriftRules.minimumBoostCharge))%.")
                .accessibilityLabel("Запас нитро \(Int(game.rules.nitro))%")
            HStack(spacing: 3) {
                ForEach(0 ..< 3) { i in
                    Image(systemName: "heart.fill").foregroundStyle(i < game.rules.health ? Color.pink : .white.opacity(0.15))
                }
            }.font(.system(size: 9)).padding(.leading, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Здоровье \(game.rules.health) из 3")
            if game.rules.shield { Image(systemName: "shield.fill").font(.system(size: 10)).foregroundStyle(.mint) }
            if game.rules.magnet > 0 { Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10)).foregroundStyle(.purple) }
            Label(game.wallet.formatted(), systemImage: "circle.inset.filled")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.yellow)
                .accessibilityLabel("Монеты: \(game.wallet)")
        }
    }

    private var raceHUD: some View {
        let rules = game.rules
        return ZStack(alignment: .top) {
            HStack(alignment: .top) {
                VStack(spacing: 2) {
                    DriftSpeedometer(speedKPH: rules.speedKPH)
                    Label(rules.distance.formatted(.number.precision(.fractionLength(0))),
                          systemImage: "flag.checkered")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchPalette.secondaryText)
                        .accessibilityLabel("\(Int(rules.distance)) из \(Int(DriftRules.finishDistance)) метров")
                    meter(rules.distance / DriftRules.finishDistance, tint: .white.opacity(0.58))
                        .frame(width: 63)
                }
                .monospacedDigit().frame(width: 97).padding(.horizontal, 7).padding(.vertical, 6)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .modifier(NotchSurface(radius: 14))
                .accessibilityElement(children: .combine)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if rules.combo > 1 {
                        Text("×\(rules.combo)").font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                    Label(rules.overtakes.formatted(), systemImage: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                        .accessibilityLabel("Обгоны \(rules.overtakes)")
                }
                .monospacedDigit().padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .modifier(NotchSurface(radius: 13))
            }
            VStack(spacing: 5) {
                if rules.isBoosting { status("Нитро", "bolt.fill", tint: accent) }
                else if rules.isBraking { status("Тормоз", "arrow.down", tint: .orange) }
                else if rules.exhaustRemaining > 0 { status("Выхлоп", "flame.fill", tint: .orange) }
                else if rules.weaveStreak > 0 && rules.comboTime > 0 { status("Серия \(rules.weaveStreak)", "arrow.up.right", tint: accent) }
                else if rules.isDrifting { status("Дрифт", "steeringwheel", tint: accent) }
                if rules.hasDanger { status("Край трассы", "exclamationmark.triangle.fill", tint: .orange) }
                if let notice = game.notice {
                    HStack(spacing: 5) {
                        Image(systemName: notice.symbol)
                        if let number = notice.number { Text(number).monospacedDigit() }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.black.opacity(0.64), in: Capsule())
                    .accessibilityLabel(notice.label)
                }
            }
            .padding(.horizontal, 118)
        }.padding(12)
    }

    private func meter(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { proxy in
            Capsule().fill(.white.opacity(0.12)).overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }.frame(height: 3).accessibilityHidden(true)
    }

    private func status(_ title: String, _ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint).padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.7), in: Capsule())
            .accessibilityLabel(title)
    }
    private var card: some View {
        let phase = game.rules.phase
        let symbol = switch phase {
        case .ready, .running: "steeringwheel"
        case .paused: "pause.fill"
        case .over: "exclamationmark.triangle"
        case .finished: "flag.checkered"
        }
        return VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .modifier(NotchSurface(radius: 12, opacity: 0.12))
                .accessibilityHidden(true)
            if phase == .ready {
                tutorial
            } else {
                HStack(spacing: 18) {
                    raceStat(game.rules.score.formatted(), "star", "Очки")
                    raceStat(Int(game.rules.distance).formatted(), "flag.checkered", "Дистанция")
                    raceStat(game.rules.coins.formatted(), "circle.circle", "Монеты")
                }.padding(.vertical, 3)
            }
            Button {
                GameKeyboard.shared.takeFocus(); game.start()
            } label: {
                Image(systemName: phase == .over || phase == .finished ? "arrow.counterclockwise" : "play.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 25).padding(.vertical, 9).background(NotchPalette.selection, in: Capsule())
            }.buttonStyle(NotchPressStyle()).disabled(phase == .over && game.rules.crashAge < 0.65).padding(.top, 3)
                .accessibilityLabel(phase == .paused ? "Продолжить" : "Начать заезд")
        }.padding(.horizontal, 22).padding(.vertical, 16)
            .background(NotchPalette.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .modifier(NotchSurface(radius: 24, opacity: 0.10))
    }
    private var tutorial: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                keyHint("← →", "steeringwheel", "Руль")
                keyHint("↑", "arrow.up", "Газ")
                keyHint("↓", "brakesignal", "Тормоз")
                keyHint("␣", "arrow.turn.up.right", "Дрифт")
            }
            HStack(spacing: 10) {
                keyHint("⇧", "bolt.fill", "Нитро")
                keyHint("F", "headlight.high.beam.fill", "Дальний свет")
                keyHint("B", "flame.fill", "Выхлоп")
                keyHint("⎋", "pause.fill", "Пауза")
            }
        }
        .padding(.horizontal, 12)
    }

    private func keyHint(_ key: String, _ symbol: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
            Text(key)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(width: 74, height: 48)
        .modifier(NotchSurface(radius: 11))
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(key)")
    }
    private func raceStat(_ value: String, _ symbol: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(NotchPalette.secondaryText)
        }
        .frame(minWidth: 56)
        .accessibilityLabel("\(caption): \(value)")
    }
    private var guide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Управление Hellcat").font(.system(size: 15, weight: .semibold))
            Text("A/D или ←/→ — поворот\nПробел + поворот — управляемый занос\nW или ↑ — газ · Shift — нитро\nСвыше \(Int(DriftRules.dangerousSpeedKPH)) км/ч удар снимает два сердца.\nS или ↓ — тормоз\nF — моргнуть дальним · B — отстрел выхлопа\nP/Esc — пауза · R — новый заезд\nФиниш через 18 км.")
                .font(.system(size: 11)).lineSpacing(4)
            Divider()
            ForEach(DriftPickup.allCases, id: \.rawValue) { kind in
                Label(kind.title, systemImage: kind.symbol).font(.system(size: 11)).foregroundStyle(DriftPalette.pickup(kind))
            }
            Text("Чередуй тесные обгоны слева и справа. Серия даёт больше очков и нитро. Комбо до ×12, пауза между обгонами — до 4,2 сек. Поворотник предупреждает о перестроении. Три сердца на заезд.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Дальний действует на ближайшую машину прямо впереди, до 125 м. Она уступает только в свободную соседнюю полосу; перезарядка — 4 сек.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Двойной выхлоп хлопает при сбросе нитро и по B. Кнопка звука включает эффекты и оригинальный 808-бит; на паузе музыка останавливается.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 310).background(NotchPalette.panel)
    }
}

private struct DriftSpeedometer: View {
    let speedKPH: Double

    private var fraction: Double {
        min(max(speedKPH / DriftRules.speedometerScaleKPH, 0), 1)
    }
    private var isAboveRegularSpeed: Bool {
        speedKPH > DriftRules.dangerousSpeedKPH
    }
    private var tint: Color { isAboveRegularSpeed ? .orange : NotchPalette.accent }

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
                let radius: CGFloat = 31
                let start = 140.0
                let sweep = 260.0

                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(start),
                             endAngle: .degrees(start + sweep), clockwise: false)
                let stroke = StrokeStyle(lineWidth: 3.5, lineCap: .round)
                context.stroke(track, with: .color(.white.opacity(0.18)), style: stroke)

                if fraction > 0 {
                    var progress = Path()
                    progress.addArc(center: center, radius: radius, startAngle: .degrees(start),
                                    endAngle: .degrees(start + sweep * fraction), clockwise: false)
                    context.stroke(progress, with: .color(tint), style: stroke)
                }

                var ticks = Path()
                for index in 0...10 {
                    let angle = Angle.degrees(start + sweep * Double(index) / 10).radians
                    let inner = radius + 4
                    let outer = inner + (index.isMultiple(of: 5) ? 3 : 2)
                    ticks.move(to: CGPoint(x: center.x + cos(angle) * inner,
                                          y: center.y + sin(angle) * inner))
                    ticks.addLine(to: CGPoint(x: center.x + cos(angle) * outer,
                                             y: center.y + sin(angle) * outer))
                }
                context.stroke(ticks, with: .color(.white.opacity(0.36)), lineWidth: 0.75)
            }
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                Text(Int(speedKPH), format: .number)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(isAboveRegularSpeed ? tint : .white)
                Image(systemName: "speedometer")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(NotchPalette.secondaryText)
            }
            .offset(y: 4)
        }
        .frame(width: 88, height: 70)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Скорость")
        .accessibilityValue("\(Int(speedKPH)) километров в час")
    }
}
