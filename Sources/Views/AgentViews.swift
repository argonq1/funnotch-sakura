//
//  AgentViews.swift
//  FunNotch
//
//  The pieces a Claude Code or Codex session is drawn with: Claude's own
//  spinner while it works, an orange hand while it waits for you, and a check
//  that draws itself when it is done. Plus the small motion toolkit every
//  announcement in the notch uses.
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Motion

/// Easing and springs as plain functions of time.
///
/// Announcements animate procedurally — each piece works out where it should
/// be from the seconds since it appeared — rather than through SwiftUI's
/// implicit animations. The entrances then play identically every time, can
/// be layered with precise delays, and render correctly in the snapshot
/// renderer, which cannot wait for SwiftUI to animate anything.
enum Motion {
    /// Set by the snapshot renderer: every entrance is drawn finished.
    nonisolated(unsafe) static var snapshotMode = false

    /// Set by the film renderer (`--render-film`): seconds since the shot
    /// began. Every clock-driven view reads this instead of the wall clock, so
    /// a video can be rendered one exact frame at a time.
    nonisolated(unsafe) static var filmTime: Double?

    /// The wall-clock time the film pretends it is, advancing with the shot.
    nonisolated(unsafe) static var filmDate: Date?

    /// Set by the film renderer: the level of each of the spectrum's bars for
    /// this frame, 0...1, so the bars move the same way in every render.
    nonisolated(unsafe) static var filmSpectrum: [Double]?

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// 0 → 1 over `duration`, starting after `delay`.
    static func progress(_ t: Double, delay: Double = 0, duration: Double) -> Double {
        clamp((t - delay) / max(duration, 0.0001))
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }

    static func easeInOut(_ x: Double) -> Double {
        let t = clamp(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// An underdamped spring's step response: overshoots, then settles on 1.
    /// The same curve SwiftUI's `.spring(response:dampingFraction:)` follows.
    static func spring(_ t: Double, response: Double = 0.42, damping: Double = 0.55) -> Double {
        guard t > 0 else { return 0 }
        let natural = 2 * Double.pi / response
        let zeta = min(max(damping, 0.01), 0.99)
        let damped = natural * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * natural * t)
        return 1 - decay * (cos(damped * t) + (zeta * natural / damped) * sin(damped * t))
    }
}

/// Hands its content the seconds elapsed since it first appeared, then stops
/// ticking once the entrance is over.
struct IntroTimeline<Content: View>: View {
    /// How long the content keeps changing. Past this it is drawn once more
    /// and left alone.
    var duration: Double = 1.2
    @ViewBuilder let content: (Double) -> Content

    @State private var start = Date()
    @State private var settled = false

    var body: some View {
        if let film = Motion.filmTime {
            content(film)
        } else if Motion.snapshotMode {
            content(60)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: settled)) { context in
                content(settled ? 60 : context.date.timeIntervalSince(start))
            }
            .task {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                settled = true
            }
        }
    }
}

// MARK: - Working

/// Claude Code's own spinner — the glyph that turns beside "Thinking…" in the
/// terminal — so a working session looks the way it does in Claude.
struct ClaudeSpinner: View {
    var size: CGFloat = 13
    var tint: Color = AgentPalette.claude

    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let interval = 0.12

    var body: some View {
        if let film = Motion.filmTime {
            glyph(Self.frames[Int(film / Self.interval) % Self.frames.count])
        } else if Motion.snapshotMode {
            glyph(Self.frames[4])
        } else {
            TimelineView(.periodic(from: .now, by: Self.interval)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate / Self.interval) % Self.frames.count
                glyph(Self.frames[index])
            }
        }
    }

    private func glyph(_ character: String) -> some View {
        Text(character)
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(tint)
            .shadow(color: tint.opacity(0.6), radius: size * 0.3)
            .frame(width: size * 1.3, height: size * 1.3)
    }
}

/// Codex has no signature glyph, so it gets a quiet orbit.
struct OrbitSpinner: View {
    var size: CGFloat = 13
    var tint: Color = AgentPalette.codex
    @ObservedObject private var activity = SystemActivityMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CompositedOrbit(tint: NSColor(tint), spinning: !activity.isIdle && !reduceMotion
                        && !Motion.snapshotMode && Motion.filmTime == nil,
                        angle: Motion.filmTime.map { $0 * 300 } ?? 40)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Core Animation rotates the ring without rebuilding SwiftUI 30 times a second.
private struct CompositedOrbit: NSViewRepresentable {
    let tint: NSColor
    let spinning: Bool
    let angle: Double
    func makeNSView(context: Context) -> OrbitLayerView { OrbitLayerView() }
    func updateNSView(_ view: OrbitLayerView, context: Context) {
        view.update(tint: tint, spinning: spinning, angle: angle)
    }
}

final class OrbitLayerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track); layer?.addSublayer(arc)
        for ring in [track, arc] { ring.fillColor = nil; ring.lineWidth = 1.6 }
        arc.strokeEnd = 0.3; arc.lineCap = .round
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for ring in [track, arc] {
            // Setting `frame` on a rotated layer changes its effective bounds,
            // moving the arc away from the track. Keep the rotation's pivot
            // and drawing coordinates explicit instead.
            ring.bounds = CGRect(origin: .zero, size: bounds.size)
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            ring.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }
    func update(tint: NSColor, spinning: Bool, angle: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.strokeColor = tint.withAlphaComponent(0.25).cgColor
        arc.strokeColor = tint.cgColor
        arc.transform = spinning ? CATransform3DIdentity : CATransform3DMakeRotation(-angle * .pi / 180, 0, 0, 1)
        CATransaction.commit()
        if spinning {
            if arc.animation(forKey: "orbit") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0; spin.toValue = -Double.pi * 2
                spin.duration = 1.2; spin.repeatCount = .infinity
                spin.timingFunction = CAMediaTimingFunction(name: .linear)
                arc.add(spin, forKey: "orbit")
            }
        } else { arc.removeAnimation(forKey: "orbit") }
    }
}

/// Whichever spinner belongs to the agent.
struct AgentWorkingGlyph: View {
    let agent: AgentSessionsManager.Agent
    var size: CGFloat = 13

    var body: some View {
        switch agent {
        case .claude: ClaudeSpinner(size: size)
        case .codex: OrbitSpinner(size: size * 0.95)
        }
    }
}

// MARK: - Waiting

/// A raised hand that waves every couple of seconds, with a ring that keeps
/// pulsing out from it — hard to miss, easy to ignore.
struct AgentWaitingGlyph: View {
    var size: CGFloat = 13
    /// Seconds since the wait began, when the caller already has a clock.
    var time: Double?

    var body: some View {
        if let time = time ?? Motion.filmTime {
            drawn(time)
        } else if Motion.snapshotMode {
            drawn(1.1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                drawn(context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func drawn(_ t: Double) -> some View {
        let period = 2.2
        let local = t.truncatingRemainder(dividingBy: period)
        let wave = max(0, 1 - local / 0.9)
        let ring = t.truncatingRemainder(dividingBy: 1.4) / 1.4
        return ZStack {
            Circle()
                .stroke(AgentPalette.waiting.opacity(0.55 * (1 - ring)), lineWidth: 1.2)
                .scaleEffect(0.7 + ring * 0.9)
            Image(systemName: "hand.raised.fill")
                .font(.system(size: size * 0.82, weight: .semibold))
                .foregroundStyle(AgentPalette.waiting)
                .rotationEffect(.degrees(sin(local * 16) * 16 * wave), anchor: .bottom)
        }
        .frame(width: size * 1.3, height: size * 1.3)
    }
}

// MARK: - Done

/// A circle that draws itself, a check inside it, and a small burst of sparks
/// as it lands.
struct CheckmarkBurst: View {
    /// Seconds since the check started drawing.
    let time: Double
    var size: CGFloat = 17
    var tint: Color = AgentPalette.done

    var body: some View {
        let ring = Motion.easeOut(Motion.progress(time, duration: 0.36))
        let tick = Motion.easeOut(Motion.progress(time, delay: 0.24, duration: 0.26))
        let pop = Motion.spring(time, response: 0.46, damping: 0.48)
        let burst = Motion.progress(time, delay: 0.32, duration: 0.62)

        return ZStack {
            ForEach(0 ..< 8, id: \.self) { index in
                let angle = Double(index) / 8 * 2 * Double.pi + 0.2
                let radius = Double(size) * (0.58 + 0.5 * Motion.easeOut(burst))
                Circle()
                    .fill(index.isMultiple(of: 2) ? tint : .white)
                    .frame(width: 2.3, height: 2.3)
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
                    .opacity(burst > 0 && burst < 1 ? 1 - burst : 0)
            }
            Circle()
                .fill(tint.opacity(0.18 * ring))
            Circle()
                .trim(from: 0, to: ring)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CheckShape()
                .trim(from: 0, to: tick)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .scaleEffect(0.5 + 0.5 * pop)
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
        return path
    }
}

// MARK: - Beside the cutout

/// The small light beside the camera while any session is busy: Claude's
/// spinner, or the waving hand if one of them is waiting for you, with a count
/// when there is more than one.
struct AgentPip: View {
    @ObservedObject private var agents = AgentSessionsManager.shared
    var body: some View {
        HStack(spacing: 2) {
            if agents.waitingCount > 0 { AgentWaitingGlyph(size: 12) }
            else { ClaudeSpinner(size: 12) }
            let count = agents.sessions.filter { $0.agent == .claude && $0.status.isActive }.count
            if count > 1 { Text("\(count)").font(.system(size: 9.5, weight: .bold)) }
        }
        .padding(.leading, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct AgentWingGlyph: View {
    @ObservedObject private var agents = AgentSessionsManager.shared
    var body: some View {
        Group {
            if agents.waitingCount > 0 { AgentWaitingGlyph(size: 13) }
            else { ClaudeSpinner(size: 13) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActiveCodexBadge: View {
    @ObservedObject private var agents = AgentSessionsManager.shared
    @EnvironmentObject private var viewModel: NotchViewModel
    @StateObject private var hover = CodexMenuHover()
    @State private var expanded = false
    @State private var keyboardPresentation = false
    @State private var hovered = false
    @State private var previousPin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var activity = SystemActivityMonitor.shared

    var body: some View {
        let working = agents.activeCodex.contains { $0.status == .working }
        Button { keyboardPresentation = false; expanded.toggle() } label: {
            HStack(spacing: 5) {
                CodexBrandMark().frame(width: 18, height: 18)
                if viewModel.usesPhysicalCutout {
                    Text("Codex")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
                if working {
                    CodexWorkingDots(animate: !reduceMotion && !activity.isIdle
                        && !viewModel.hiddenForFullscreen && !Motion.snapshotMode && Motion.filmTime == nil)
                        .frame(width: 16, height: 5)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: expanded)
            }
                .padding(.horizontal, 8)
                .frame(width: viewModel.usesPhysicalCutout ? viewModel.codexBadgeRect.width : nil, height: 26)
                .background {
                    Capsule().fill(.black.opacity(0.94))
                        .overlay {
                            Capsule().fill(LinearGradient(
                                colors: [SakuraTheme.accent.opacity(expanded || hovered || viewModel.codexCompletion != nil ? 0.25 : 0.13), .white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                        }
                        .overlay(Capsule().strokeBorder(NotchPalette.rim, lineWidth: 0.6))
                }
                .contentShape(Capsule())
        }.buttonStyle(NotchPressStyle())
            .overlay(alignment: .top) {
                if let completion = viewModel.codexCompletion {
                    CodexCompletionFlight(announcement: completion)
                        .id(completion.date)
                        .frame(width: 96, height: 112)
                        .overlay(alignment: .topTrailing) {
                            if viewModel.codexCompletionCount > 1 {
                                Text("\(viewModel.codexCompletionCount)")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .padding(4).background(SakuraTheme.selectedTab, in: Circle())
                                    .offset(x: -13, y: 39)
                            }
                        }
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .background(CodexMenuHoverRegion(hover: hover))
            .help("Codex: \(agents.activeCodex.count) в работе. Открыть меню чатов")
            .accessibilityLabel("Меню Codex. В работе: \(agents.activeCodex.count). Открыть чаты")
            .onReceive(NotificationCenter.default.publisher(for: .toggleCodexMenuRequested)) { notification in
                if notification.object as? String == viewModel.screenIdentifier {
                    keyboardPresentation = !expanded
                    if keyboardPresentation { NSApp.activate(ignoringOtherApps: true) }
                    expanded.toggle()
                }
            }
            .popover(isPresented: $expanded, arrowEdge: .bottom) {
                ActiveCodexList(dismiss: { expanded = false }, editing: { hover.setEditing($0) }, focusSearch: keyboardPresentation)
                    .modifier(NotchReveal())
                    .background(ActiveCodexList.surface)
                    .background(CodexMenuHoverRegion(hover: hover, isMenu: true))
                    .preferredColorScheme(.dark)
            }
            .onChange(of: expanded) { _, show in
                if show {
                    if !viewModel.usesPhysicalCutout {
                        previousPin = viewModel.pinnedOpen
                        viewModel.pinnedOpen = true
                    }
                    agents.refresh()
                    hover.start(keyboard: keyboardPresentation)
                } else {
                    hover.stop()
                    if !viewModel.usesPhysicalCutout {
                        viewModel.pinnedOpen = previousPin
                    }
                }
            }
            .onChange(of: hover.dismissRequested) { _, dismiss in
                if dismiss { expanded = false }
            }
            .onDisappear {
                hover.stop()
                if expanded && !viewModel.usesPhysicalCutout { viewModel.pinnedOpen = previousPin }
            }
    }
}

private struct CodexWorkingDots: NSViewRepresentable {
    let animate: Bool

    func makeNSView(context: Context) -> DotsView { DotsView() }
    func updateNSView(_ view: DotsView, context: Context) { view.setAnimating(animate) }

    final class DotsView: NSView {
        private let dots = (0..<3).map { _ in CALayer() }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: index * 6, y: 1, width: 4, height: 4)
                dot.cornerRadius = 2
                dot.backgroundColor = NSColor(srgbRed: 0.95, green: 0.71, blue: 0.81, alpha: 1).cgColor
                layer?.addSublayer(dot)
            }
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func setAnimating(_ enabled: Bool) {
            let start = CACurrentMediaTime()
            for (index, dot) in dots.enumerated() {
                if !enabled {
                    dot.removeAnimation(forKey: "pulse")
                } else if dot.animation(forKey: "pulse") == nil {
                    let pulse = CAKeyframeAnimation(keyPath: "opacity")
                    pulse.values = [0.28, 1.0, 0.28, 0.28]
                    pulse.keyTimes = [0, 0.24, 0.48, 1]
                    pulse.duration = 1.35
                    pulse.beginTime = dot.convertTime(start, from: nil) - Double(2 - index) * 0.16
                    pulse.repeatCount = .infinity
                    dot.add(pulse, forKey: "pulse")
                }
            }
        }
    }
}

struct ActiveCodexList: View {
    static let surface = LinearGradient(colors: [SakuraTheme.panel, NotchPalette.panel],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
    private static let rowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 5
    @ObservedObject private var agents = AgentSessionsManager.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var activity = SystemActivityMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var dismiss: () -> Void = {}
    var editing: (Bool) -> Void = { _ in }
    var focusSearch = false
    @State private var error: String?
    @State private var query = ""
    @FocusState private var searching: Bool

    private var chats: [AgentSessionsManager.Session] {
        let pinned = Set(settings.pinnedCodexChats)
        return agents.sessions.filter { session in
            session.agent == .codex && (session.status.isActive || pinned.contains(session.id)
                || agents.recentCodex.contains(where: { $0.id == session.id }))
                && (query.isEmpty || (session.name + " " + session.project).localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            if lhs.status.isActive != rhs.status.isActive { return lhs.status.isActive }
            if lhs.status.isWaiting != rhs.status.isWaiting { return lhs.status.isWaiting }
            if pinned.contains(lhs.id) != pinned.contains(rhs.id) { return pinned.contains(lhs.id) }
            return lhs.statusSince == rhs.statusSince ? lhs.id < rhs.id : lhs.statusSince > rhs.statusSince
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск чатов", text: $query).textFieldStyle(.plain).focused($searching)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
            }
            .font(.system(size: 12)).padding(9).modifier(NotchSurface(radius: 12))
            if !agents.hasScanned {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            } else if chats.isEmpty {
                Text(query.isEmpty ? "Нет чатов" : "Ничего не найдено")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
            } else {
                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) { ForEach(chats) { row($0) } }
                }
                .defaultScrollAnchor(.top)
                .frame(height: min(338, CGFloat(chats.count) * (Self.rowHeight + Self.rowSpacing) - Self.rowSpacing
                    + (chats.contains { agents.stopErrors[$0.id] != nil } ? 24 : 0)))
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 4)
            }
        }
        .padding(9).frame(width: 340).background(Self.surface)
        .environment(\.colorScheme, .dark).accessibilityLabel("Чаты Codex")
        .onChange(of: searching) { _, value in editing(value) }
        .onAppear { if focusSearch { DispatchQueue.main.async { searching = true } } }
        .onDisappear { editing(false) }
    }

    private func row(_ session: AgentSessionsManager.Session) -> some View {
        let working = session.status == .working
        let active = session.status.isActive
        return VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .trailing) {
                Button {
                    if agents.openCodexChat(session) { dismiss() }
                    else { error = "Не удалось открыть чат. Проверь, что Codex установлен." }
                } label: {
                    HStack(spacing: 10) {
                        Text(session.name)
                            .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(active ? 0.97 : 0.76))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if session.status.isWaiting || session.failure != nil || session.wasInterrupted {
                            Image(systemName: session.failure != nil ? "exclamationmark.circle" : session.status.isWaiting ? "hand.raised" : "pause.circle")
                                .font(.system(size: 12)).foregroundStyle(SakuraTheme.accent)
                                .help(session.failure ?? session.waitingReason ?? "Остановлен")
                        } else if working {
                            CodexWorkingDots(animate: !reduceMotion && !activity.isIdle
                                && !Motion.snapshotMode && Motion.filmTime == nil)
                                .frame(width: 16, height: 5)
                                .accessibilityHidden(true)
                        }
                        if session.status.isActive {
                            Color.clear.frame(width: 24, height: 1)
                                .accessibilityHidden(true)
                        }
                        Color.clear.frame(width: 22)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: Self.rowHeight)
                    .modifier(NotchHoverHighlight(tint: working ? NotchPalette.accent : .white))
                    .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressStyle())
                .help("Открыть чат «" + session.name + "»")
                .accessibilityLabel(session.name + ". Открыть чат")
                .accessibilityValue(accessibilityStatus(for: session))
                HStack(spacing: 2) {
                    if session.status.isActive {
                        CodexStopButton(session: session, compact: true, tint: .white.opacity(0.68))
                    }
                    Button { togglePin(session.id) } label: {
                        Image(systemName: settings.pinnedCodexChats.contains(session.id) ? "pin.fill" : "pin")
                            .font(.system(size: 10)).frame(width: 24, height: 30)
                    }
                    .buttonStyle(.plain).foregroundStyle(settings.pinnedCodexChats.contains(session.id) ? SakuraTheme.accent : .white.opacity(0.35))
                    .help(settings.pinnedCodexChats.contains(session.id) ? "Открепить чат" : "Закрепить чат")
                }.padding(.trailing, 6)
            }
            .modifier(NotchSurface(radius: 12, opacity: active ? 0.15 : 0.055))
            if let message = agents.stopErrors[session.id] {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
            }
        }
    }

    private func togglePin(_ id: String) {
        var pinned = settings.pinnedCodexChats
        if pinned.contains(id) { pinned.removeAll { $0 == id } }
        else { pinned.append(id) }
        settings.pinnedCodexChats = pinned
        agents.refresh()
    }

    private func accessibilityStatus(for session: AgentSessionsManager.Session) -> String {
        if let failure = session.failure { return failure }
        switch session.status {
        case .working: return "Работает"
        case .waiting: return "Ждёт ответа"
        case .idle: return session.wasInterrupted ? "Остановлен" : "Завершён"
        }
    }
}

/// A separate sibling button so Stop never also opens the chat row.
struct CodexStopButton: View {
    let session: AgentSessionsManager.Session
    var compact = false
    var tint: Color = .orange
    @ObservedObject private var agents = AgentSessionsManager.shared
    private var pending: Bool { agents.stoppingCodex.contains(session.id) }
    var body: some View {
        Button { agents.stopCodexResponse(session) } label: {
            HStack(spacing: 4) {
                Image(systemName: pending ? "hourglass" : "stop.fill").font(.system(size: 9, weight: .bold))
                if !compact { Text(pending ? "Останавливаю…" : "Стоп").font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundStyle(session.canStop ? tint : Color.secondary)
            .padding(.horizontal, 8).frame(minHeight: 28)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(pending || !session.canStop)
            .help(agents.stopErrors[session.id] ?? (session.canStop ? "Остановить ответ в чате «\(session.name)»" : "Не найден текущий ответ. Открой чат в Codex."))
            .accessibilityLabel(pending ? "Останавливаю ответ: \(session.name)" : "Остановить ответ: \(session.name)")
    }
}

/// …and how long it has been at it on the right.
struct AgentWingClock: View {
    @ObservedObject private var agents = AgentSessionsManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let session = agents.headline
            let since = session?.turnStartedAt ?? session?.statusSince ?? context.date
            Text(agents.activeCount > 1
                 ? "×\(agents.activeCount)"
                 : AgentSessionsManager.clock(context.date.timeIntervalSince(since)))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(agents.waitingCount > 0 ? AgentPalette.waiting : .white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
