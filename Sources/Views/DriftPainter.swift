import SwiftUI

struct DriftPalette {
    let sky: Color
    let horizon: Color
    let light: Color

    init(_ track: DriftTrack) {
        switch track {
        case .city:
            sky = Color(red: 0.035, green: 0.065, blue: 0.10)
            horizon = Color(red: 0.26, green: 0.42, blue: 0.47)
            light = NotchPalette.accent
        case .sunset:
            sky = Color(red: 0.51, green: 0.44, blue: 0.65)
            horizon = Color(red: 0.92, green: 0.64, blue: 0.67)
            light = Color(red: 1, green: 0.86, blue: 0.73)
        case .rain:
            sky = Color(red: 0.026, green: 0.055, blue: 0.084)
            horizon = Color(red: 0.21, green: 0.32, blue: 0.41)
            light = Color(red: 0.65, green: 0.83, blue: 1)
        }
    }

    static func car(_ car: DriftCar) -> Color {
        switch car {
        case .vector: return Color(red: 0.43, green: 0.51, blue: 0.55)
        case .inferno: return Color(red: 0.72, green: 0.21, blue: 0.24)
        case .violet: return Color(red: 0.62, green: 0.49, blue: 0.75)
        case .acid: return Color(red: 0.49, green: 0.74, blue: 0.43)
        case .gold: return Color(red: 0.81, green: 0.67, blue: 0.45)
        case .ghost: return Color(red: 0.87, green: 0.97, blue: 1)
        }
    }
    static func pickup(_ kind: DriftPickup) -> Color {
        switch kind { case .coin: return .yellow; case .nitro: return .cyan; case .shield: return .mint; case .repair: return .pink; case .magnet: return .purple }
    }
}

@MainActor
struct DriftPainter {
    private static let trafficColours: [Color] = [
        Color(red: 0.62, green: 0.38, blue: 0.42), Color(red: 0.79, green: 0.66, blue: 0.48),
        Color(red: 0.40, green: 0.57, blue: 0.75), Color(red: 0.40, green: 0.68, blue: 0.63),
        Color(red: 0.55, green: 0.48, blue: 0.64), Color(red: 0.74, green: 0.79, blue: 0.88),
        Color(red: 0.60, green: 0.30, blue: 0.33)
    ]
    let game: DriftGame
    private var world: DriftRules { game.rules }
    private let palette: DriftPalette
    init(game: DriftGame) { self.game = game; palette = DriftPalette(game.rules.track) }
    private func depth(_ z: Double) -> Double { DriftProjection.depth(z) }
    private func point(_ x: Double, _ t: Double) -> CGPoint {
        DriftProjection.position(lane: x, depth: t, curve: world.curve)
    }
    private func polygon(_ points: [CGPoint]) -> Path {
        Path { path in guard let first = points.first else { return }; path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath() }
    }
    private func playerTransform(heading: Double) -> CGAffineTransform {
        let steering = world.lateralVelocity * (world.isDrifting ? 12 : 6)
        let tilt = Angle.degrees(min(22, max(-22, steering))).radians
        // Perspective shifts the nose toward the road's vanishing point.
        // Only steering tilts the rear of the sprite.
        let shear = tan(Angle.degrees(heading).radians) - tan(tilt)
        let cosine = cos(tilt)
        let sine = sin(tilt)
        return CGAffineTransform(a: cosine - shear * sine, b: sine,
                                 c: -sine - shear * cosine, d: cosine, tx: 0, ty: 0)
    }

    func draw(in c: inout GraphicsContext) {
        let rect = CGRect(x: 0, y: 0, width: DriftRules.width, height: DriftRules.height)
        let outline = Path(rect)
        let playerAngle = DriftProjection.playerHeading(lane: world.playerX, curve: world.curve,
                                                       lateralVelocity: world.lateralVelocity, drifting: world.isDrifting)
        let pose = playerTransform(heading: playerAngle)
        skyline(&c)
        let asphalt = roadBand(from: -1.07, to: 1.07)
        road(&c, asphalt: asphalt)
        headlights(&c, asphalt: asphalt, angle: playerAngle, pose: pose)
        // Depth-sort the entire scene so nearby cars naturally cover loot.
        let traffic = world.traffic
        let loot = world.loot
        let cars = traffic.indices.filter { traffic[$0].isVisible }.map { (z: traffic[$0].z, isCar: true, index: $0) }
        let pickups = loot.indices.filter { loot[$0].z > -5 }.map { (z: loot[$0].z, isCar: false, index: $0) }
        for object in (cars + pickups).sorted(by: { $0.z > $1.z }) {
            if object.isCar {
                let car = traffic[object.index]
                let t = depth(car.z), p = point(car.x, t)
                let tint = Self.trafficColours[abs(car.tint % Self.trafficColours.count)]
                let signalOn = car.isChangingLane && Int((world.elapsed - car.signalStartedAt) * 5) % 2 == 0
                vehicle(at: p, scale: t, tint: tint, truck: car.truck, sport: car.driver == .brisk,
                        angle: car.isChangingLane && car.signalTime <= 0 ? -car.indicatorSide * 7 : 0,
                        player: false, braking: car.braking, indicator: signalOn ? car.indicatorSide : 0, in: &c)
            } else {
                pickup(loot[object.index], in: &c)
            }
        }
        player(&c, pose: pose)
        if world.track == .rain { rain(&c) }
        if world.isBoosting { speedLines(&c) }
        if game.flash > 0 { c.fill(outline, with: .color(.red.opacity(game.flash * 0.25))) }
    }
    private func skyline(_ c: inout GraphicsContext) {
        c.fill(Path(CGRect(x: 0, y: 0, width: 960, height: 384)), with: .linearGradient(
            Gradient(stops: [.init(color: palette.sky, location: 0), .init(color: palette.horizon, location: 0.68),
                             .init(color: palette.horizon.opacity(0.8), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: 130)))
        let coast = world.track == .sunset
        let glow = CGPoint(x: coast ? 665 : 740, y: coast ? 53 : 35)
        c.fill(Path(CGRect(x: 0, y: 0, width: 960, height: 140)), with: .radialGradient(
            Gradient(colors: [palette.light.opacity(coast ? 0.75 : 0.24), .clear]), center: glow,
            startRadius: 0, endRadius: coast ? 235 : 152))
        if coast {
            c.fill(Path(ellipseIn: CGRect(x: glow.x - 25, y: glow.y - 25, width: 50, height: 50)),
                   with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.96, blue: 0.84), palette.light]),
                                         startPoint: CGPoint(x: glow.x, y: glow.y - 25),
                                         endPoint: CGPoint(x: glow.x, y: glow.y + 25)))
            var cliffs = Path()
            cliffs.move(to: CGPoint(x: 0, y: 70))
            cliffs.addQuadCurve(to: CGPoint(x: 382, y: 119), control: CGPoint(x: 145, y: 58))
            cliffs.addQuadCurve(to: CGPoint(x: 960, y: 90), control: CGPoint(x: 720, y: 107))
            cliffs.addLine(to: CGPoint(x: 960, y: 151))
            cliffs.addLine(to: CGPoint(x: 0, y: 151))
            cliffs.closeSubpath()
            c.fill(cliffs, with: .linearGradient(
                Gradient(colors: [Color(red: 0.55, green: 0.39, blue: 0.55),
                                  Color(red: 0.37, green: 0.29, blue: 0.43)]),
                startPoint: CGPoint(x: 0, y: 72), endPoint: CGPoint(x: 0, y: 151)))
            return
        }

        if world.track == .city {
            var stars = Path()
            for i in 0 ..< 25 {
                let x = Double(i * 137 % 959), y = Double(i * 47 % 73) + 5
                stars.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
            }
            c.fill(stars, with: .color(.white.opacity(0.36)))
            c.fill(Path(ellipseIn: CGRect(x: glow.x - 9, y: glow.y - 9, width: 18, height: 18)),
                   with: .color(.white.opacity(0.86)))
        }
        for layer in 0 ..< 2 {
            var buildings = Path(), windows = Path(), facades = Path()
            let offset = world.curve * Double(layer + 1) * 10
            for i in 0 ..< 25 {
                let x = Double(i) * 42 - 24 + offset
                let width = 23 + Double((i * 17 + layer * 11) % 19)
                let avenue = (10 ... 13).contains(i)
                let height = avenue ? 9 + Double(i % 3) * 4 : 22 + Double((i * 37 + layer * 23) % 67)
                let y = 113 - height + Double(layer) * 5
                buildings.addRect(CGRect(x: x, y: y, width: width, height: height + 18))
                facades.addRect(CGRect(x: x + width - 5, y: y + 1, width: 5, height: height))
                if i % 6 == 1 && !avenue {
                    buildings.addRect(CGRect(x: x + 8, y: y - 5, width: width - 16, height: 5))
                }
                for row in 0 ..< Int(height / 8) {
                    for column in 0 ..< 3 where (i + row * 2 + column) % 4 < 2 {
                        windows.addRect(CGRect(x: x + 5 + Double(column) * 6, y: y + 4 + Double(row) * 8,
                                               width: 1.8, height: 2.5))
                    }
                }
            }
            c.fill(buildings, with: .color(layer == 0 ? Color(red: 0.13, green: 0.20, blue: 0.24)
                                                      : Color(red: 0.057, green: 0.084, blue: 0.11)))
            c.fill(facades, with: .color(.black.opacity(0.22)))
            c.fill(windows, with: .color(palette.light.opacity(layer == 0 ? 0.16 : 0.46)))
        }
    }

    private func roadBand(from left: Double, to right: Double) -> Path {
        let bottom = (DriftRules.height - DriftProjection.horizonY) / DriftProjection.roadHeight
        let steps = (0 ... 32).map { Double($0) * bottom / 32 }
        return polygon(steps.map { point(left, $0) } + steps.reversed().map { point(right, $0) })
    }

    private func road(_ c: inout GraphicsContext, asphalt: Path) {
        let coast = world.track == .sunset
        let shoulder = coast ? Color(red: 0.33, green: 0.25, blue: 0.34) : Color(red: 0.073, green: 0.085, blue: 0.101)
        let coastShadow = Color(red: 0.19, green: 0.16, blue: 0.23)
        c.fill(Path(CGRect(x: 0, y: 120, width: 960, height: 264)), with: .linearGradient(
            Gradient(colors: [coast ? Color(red: 0.43, green: 0.34, blue: 0.46)
                : Color(red: 0.09, green: 0.12, blue: 0.15), shoulder, coast ? coastShadow : .black]),
            startPoint: CGPoint(x: 480, y: 120), endPoint: CGPoint(x: 480, y: 384)))
        c.fill(roadBand(from: -3, to: 3), with: .linearGradient(
            Gradient(colors: [palette.horizon, shoulder, coast ? coastShadow : Color(red: 0.023, green: 0.031, blue: 0.043)]),
            startPoint: CGPoint(x: 480, y: 88), endPoint: CGPoint(x: 480, y: 384)))
        let roadMid = coast ? Color(red: 0.37, green: 0.32, blue: 0.42) : Color(red: 0.16, green: 0.20, blue: 0.25)
        let roadNear = coast ? Color(red: 0.23, green: 0.23, blue: 0.32) : Color(red: 0.072, green: 0.09, blue: 0.114)
        c.fill(asphalt, with: .linearGradient(
            Gradient(colors: [palette.horizon, roadMid, roadNear]),
            startPoint: CGPoint(x: 480, y: 90), endPoint: CGPoint(x: 480, y: 384)))

        for side in [-1.0, 1.0] {
            c.fill(roadBand(from: side * 1.008, to: side * 1.019), with: .color(.white.opacity(0.68)))
            c.fill(roadBand(from: side * 1.14, to: side * 1.17), with: .color(palette.light.opacity(0.23)))
        }

        let offset = world.distance.truncatingRemainder(dividingBy: 14)
        let bottom = (DriftRules.height - DriftProjection.horizonY) / DriftProjection.roadHeight
        let nearEdge = DriftProjection.cameraDistance / bottom - DriftProjection.cameraDistance
        var stripes = Path()
        for z in stride(from: -offset, through: 252, by: 14) where z + 6 > nearEdge {
            let near = depth(max(nearEdge, z)), far = depth(z + 6)
            for lane in [-0.5, 0.0, 0.5] {
                stripes.addPath(polygon([point(lane - 0.006, near), point(lane + 0.006, near),
                                         point(lane + 0.006, far), point(lane - 0.006, far)]))
            }
        }
        c.fill(stripes, with: .color(.white.opacity(0.52)))

        var poles = Path(), bulbs = Path(), reflectors = Path()
        let lampOffset = world.distance.truncatingRemainder(dividingBy: 32)
        for z in stride(from: 12 - lampOffset, through: 228, by: 32) where z >= 0 {
            let t = depth(z)
            for side in [-1.0, 1.0] {
                let foot = point(side * 1.23, t)
                let arm = CGPoint(x: foot.x, y: foot.y - 105 * t)
                let bulb = CGPoint(x: arm.x - side * 25 * t, y: arm.y - 4 * t)
                poles.move(to: foot)
                poles.addLine(to: arm)
                poles.addQuadCurve(to: bulb, control: CGPoint(x: arm.x, y: bulb.y))
                bulbs.addEllipse(in: CGRect(x: bulb.x - 5 * t, y: bulb.y - t, width: 10 * t, height: 3 * t))
                let reflector = point(side * 1.14, t)
                reflectors.addRect(CGRect(x: reflector.x - 2 * t, y: reflector.y - 5 * t, width: 4 * t, height: 4 * t))
                if world.track == .rain {
                    c.fill(Path(ellipseIn: CGRect(x: foot.x - 16 * t, y: foot.y - 5 * t, width: 32 * t, height: 44 * t)),
                           with: .linearGradient(Gradient(colors: [palette.light.opacity(0.30), .clear]),
                                                 startPoint: foot, endPoint: CGPoint(x: foot.x, y: foot.y + 44 * t)))
                }
            }
        }
        c.stroke(poles, with: .color(.black.opacity(0.72)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        c.fill(bulbs, with: .color(palette.light))
        c.fill(reflectors, with: .color(palette.light.opacity(0.68)))
        if world.track == .sunset { palms(&c) }
    }

    private func palms(_ c: inout GraphicsContext) {
        let silhouette = Color(red: 0.24, green: 0.17, blue: 0.27)
        for i in 0 ..< 6 {
            let t = depth(Double(i) * 26 + 8)
            for side in [-1.0, 1] {
                let p = point(side * 1.38, t), top = CGPoint(x: point(side * 1.38, t).x - side * 10 * t, y: p.y - 106 * t)
                var palm = Path(); palm.move(to: p); palm.addQuadCurve(to: top, control: CGPoint(x: p.x, y: p.y - 75 * t))
                c.stroke(palm, with: .color(silhouette), lineWidth: 6 * t)
                for j in 0 ..< 7 {
                    let angle = Double(j) * .pi / 5 - .pi * 1.1
                    var leaf = Path(); leaf.move(to: top)
                    leaf.addQuadCurve(to: CGPoint(x: top.x + cos(angle) * 48 * t, y: top.y + sin(angle) * 32 * t + 12 * t),
                                      control: CGPoint(x: top.x + cos(angle) * 25 * t, y: top.y + sin(angle) * 50 * t))
                    c.stroke(leaf, with: .color(silhouette), style: StrokeStyle(lineWidth: 4 * t, lineCap: .round))
                }
            }
        }
    }
    private func headlights(_ context: inout GraphicsContext, asphalt: Path, angle: Double, pose: CGAffineTransform) {
        let remaining = world.highBeamRemaining
        let flash = max(0, min(1, (0.65 - remaining) / 0.075, remaining / 0.20))
        let reach = 37 + 94 * flash
        let origin = point(world.playerX, DriftProjection.playerDepth)
        let bonnet = DriftProjection.bonnetDepth
        let frontZ = DriftProjection.metres(at: bonnet)
        let beamSlope = tan(Angle.degrees(angle).radians)
        let beamEndY = point(0, depth(frontZ + reach)).y
        let bonnetY = point(0, bonnet).y
        var roadLight = context
        roadLight.clip(to: asphalt)

        for side in [-1.0, 1.0] {
            // The beam begins at the rotated lamp, then narrows on screen
            // as the projected footprint moves away from the camera.
            let x = side * 23
            let offset = CGPoint(x: x, y: -DriftProjection.bonnetLength).applying(pose)
            let lamp = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
            let sections = [0.08, 0.18, 0.32, 0.51, 0.74, 1.0]
            for width in [1.0, 0.48] {
                var left = [CGPoint(x: lamp.x - 3 * width, y: lamp.y)]
                var right = [CGPoint(x: lamp.x + 3 * width, y: lamp.y)]
                for section in sections {
                    let metres = section * reach
                    let spread = (0.036 + metres * 0.0023) * width
                    let perspective = depth(frontZ + metres)
                    let projectedY = point(0, perspective).y
                    let screenY = projectedY + (lamp.y - bonnetY) * perspective / bonnet
                    let convergence = x * pose.a * (1 - perspective / bonnet)
                    let center = lamp.x + beamSlope * (lamp.y - screenY) - convergence
                    let halfWidth = spread * DriftProjection.laneScale(at: perspective)
                    left.append(CGPoint(x: center - halfWidth, y: screenY))
                    right.append(CGPoint(x: center + halfWidth, y: screenY))
                }
                let brightness = width == 1 ? 0.065 + 0.11 * flash : 0.035 + 0.09 * flash
                roadLight.fill(polygon(left + right.reversed()), with: .linearGradient(
                    Gradient(stops: [.init(color: .white.opacity(brightness), location: 0),
                                     .init(color: .white.opacity(brightness * 0.68), location: 0.48),
                                     .init(color: .clear, location: 1)]),
                    startPoint: lamp, endPoint: CGPoint(x: lamp.x, y: beamEndY)))
            }
        }
    }
    private func pickup(_ item: DriftRules.Loot, in c: inout GraphicsContext) {
        let t = depth(item.z), ground = point(item.x, t)
        let p = CGPoint(x: ground.x, y: ground.y - t * 15)
        let tint = DriftPalette.pickup(item.kind), r = (item.kind == .coin ? 9.0 : 13) * t
        c.fill(Path(ellipseIn: CGRect(x: p.x - r * 2, y: p.y - r * 2, width: r * 4, height: r * 4)), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.28), .clear]), center: p, startRadius: 0, endRadius: r * 2))
        if item.kind == .coin {
            c.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.7, y: p.y - r, width: r * 1.4, height: r * 2)), with: .color(.yellow))
            c.stroke(Path(ellipseIn: CGRect(x: p.x - r * 0.4, y: p.y - r * 0.75, width: r * 0.8, height: r * 1.5)), with: .color(.orange), lineWidth: t * 1.5)
        } else {
            c.fill(Path(roundedRect: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2), cornerRadius: r * 0.3), with: .color(tint))
            var icon = c.resolve(Image(systemName: item.kind.symbol)); icon.shading = .color(.black.opacity(0.85))
            c.draw(icon, in: CGRect(x: p.x - r * 0.6, y: p.y - r * 0.6, width: r * 1.2, height: r * 1.2))
        }
    }
    private func player(_ c: inout GraphicsContext, pose: CGAffineTransform) {
        let p = point(world.playerX, DriftProjection.playerDepth), tint = DriftPalette.car(game.car)
        // The skid marks follow recorded tyre positions rather than random sparks.
        for trail in game.trails {
            let age = world.elapsed - trail.time
            if age > 1.0 { continue }
            let t = depth((world.distance - trail.distance) * 0.45)
            let start = point(trail.x, min(0.94, t)), end = point(trail.x, max(0, t - 0.025))
            for side in [-1.0, 1] {
                var mark = Path(); mark.move(to: CGPoint(x: start.x + side * 23 * t, y: start.y))
                mark.addLine(to: CGPoint(x: end.x + side * 23 * t, y: end.y))
                c.stroke(mark, with: .color(tint.opacity((1 - age) * 0.4)), style: StrokeStyle(lineWidth: 3 * t, lineCap: .round))
            }
        }
        c.fill(Path(ellipseIn: CGRect(x: p.x - 52, y: p.y - 15, width: 104, height: 25)), with: .radialGradient(
            Gradient(colors: [tint.opacity(0.5), .clear]), center: CGPoint(x: p.x, y: p.y - 2), startRadius: 0, endRadius: 55))
        var carContext = c
        if world.invulnerability > 0 && Int(world.elapsed * 13) % 2 == 0 { carContext.opacity = 0.45 }
        vehicle(at: p, scale: 1, tint: tint, truck: false,
                angle: 0, player: true, braking: world.isBraking, pose: pose, in: &carContext)
        if world.shield {
            c.stroke(Path(ellipseIn: CGRect(x: p.x - 45, y: p.y - 66, width: 90, height: 79)), with: .color(.mint.opacity(0.6)), lineWidth: 1.7)
        }
        if world.isDrifting {
            for i in 0 ..< 8 {
                let a = Double(i) * 1.7 + world.elapsed * 2
                let x = p.x - world.lateralVelocity * Double(i) * 4
                let y = p.y - 1 - Double(i) * 4
                c.fill(Path(ellipseIn: CGRect(x: x + sin(a) * 17, y: y, width: 2.5, height: 2.5)), with: .color(i % 2 == 0 ? .white : tint))
            }
        }
    }
    private func vehicle(at p: CGPoint, scale: Double, tint: Color, truck: Bool, sport: Bool = false, angle: Double,
                         player: Bool, braking: Bool = false, indicator: Double = 0, pose: CGAffineTransform? = nil,
                         in context: inout GraphicsContext) {
        var c = context
        c.translateBy(x: p.x, y: p.y)
        c.scaleBy(x: scale, y: scale)
        if let pose { c.concatenate(pose) }
        else { c.rotate(by: .degrees(angle)) }
        let w = truck ? 43.0 : (player ? 39 : 32), h = truck ? 91.0 : (player ? 67 : 55)
        c.fill(Path(ellipseIn: CGRect(x: -w * 1.2, y: -6, width: w * 2.4, height: 15)), with: .color(.black.opacity(0.65)))
        for side in [-1.0, 1] {
            c.fill(Path(roundedRect: CGRect(x: side * w - 5, y: -29, width: 10, height: 22), cornerRadius: 3), with: .color(Color(white: 0.025)))
        }
        let body: Path
        if player {
            body = Path { p in
                p.move(to: CGPoint(x: -w, y: -2))
                p.addLine(to: CGPoint(x: -w - 3, y: -20))
                p.addQuadCurve(to: CGPoint(x: -w + 2, y: -43), control: CGPoint(x: -w - 5, y: -35))
                p.addLine(to: CGPoint(x: -w * 0.73, y: -h + 3))
                p.addQuadCurve(to: CGPoint(x: w * 0.73, y: -h + 3), control: CGPoint(x: 0, y: -h - 4))
                p.addLine(to: CGPoint(x: w - 2, y: -43))
                p.addQuadCurve(to: CGPoint(x: w + 3, y: -20), control: CGPoint(x: w + 5, y: -35))
                p.addLine(to: CGPoint(x: w, y: -2)); p.closeSubpath()
            }
        } else {
            let nose = w * (truck ? 0.94 : sport ? 0.60 : 0.70)
            body = polygon([CGPoint(x: -w, y: -4), CGPoint(x: -w - 1, y: -25), CGPoint(x: -nose, y: -h),
                            CGPoint(x: nose, y: -h), CGPoint(x: w + 1, y: -25), CGPoint(x: w, y: -4)])
        }
        c.fill(body, with: .linearGradient(Gradient(colors: [tint, tint, .black.opacity(0.92)]), startPoint: CGPoint(x: -w, y: -h), endPoint: CGPoint(x: w, y: 13)))
        c.stroke(body, with: .color(player ? .white.opacity(0.5) : tint.opacity(0.84)), lineWidth: 1.5)
        if truck {
            let doors = Path(roundedRect: CGRect(x: -w + 5, y: -h + 5, width: w * 2 - 10, height: h - 19), cornerRadius: 3)
            c.fill(doors, with: .color(.black.opacity(0.28)))
            c.stroke(doors, with: .color(.white.opacity(0.32)), lineWidth: 1.3)
            var seam = Path()
            seam.move(to: CGPoint(x: 0, y: -h + 6))
            seam.addLine(to: CGPoint(x: 0, y: -19))
            c.stroke(seam, with: .color(.black.opacity(0.55)), lineWidth: 1.5)
        } else {
            let glassTop = -h + (sport ? 17 : 12)
            let glass = polygon([CGPoint(x: -w * 0.72, y: -29), CGPoint(x: -w * 0.57, y: glassTop),
                                 CGPoint(x: w * 0.57, y: glassTop), CGPoint(x: w * 0.72, y: -29)])
            c.fill(glass, with: .linearGradient(Gradient(colors: [Color(red: 0.03, green: 0.08, blue: 0.10), .black]), startPoint: CGPoint(x: 0, y: -h), endPoint: .zero))
            c.stroke(glass, with: .color(.white.opacity(0.2)), lineWidth: 1)
        }
        c.fill(Path(roundedRect: CGRect(x: -w, y: -23, width: w * 2, height: 22), cornerRadius: 4), with: .color(tint))
        if player {
            // Challenger-style wide rear, black deck, full-width racetrack lights.
            let trim = game.car == .vector ? NotchPalette.accent.opacity(0.72) : tint
            c.fill(Path(roundedRect: CGRect(x: -w + 3, y: -23, width: w * 2 - 6, height: 14), cornerRadius: 4), with: .color(Color(white: 0.025)))
            c.stroke(Path(roundedRect: CGRect(x: -w + 6, y: -21, width: w * 2 - 12, height: 10), cornerRadius: 3),
                     with: .color(.red), lineWidth: 2.4)
            c.fill(Path(CGRect(x: -12, y: -23, width: 24, height: 13)), with: .color(Color(white: 0.025)))
            c.draw(Text("SRT").font(.system(size: 6, weight: .black, design: .rounded)).foregroundColor(.white), at: CGPoint(x: 0, y: -16))
            c.fill(Path(roundedRect: CGRect(x: -w - 2, y: -29, width: w * 2 + 4, height: 4), cornerRadius: 1), with: .color(.black))
            for dx in [-11.0, 7] {
                c.fill(Path(CGRect(x: dx, y: -h + 2, width: 4, height: 13)), with: .color(trim))
            }
            c.stroke(Path(roundedRect: CGRect(x: -w + 1, y: -4, width: w * 2 - 2, height: 3), cornerRadius: 1), with: .color(trim), lineWidth: 1)
            for dx in [-25.0, 25] {
                c.fill(Path(roundedRect: CGRect(x: dx - 5, y: -2, width: 10, height: 5), cornerRadius: 2), with: .color(.gray))
                c.fill(Path(roundedRect: CGRect(x: dx - 3, y: -1, width: 6, height: 3), cornerRadius: 1), with: .color(.black))
                if world.exhaustRemaining > 0 || world.isBoosting {
                    let pop = world.exhaustRemaining > 0
                    let flicker = 0.75 + abs(sin(world.elapsed * 67)) * 0.25
                    let length = (pop ? 29.0 : 21) * flicker
                    let hot: Color = pop ? .orange : .cyan
                    c.fill(Path(ellipseIn: CGRect(x: dx - 14, y: -5, width: 28, height: 35)), with: .radialGradient(
                        Gradient(colors: [hot.opacity(0.65), .clear]), center: CGPoint(x: dx, y: 8), startRadius: 1, endRadius: 20))
                    c.fill(polygon([CGPoint(x: dx - 5, y: 1), CGPoint(x: dx + 5, y: 1), CGPoint(x: dx + 3, y: length * 0.5),
                                    CGPoint(x: dx, y: length), CGPoint(x: dx - 4, y: length * 0.4)]),
                           with: .linearGradient(Gradient(colors: [.white, hot, (pop ? Color.red : .blue).opacity(0)]),
                                                  startPoint: CGPoint(x: dx, y: 0), endPoint: CGPoint(x: dx, y: length)))
                }
            }
        } else if sport {
            c.fill(Path(roundedRect: CGRect(x: -w + 4, y: -18, width: w * 2 - 8, height: 4), cornerRadius: 2), with: .color(.red))
        } else {
            for x in [-w + 5, w - 16] {
                c.fill(Path(roundedRect: CGRect(x: x, y: -17, width: 11, height: 5), cornerRadius: 1), with: .color(.red))
            }
        }
        if braking {
            c.fill(Path(ellipseIn: CGRect(x: -w - 6, y: -27, width: w * 2 + 12, height: 25)), with: .radialGradient(
                Gradient(colors: [.red.opacity(0.55), .clear]), center: CGPoint(x: 0, y: -14), startRadius: 0, endRadius: w + 10))
            c.fill(Path(CGRect(x: -w + 4, y: -17, width: w * 2 - 8, height: 5)), with: .color(Color(red: 1, green: 0.3, blue: 0.3)))
        }
        if indicator != 0 {
            let x = indicator < 0 ? -w + 2 : w - 9
            c.fill(Path(CGRect(x: x, y: -18, width: 8, height: 7)), with: .color(.orange))
        }
        c.fill(Path(CGRect(x: -9, y: -9, width: 18, height: 5)), with: .color(.white.opacity(0.7)))
        c.fill(Path(CGRect(x: -w + 3, y: -3, width: w * 2 - 6, height: 4)), with: .color(.black.opacity(0.75)))
    }
    private func rain(_ c: inout GraphicsContext) {
        var lines = Path()
        for i in 0 ..< 55 {
            let x = Double(i * 107 % 1021) - 30
            let y = (Double(i * 71) + world.elapsed * 510).truncatingRemainder(dividingBy: 400) - 16
            lines.move(to: CGPoint(x: x, y: y)); lines.addLine(to: CGPoint(x: x - 7, y: y + 17))
        }
        c.stroke(lines, with: .color(palette.light.opacity(0.21)), lineWidth: 0.8)
    }
    private func speedLines(_ c: inout GraphicsContext) {
        var streaks = Path()
        for i in 0 ..< 16 {
            let side = i % 2 == 0 ? -1.0 : 1
            let t = (Double(i) / 16 + world.elapsed * 1.8).truncatingRemainder(dividingBy: 1)
            let x = 480 + side * (260 + t * 230), y = 95 + t * 285
            streaks.move(to: CGPoint(x: x, y: y)); streaks.addLine(to: CGPoint(x: x + side * 30, y: y + 45))
        }
        c.stroke(streaks, with: .color(NotchPalette.accent.opacity(0.36)), lineWidth: 1.5)
    }
}
