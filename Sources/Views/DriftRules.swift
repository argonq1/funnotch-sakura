import Foundation

/// Shared by drawing and simulation: an NPC leaves only once its entire
/// rotated body has passed the bottom edge. Negative Z keeps moving on screen.
enum DriftProjection {
    static let cameraDistance = 22.0
    static let horizonY = 91.0
    static let roadHeight = 281.0
    static let playerDepth = 0.94
    static let bonnetLength = 62.0
    static let bonnetDepth = playerDepth - bonnetLength / roadHeight

    static func depth(_ z: Double) -> Double { cameraDistance / (cameraDistance + max(-12, z)) }
    static func metres(at depth: Double) -> Double { cameraDistance / depth - cameraDistance }
    static func laneScale(at depth: Double) -> Double { 26 + 354 * depth }

    static func position(lane: Double, depth: Double, curve: Double) -> CGPoint {
        let inset = 1 - depth
        return CGPoint(x: DriftRules.width / 2 + curve * 145 * inset * inset + lane * laneScale(at: depth),
                       y: horizonY + depth * roadHeight)
    }

    static func playerLane(at screenX: Double, curve: Double) -> Double {
        let center = position(lane: 0, depth: playerDepth, curve: curve)
        return (screenX - center.x) / laneScale(at: playerDepth)
    }

    static func playerHeading(lane: Double, curve: Double, lateralVelocity: Double, drifting: Bool) -> Double {
        let rear = position(lane: lane, depth: playerDepth, curve: curve)
        let ahead = position(lane: lane, depth: bonnetDepth, curve: curve)
        let roadHeading = atan2(ahead.x - rear.x, rear.y - ahead.y) * 180 / .pi
        let heading = roadHeading * 0.68 + lateralVelocity * (drifting ? 12 : 6)
        return min(38, max(-38, heading))
    }

    static func exitZ(truck: Bool) -> Double {
        // Includes the roof, outline and the maximum seven-degree lane turn.
        let frontExtent = truck ? 98.0 : 60.0
        return cameraDistance * (roadHeight - frontExtent) / (DriftRules.height - horizonY) - cameraDistance
    }
}

enum DriftTrack: String, CaseIterable, Identifiable {
    case city, sunset, rain
    var id: String { rawValue }
    var title: String {
        switch self { case .city: return "Southside"; case .sunset: return "West Coast"; case .rain: return "After Hours" }
    }
    var detail: String {
        switch self { case .city: return "Ночной город"; case .sunset: return "Побережье на закате"; case .rain: return "Дождь · больше скольжения" }
    }
}

enum DriftCar: String, CaseIterable, Identifiable {
    case vector, inferno, violet, acid, gold, ghost
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vector: return "Hellcat SRT"; case .inferno: return "SRT · Redeye"; case .violet: return "SRT · Purple"
        case .acid: return "SRT · Slime"; case .gold: return "SRT · Gold"; case .ghost: return "SRT · Ghost"
        }
    }
}

enum DriftPickup: String, CaseIterable {
    case coin, nitro, shield, repair, magnet
    var symbol: String {
        switch self {
        case .coin: return "circle.inset.filled"; case .nitro: return "bolt.fill"; case .shield: return "shield.fill"
        case .repair: return "cross.case.fill"; case .magnet: return "dot.radiowaves.left.and.right"
        }
    }
    var title: String {
        switch self { case .coin: return "+1 монета"; case .nitro: return "Нитро +45"; case .shield: return "Щит"; case .repair: return "Ремонт +1"; case .magnet: return "Магнит · 8 сек" }
    }
}

/// Pure world simulation. X is road-relative (-1...1); Z is metres ahead.
struct DriftRules {
    static let width = 960.0
    static let height = 384.0
    static let lanes = [-0.75, -0.25, 0.25, 0.75]
    static let playerHalfWidth = 0.08
    static let comboGrace = 4.2
    static let dangerousSpeedKPH = 350.0
    static let speedometerScaleKPH = 520.0
    static let finishDistance = 18_000.0
    static let minimumBoostCharge = 12.0
    static func steeringDamping(track: DriftTrack, drifting: Bool) -> Double {
        drifting ? 4.6 : (track == .rain ? 13.0 : 15.0)
    }
    static func steeringAcceleration(drifting: Bool) -> Double { drifting ? 11 : 26 }
    static func targetSteering(target: Double, x: Double, velocity: Double) -> Double {
        clamp((target - x) * 5.5 - velocity * 0.85, -1, 1)
    }
    enum Phase { case ready, running, paused, over, finished }
    enum HeadlightResult { case unavailable, flashed, yielded, blocked }
    struct Input {
        var steer = 0.0
        var drift = false
        var throttle = false
        var nitro = false
        var brake = false
        var targetX: Double?
    }
    struct Traffic: Identifiable {
        enum Driver { case calm, commuter, brisk }
        let id: Int
        var x: Double
        var z: Double
        var tint: Int
        var truck = false
        var passed = false
        var speedKPH = 100.0
        var targetX: Double?
        var signalTime = 0.0
        var signalStartedAt = 0.0
        var yieldingToPlayer = false
        var braking = false
        var closestGap = Double.infinity
        var passSide = 0
        var contacted = false
        var driver: Driver = .commuter
        var currentSpeedKPH: Double?
        var laneChangeCooldown = 0.0
        var effectiveSpeedKPH: Double { currentSpeedKPH ?? speedKPH }
        var laneChangeRate: Double { truck ? 0.32 : (driver == .brisk ? 0.60 : 0.46) }
        var halfWidth: Double { truck ? 0.12 : 0.09 }
        var collisionLength: Double { truck ? 5.5 : 4.3 }
        var isVisible: Bool { z > DriftProjection.exitZ(truck: truck) }
        var isChangingLane: Bool { targetX != nil }
        var indicatorSide: Double { targetX.map { $0 > x ? 1 : -1 } ?? 0 }
    }
    struct Loot: Identifiable {
        let id: Int
        let x: Double
        var z: Double
        let kind: DriftPickup
    }
    enum Event {
        case pickup(DriftPickup)
        case nearMiss(Int)
        case weave(Int, Int)
        case hit(Int)
        case shieldBreak
        case crashed
        case finished
        case levelUp(Int)
        case boost
        case backfire
    }
    let track: DriftTrack
    private(set) var phase: Phase = .ready
    private(set) var playerX = 0.25
    private(set) var lateralVelocity = 0.0
    private(set) var distance = 0.0
    private(set) var elapsed = 0.0
    private(set) var speedKPH = 130.0
    private(set) var points = 0.0
    private(set) var coins = 0
    private(set) var health = 3
    private(set) var overtakes = 0
    private(set) var weaveStreak = 0
    private(set) var bestWeave = 0
    private(set) var laneChangeCount = 0
    private(set) var isBraking = false
    private(set) var highBeamRemaining = 0.0
    private(set) var highBeamCooldown = 0.0
    private(set) var exhaustRemaining = 0.0
    private(set) var exhaustCooldown = 0.0
    private(set) var nitro = 70.0
    private(set) var shield = false
    private(set) var magnet = 0.0
    private(set) var invulnerability = 0.0
    private(set) var combo = 1
    private(set) var comboTime = 0.0
    private(set) var driftTime = 0.0
    private(set) var isDrifting = false
    private(set) var isBoosting = false
    private(set) var crashAge = 0.0
    private(set) var traffic: [Traffic] = []
    private(set) var loot: [Loot] = []
    private var spawnIn = 2.6
    private var maneuverIn = 4.0
    private var lastPassAt = -100.0
    private var lastPassSide = 0
    private var lastWeaveX = 0.25
    private var nextID = 0
    private var safeLane = 2
    private var shoulderTime = 0.0
    private var seed: UInt64
    private var nitroExhausted = false
    private var nitroRecoveryTime = 0.0
    var score: Int { Int(points) }
    var level: Int { 1 + Int(distance / 650) }
    /// A short warm-up followed by steadily denser traffic toward the finish.
    private var intensity: Double {
        let progress = max(0, distance - 480)
        return progress / (progress + 3_000)
    }
    var cruiseSpeedKPH: Double { 155 + 105 * intensity }
    var spawnInterval: Double {
        let warmup = min(1, elapsed / 10)
        let highSpeed = Self.clamp((speedKPH - 155) / 245, 0, 1)
        return (2.6 - 0.55 * warmup - 1.62 * intensity) * (1 - 0.32 * highSpeed)
    }

    static func throttleAcceleration(at speed: Double) -> Double {
        34 - 0.0002125 * speed * speed
    }

    static func nextSpeed(from speed: Double, cruise: Double, braking: Bool,
                          throttle: Bool, boosting: Bool, step: Double) -> Double {
        if braking { return speed - min(max(0, speed - min(72, cruise * 0.62)), 104 * step) }
        // The engine and nitro fight quadratic drag. Speed approaches its
        // equilibrium gradually, including when nitro runs out under throttle.
        if boosting { return speed + (131 - 0.00049 * speed * speed) * step }
        if throttle { return speed + throttleAcceleration(at: speed) * step }
        if speed < cruise { return min(cruise, speed + 27 * step) }
        return max(cruise, speed - (17 + (speed - cruise) * 0.19) * step)
    }
    var curve: Double { sin(distance / 165) * 0.72 + sin(distance / 370) * 0.22 }
    var hasDanger: Bool { abs(playerX) > 0.94 }
    var relativeSpeed: Double { max(0, (speedKPH - 100) / 3.6) }
    func closingSpeed(for car: Traffic) -> Double { (speedKPH - car.effectiveSpeedKPH) / 3.6 }
    func predictedX(of car: Traffic, after seconds: Double) -> Double {
        guard let target = car.targetX else { return car.x }
        let travel = max(0, seconds - car.signalTime) * car.laneChangeRate
        return car.x + Self.clamp(target - car.x, -travel, travel)
    }

    init(track: DriftTrack = .city, seed: UInt64 = UInt64.random(in: 1 ... UInt64.max),
         traffic: [Traffic]? = nil, loot: [Loot]? = nil) {
        self.track = track; self.seed = seed == 0 ? 1 : seed
        if let traffic { self.traffic = traffic; nextID = (traffic.map(\.id).max() ?? 0) + 1 }
        else {
            // Two open middle lanes let the player learn the controls first.
            for lane in [0, 3] {
                self.traffic.append(Traffic(id: nextID, x: Self.lanes[lane], z: 110 + Double(lane % 2) * 12,
                                            tint: lane, speedKPH: 94 + Double(lane) * 3))
                nextID += 1
            }
            for lane in [1, 3] {
                self.traffic.append(Traffic(id: nextID, x: Self.lanes[lane], z: 180 + Double(lane % 2) * 12,
                                            tint: lane + 1, truck: lane == 0, speedKPH: 106))
                nextID += 1
            }
            safeLane = 2
        }
        self.loot = loot ?? [Loot(id: -1, x: -0.25, z: 82, kind: .coin), Loot(id: -2, x: -0.25, z: 87, kind: .coin),
                             Loot(id: -3, x: 0.25, z: 139, kind: .nitro)]
    }
    mutating func start() { if phase == .ready || phase == .paused { phase = .running } }
    mutating func pause() {
        if phase == .running { phase = .paused }
        isBoosting = false; isDrifting = false; isBraking = false
        exhaustRemaining = 0
    }

    @discardableResult
    mutating func popExhaust() -> Bool {
        guard phase == .running, exhaustCooldown <= 0 else { return false }
        exhaustRemaining = 0.42; exhaustCooldown = 1.1
        return true
    }

    mutating func flashHeadlights() -> HeadlightResult {
        guard phase == .running, highBeamCooldown <= 0 else { return .unavailable }
        highBeamRemaining = 0.65; highBeamCooldown = 4.0
        guard let i = traffic.indices.filter({
            traffic[$0].z > 10 && traffic[$0].z < 125 && abs(traffic[$0].x - playerX) < 0.30
        }).min(by: { traffic[$0].z < traffic[$1].z }) else { return .flashed }
        if traffic[i].isChangingLane { return .yielded }
        let car = traffic[i]
        for direction in [1.0, -1.0] {
            let target = car.x + direction * 0.5
            let duration = 0.32 + 0.5 / car.laneChangeRate
            guard abs(target) < 0.85, isLaneClear(target, beside: car, after: duration),
                  leavesPassingLane(at: target, beside: car, after: duration) else { continue }
            traffic[i].targetX = target; traffic[i].signalTime = 0.32
            traffic[i].signalStartedAt = elapsed
            traffic[i].yieldingToPlayer = true
            return .yielded
        }
        return .blocked
    }
    mutating func advance(by delta: Double, input: Input = Input()) -> [Event] {
        guard delta.isFinite, delta > 0, phase == .running || phase == .over else { return [] }
        let dt = min(delta, 0.1)
        // Do not let an already off-screen car return as an invisible obstacle
        // when the player brakes and its relative speed reverses.
        traffic.removeAll { !$0.isVisible }
        let steps = max(1, Int(ceil(dt * 120)))
        var events: [Event] = []
        for _ in 0 ..< steps {
            let step = dt / Double(steps)
            if phase == .over { crashAge += step; continue }
            elapsed += step
            highBeamRemaining = max(0, highBeamRemaining - step)
            highBeamCooldown = max(0, highBeamCooldown - step)
            exhaustRemaining = max(0, exhaustRemaining - step)
            exhaustCooldown = max(0, exhaustCooldown - step)
            invulnerability = max(0, invulnerability - step)
            magnet = max(0, magnet - step)
            comboTime = max(0, comboTime - step)
            if comboTime == 0 { combo = 1; weaveStreak = 0 }
            let oldLevel = level
            let wasBoosting = isBoosting
            let wasBraking = isBraking
            if !input.nitro { nitroExhausted = false }
            isBraking = input.brake
            isBoosting = input.nitro && !isBraking && !nitroExhausted
                && (wasBoosting ? nitro > 0 : nitro >= Self.minimumBoostCharge)
            if input.nitro {
                nitroRecoveryTime = 1.1
            } else {
                nitroRecoveryTime = max(0, nitroRecoveryTime - step)
                if nitroRecoveryTime == 0 { nitro = min(100, nitro + step * 1.6) }
            }
            if isBoosting {
                let drain = 32 + max(0, speedKPH - 155) * 0.026
                nitro = max(0, nitro - step * drain)
                if nitro == 0 { nitroExhausted = true }
                if !wasBoosting { events.append(.boost) }
            }
            speedKPH = Self.nextSpeed(from: speedKPH, cruise: cruiseSpeedKPH,
                                      braking: isBraking, throttle: input.throttle, boosting: isBoosting, step: step)
            if hasDanger { speedKPH -= min(max(0, speedKPH - 64), 58 * step) }
            if (wasBoosting && !isBoosting) || (isBraking && !wasBraking && cruiseSpeedKPH > 175) {
                if popExhaust() { events.append(.backfire) }
            }

            let steering: Double
            if let target = input.targetX, target.isFinite {
                steering = Self.targetSteering(target: target, x: playerX, velocity: lateralVelocity)
            } else { steering = input.steer.isFinite ? Self.clamp(input.steer, -1, 1) : 0 }
            let drifting = input.drift && abs(lateralVelocity) > 0.23 && !hasDanger
            let slippery = Self.steeringDamping(track: track, drifting: input.drift)
            let acceleration = Self.steeringAcceleration(drifting: input.drift)
            lateralVelocity += (steering * acceleration - lateralVelocity * slippery) * step
            lateralVelocity = Self.clamp(lateralVelocity, -2.1, 2.1)
            playerX = Self.clamp(playerX + lateralVelocity * step, -1.18, 1.18)
            shoulderTime = hasDanger ? shoulderTime + step : max(0, shoulderTime - 2 * step)
            isDrifting = drifting
            if drifting {
                driftTime += step
                let inTraffic = traffic.contains { abs($0.z) < 22 && abs($0.x - playerX) < 0.65 }
                if inTraffic {
                    points += step * 8 * Double(combo)
                    nitro = min(100, nitro + step * 5)
                }
            }
            let metres = min(Self.finishDistance - distance, speedKPH / 3.6 * step)
            distance += metres
            if !hasDanger { points += metres * 0.35 }
            if oldLevel != level { events.append(.levelUp(level)) }
            let move = relativeSpeed * step
            updateTraffic(by: step)
            for i in loot.indices { loot[i].z -= move }

            // Resolve pickups first so a just-collected shield can save a hit.
            var collected = Set<Int>()
            for item in loot where abs(item.z) < 4.5 {
                let reach = item.kind == .coin && magnet > 0 ? 0.9 : 0.23
                if abs(item.x - playerX) < reach {
                    collected.insert(item.id)
                    grant(item.kind)
                    events.append(.pickup(item.kind))
                }
            }
            loot.removeAll { collected.contains($0.id) || $0.z < -12 }
            if (abs(playerX) > 1.12 || shoulderTime > 0.72) && invulnerability == 0 {
                impact(events: &events)
            }
            for i in traffic.indices {
                if phase != .running { break }
                let car = traffic[i]
                let clearance = abs(car.x - playerX)
                if car.isVisible && abs(car.z) < car.collisionLength {
                    if clearance < car.halfWidth + Self.playerHalfWidth {
                        traffic[i].contacted = true
                        if invulnerability == 0 { impact(events: &events) }
                    } else if clearance < traffic[i].closestGap {
                        traffic[i].closestGap = clearance
                        traffic[i].passSide = playerX > car.x ? 1 : -1
                    }
                }
                if !car.isVisible && !car.passed {
                    traffic[i].passed = true
                    overtakes += 1
                    let gap = traffic[i].closestGap
                    if !hasDanger && !traffic[i].contacted && gap >= car.halfWidth + Self.playerHalfWidth
                        && gap < car.halfWidth + 0.26 && invulnerability == 0 {
                        recordPass(side: traffic[i].passSide, events: &events)
                    }
                }
            }
            traffic.removeAll { !$0.isVisible || $0.z > 360 }
            guard phase == .running else { continue }
            if distance >= Self.finishDistance {
                phase = .finished
                isBoosting = false; isDrifting = false; isBraking = false
                events.append(.finished)
                break
            }
            spawnIn -= step
            if spawnIn <= 0 {
                spawnWave()
                spawnIn = spawnInterval * (0.92 + random() * 0.24)
            }
        }
        return events
    }

    private mutating func grant(_ kind: DriftPickup) {
        switch kind {
        case .coin: coins += 1; points += 25 * Double(combo)
        case .nitro: nitro = min(100, nitro + 45)
        case .shield: shield = true
        case .repair: health = min(3, health + 1)
        case .magnet: magnet = 8
        }
    }
    private mutating func impact(events: inout [Event]) {
        invulnerability = 1.5; combo = 1; comboTime = 0; weaveStreak = 0; nitro = max(0, nitro - 15)
        if shield { shield = false; events.append(.shieldBreak) }
        else {
            let damage = min(health, speedKPH > Self.dangerousSpeedKPH ? 2 : 1)
            health -= damage; events.append(.hit(damage))
            if health <= 0 {
                phase = .over; crashAge = 0; isBoosting = false; isDrifting = false; isBraking = false
                events.append(.crashed)
            }
        }
    }
    private mutating func random() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(UInt64.max >> 11)
    }
    private mutating func recordPass(side: Int, events: inout [Event]) {
        combo = min(combo + 1, 12); comboTime = Self.comboGrace
        let switched = side != 0 && side != lastPassSide && elapsed - lastPassAt < Self.comboGrace
            && abs(playerX - lastWeaveX) > 0.24
        if switched {
            weaveStreak += 1; bestWeave = max(bestWeave, weaveStreak)
            let award = (150 + min(weaveStreak, 10) * 40) * combo
            points += Double(award); nitro = min(100, nitro + 11)
            events.append(.weave(award, weaveStreak))
        } else {
            let award = 75 * combo
            points += Double(award); nitro = min(100, nitro + 4)
            events.append(.nearMiss(award))
        }
        lastPassAt = elapsed; lastPassSide = side; lastWeaveX = playerX
    }

    private mutating func updateTraffic(by step: Double) {
        let snapshot = traffic
        let brakeDelta = 18 * step
        let speedPerMetre = 3.6 / step
        for i in traffic.indices {
            let car = snapshot[i]
            let currentSpeed = car.effectiveSpeedKPH
            // Slow speed variation belongs to the driver, never the renderer.
            // Followers respond smoothly to the leader's actual speed.
            let variation = sin(elapsed * 0.55 + Double(car.id) * 1.7) * (car.driver == .calm ? 2 : 5)
            var desiredSpeed = car.speedKPH + variation
            var safeSpeed = Double.infinity
            for other in snapshot where other.id != car.id {
                let ahead = other.z - car.z
                guard ahead > 0, ahead < 95 else { continue }
                let inLane = abs(other.x - car.x) < 0.28
                guard inLane || abs((other.targetX ?? other.x) - car.x) < 0.28 else { continue }
                let headway = car.truck ? 30.0 : (car.driver == .brisk ? 22 : 27)
                let closing = max(0, (currentSpeed - other.effectiveSpeedKPH) / 3.6)
                let followingSpeed = other.effectiveSpeedKPH + (ahead - closing - headway) * 1.3
                desiredSpeed = min(desiredSpeed, max(55, followingSpeed))
                if inLane {
                    // Emergency braking leaves room for the two bodies even
                    // when a much slower leader cuts into a short gap.
                    let availableGap = max(0, ahead - car.collisionLength - other.collisionLength - 1)
                    let limit = other.effectiveSpeedKPH - brakeDelta + availableGap * speedPerMetre
                    safeSpeed = min(safeSpeed, limit)
                }
            }
            let change = Self.clamp(desiredSpeed - currentSpeed, -brakeDelta, (car.truck ? 5 : 10) * step)
            let speed = min(currentSpeed + change, safeSpeed)
            traffic[i].currentSpeedKPH = speed
            traffic[i].braking = min(desiredSpeed, safeSpeed) < currentSpeed - 2
            traffic[i].laneChangeCooldown = max(0, car.laneChangeCooldown - step)
            traffic[i].z -= (speedKPH - speed) / 3.6 * step
            if let target = car.targetX {
                if car.signalTime > 0 {
                    let duration = car.signalTime + 0.5 / car.laneChangeRate
                    let canFinish = car.yieldingToPlayer || canMergeAhead(of: car, after: duration)
                    let signalEnds = car.signalTime <= step
                    if !canFinish || !isLaneClear(target, beside: car, after: duration)
                        || (signalEnds && !leavesPassingLane(at: target, beside: car, after: duration)) {
                        traffic[i].targetX = nil
                        traffic[i].signalTime = 0
                        traffic[i].yieldingToPlayer = false
                        traffic[i].laneChangeCooldown = 1.25
                    } else { traffic[i].signalTime = max(0, car.signalTime - step) }
                } else {
                    traffic[i].x += Self.clamp(target - car.x, -step * car.laneChangeRate, step * car.laneChangeRate)
                    if abs(traffic[i].x - target) < 0.005 {
                        traffic[i].x = target
                        traffic[i].targetX = nil
                        traffic[i].yieldingToPlayer = false
                        let cooldown = car.driver == .brisk ? 3.0 : 5.0
                        traffic[i].laneChangeCooldown = cooldown * (1 - 0.52 * intensity)
                        laneChangeCount += 1
                    }
                }
            }
        }
        maneuverIn -= step
        if maneuverIn <= 0 {
            planLaneChange()
            maneuverIn = (0.55 + random() * 0.35) * (1 - 0.62 * intensity)
        }
    }

    private mutating func planLaneChange() {
        let order = traffic.indices.filter {
            !traffic[$0].isChangingLane && traffic[$0].laneChangeCooldown <= 0
                && traffic[$0].z > 65 && traffic[$0].z < 320
        }.sorted { traffic[$0].braking && !traffic[$1].braking }
        for i in order {
            let car = traffic[i]
            let signal = car.driver == .brisk ? 0.78 : 0.98
            let duration = signal + 0.5 / car.laneChangeRate
            guard canMergeAhead(of: car, after: duration) else { continue }
            let heldUp = hasSlowerLeader(aheadOf: car, inLane: car.x)
            // Use the left lane to pass. If the road opens up, move back
            // toward the right instead of weaving for its own sake.
            let directions: [Double] = heldUp ? [-1, 1] : [1]
            guard heldUp || random() < 0.16 + 0.40 * intensity else { continue }
            for direction in directions {
                let target = car.x + direction * 0.5
                guard abs(target) < 0.85, !hasSlowerLeader(aheadOf: car, inLane: target),
                      isLaneClear(target, beside: car, after: duration),
                      leavesPassingLane(at: target, beside: car, after: duration) else { continue }
                traffic[i].targetX = target
                traffic[i].signalTime = signal
                traffic[i].signalStartedAt = elapsed
                return
            }
        }
    }

    private func hasSlowerLeader(aheadOf car: Traffic, inLane lane: Double) -> Bool {
        traffic.contains { other in
            let gap = other.z - car.z
            return gap > 0 && gap < 75 && other.effectiveSpeedKPH < car.speedKPH - 9
                && (abs(other.x - lane) < 0.28 || abs((other.targetX ?? other.x) - lane) < 0.28)
        }
    }

    private func canMergeAhead(of car: Traffic, after duration: Double) -> Bool {
        car.z - max(0, closingSpeed(for: car)) * duration > 34
    }

    private func isLaneClear(_ target: Double, beside car: Traffic, after duration: Double) -> Bool {
        if abs(target - playerX) < car.halfWidth + Self.playerHalfWidth + 0.12,
           car.z - max(0, closingSpeed(for: car)) * duration < 22 { return false }
        return !traffic.contains { other in
            guard other.id != car.id,
                  abs(other.x - target) < 0.28 || abs((other.targetX ?? other.x) - target) < 0.28 else { return false }
            let gap = other.z - car.z
            let futureGap = gap + (other.effectiveSpeedKPH - car.effectiveSpeedKPH) / 3.6 * duration
            let clearance = car.truck || other.truck ? 30.0 : 24.0
            return abs(gap) < clearance || abs(futureGap) < clearance - 2 || gap * futureGap <= 0
        }
    }

    /// Check the road when the maneuver begins and when the player is likely
    /// to reach this group. A lane change must not close the last opening.
    private func leavesPassingLane(at target: Double, beside car: Traffic, after duration: Double) -> Bool {
        let closing = max(0, closingSpeed(for: car))
        let window = max(23, min(50, closing * 0.55))
        let arrival = Self.clamp(car.z / max(25, closing), duration, max(duration, 3.2))
        for time in [duration, arrival] {
            var occupied = laneMask(at: target)
            for other in traffic where other.id != car.id {
                let gap = other.z - car.z + (other.effectiveSpeedKPH - car.effectiveSpeedKPH) / 3.6 * time
                guard abs(gap) < window else { continue }
                occupied |= laneMask(at: predictedX(of: other, after: time))
                if let target = other.targetX { occupied |= laneMask(at: target) }
                if occupied == 0b1111 { return false }
            }
        }
        return true
    }

    private func laneMask(at x: Double) -> Int {
        var mask = 0
        for (index, center) in Self.lanes.enumerated() where abs(center - x) < 0.27 {
            mask |= 1 << index
        }
        return mask
    }

    private mutating func spawnWave() {
        guard traffic.count < 36 else { return }
        let pace = intensity
        let lead = 218 + 50 * pace + min(32, max(0, speedKPH - 220) * 0.15)
        let direction = random() < 0.5 ? -1 : 1
        let neighboringLanes = [safeLane + direction, safeLane - direction, safeLane]
        let openLane = neighboringLanes.first { lane in
            Self.lanes.indices.contains(lane) && !traffic.contains { car in
                abs(car.z - lead) < 42
                    && (laneMask(at: car.x) | laneMask(at: car.targetX ?? car.x)) & (1 << lane) != 0
            }
        }
        if let openLane { safeLane = openLane }
        let roll = random()
        let trioChance = 0.78 * Self.clamp((pace - 0.21) / 0.55, 0, 1)
        var desiredCount = 1
        if roll < 0.80 + 0.19 * pace { desiredCount = 2 }
        if roll < trioChance { desiredCount = 3 }
        var available = Array(0 ..< 4).filter { $0 != safeLane }
        for index in 0 ..< desiredCount {
            guard traffic.count < 36 else { break }
            let z = lead + Double(index) * (29 - 5 * pace) + random() * (10 + 14 * pace)
            let truck = random() < 0.12
            let personality = random()
            let driver: Traffic.Driver = truck || personality < 0.25 ? .calm
                : (personality > 0.68 - 0.19 * pace ? .brisk : .commuter)
            let cruise: Double
            switch driver {
            case .calm: cruise = (truck ? 82 : 92) + 29 * pace
            case .commuter: cruise = 110 + 42 * pace
            case .brisk: cruise = 139 + 56 * pace
            }
            let speed = cruise + (random() - 0.5) * 14
            let tint = Int(random() * 7)
            let cooldown = 0.75 + random() * 2
            let candidates = available.compactMap { lane -> (Int, Traffic)? in
                let car = Traffic(id: nextID, x: Self.lanes[lane], z: z, tint: tint, truck: truck,
                                  speedKPH: speed, driver: driver, laneChangeCooldown: cooldown)
                guard isLaneClear(car.x, beside: car, after: 1.25),
                      leavesPassingLane(at: car.x, beside: car, after: 0) else { return nil }
                return (lane, car)
            }
            guard !candidates.isEmpty else { continue }
            let laneRoll = random()
            let randomIndex = min(candidates.count - 1, Int(laneRoll * Double(candidates.count)))
            let preferred = driver == .calm ? candidates.count - 1 : 0
            let (lane, car) = candidates[laneRoll < 0.6 && driver != .commuter ? preferred : randomIndex]
            available.removeAll { $0 == lane }
            traffic.append(car)
            nextID += 1
        }
        guard let openLane, loot.count < 62 else { return }
        for offset in [0.0, 5] {
            loot.append(Loot(id: nextID, x: Self.lanes[openLane], z: lead - 5 + offset, kind: .coin)); nextID += 1
        }
        if random() < 0.45 {
            let roll = random()
            let kind: DriftPickup = roll < 0.40 ? .nitro : roll < 0.60 ? .magnet : roll < 0.85 ? .shield : .repair
            loot.append(Loot(id: nextID, x: Self.lanes[openLane], z: lead - 14, kind: kind)); nextID += 1
        }
    }
    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    mutating func stagePreview(over: Bool = false, boosting: Bool = true, highBeam: Bool = false,
                               outsideLane: Bool = false) {
        phase = .running; distance = 1_485; elapsed = 25; points = 6_850; coins = 17
        speedKPH = boosting ? 414 : cruiseSpeedKPH + 45
        playerX = -0.18; lateralVelocity = -1.0; isDrifting = true; driftTime = 12.7
        isBoosting = boosting; exhaustRemaining = 0.32; nitro = 64; combo = 7; comboTime = 3; shield = false; weaveStreak = 4; bestWeave = 4; overtakes = 28
        if highBeam { highBeamRemaining = 0.42 }
        if outsideLane {
            playerX = Self.lanes[0]
            lateralVelocity = 0
            isDrifting = false
        }
        traffic = [Traffic(id: 0, x: -0.75, z: 14, tint: 1, speedKPH: 87),
                   Traffic(id: 1, x: 0.25, z: 22, tint: 2, speedKPH: 134, driver: .brisk),
                   Traffic(id: 2, x: 0.75, z: 37, tint: 0, truck: true, speedKPH: 76),
                   Traffic(id: 3, x: -0.25, z: 56, tint: 3, speedKPH: 130, targetX: 0.25, signalTime: 0.5,
                           signalStartedAt: 24.9, driver: .brisk),
                   Traffic(id: 4, x: -0.75, z: 76, tint: 4, speedKPH: 112),
                   Traffic(id: 5, x: 0.75, z: 84, tint: 1, speedKPH: 91, braking: true),
                   Traffic(id: 6, x: -0.25, z: 114, tint: 2, speedKPH: 100),
                   Traffic(id: 7, x: 0.25, z: 132, tint: 0, truck: true, speedKPH: 80),
                   Traffic(id: 13, x: 0.75, z: 148, tint: 5, speedKPH: 116),
                   Traffic(id: 14, x: 0.25, z: 163, tint: 6, speedKPH: 141, driver: .brisk),
                   Traffic(id: 15, x: -0.25, z: 189, tint: 5, truck: true, speedKPH: 90),
                   Traffic(id: 16, x: 0.75, z: 221, tint: 0, speedKPH: 105)]
        loot = [Loot(id: 10, x: -0.25, z: 12, kind: .coin), Loot(id: 11, x: -0.25, z: 20, kind: .coin),
                Loot(id: 12, x: 0.25, z: 48, kind: .nitro)]
        if over { phase = .over; health = 0; crashAge = 2; shield = false; isBoosting = false; isDrifting = false; exhaustRemaining = 0 }
    }
}
