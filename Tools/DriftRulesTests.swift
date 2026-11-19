import Foundation

@main
enum DriftRulesTests {
    static func main() {
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            print("[\(condition ? "PASS" : "FAIL")] \(label)")
            if !condition { failures += 1 }
        }
        @discardableResult
        func step(_ rules: inout DriftRules, seconds: Double, input: DriftRules.Input = .init()) -> [DriftRules.Event] {
            var events: [DriftRules.Event] = []
            for _ in 0 ..< Int(seconds * 120) { events += rules.advance(by: 1.0 / 120, input: input) }
            return events
        }
        var ready = DriftRules(seed: 42)
        step(&ready, seconds: 1)
        check("a new race waits without advancing", ready.phase == .ready && ready.distance == 0)
        let rollingSpeed = ready.speedKPH
        ready.start(); step(&ready, seconds: 0.5)
        check("the rolling start builds speed without a jump", ready.phase == .running && ready.distance > 15
            && ready.speedKPH > rollingSpeed && ready.speedKPH < ready.cruiseSpeedKPH)
        let before = ready
        ready.pause(); step(&ready, seconds: 1, input: .init(steer: 1, drift: true, nitro: true))
        check("pause freezes speed, traffic, steering, score and nitro", ready.speedKPH == before.speedKPH && ready.distance == before.distance && ready.playerX == before.playerX && ready.traffic.map(\.z) == before.traffic.map(\.z) && ready.score == before.score && ready.nitro == before.nitro)
        ready.start(); check("resuming preserves the current run", ready.phase == .running && ready.distance == before.distance)

        var steer = DriftRules(seed: 1, traffic: [], loot: [])
        steer.start(); step(&steer, seconds: 0.5, input: .init(steer: -1))
        check("held steering moves the car left", steer.playerX < 0)
        let moving = abs(steer.lateralVelocity)
        step(&steer, seconds: 0.5)
        check("released steering settles instead of getting stuck", abs(steer.lateralVelocity) < moving * 0.05)
        var normal = DriftRules(seed: 1, traffic: [], loot: [])
        var drifting = normal
        normal.start(); drifting.start()
        step(&normal, seconds: 0.6, input: .init(steer: -1))
        step(&drifting, seconds: 0.6, input: .init(steer: -1, drift: true))
        check("handbrake produces stronger lateral sliding", abs(drifting.lateralVelocity) > abs(normal.lateralVelocity))
        check("empty-road drifting cannot farm bonus points or nitro", drifting.driftTime > 0 && abs(drifting.points - drifting.distance * 0.35) < 0.01 && drifting.nitro <= normal.nitro + 0.01)
        var mouse = DriftRules(seed: 1, traffic: [], loot: [])
        mouse.start(); step(&mouse, seconds: 1, input: .init(targetX: -0.25))
        check("mouse steering converges toward its road target", abs(mouse.playerX + 0.25) < 0.1)
        var boost = DriftRules(seed: 1, traffic: [], loot: [])
        boost.start(); let baseSpeed = boost.speedKPH
        var gas = boost
        step(&gas, seconds: 0.1, input: .init(throttle: true))
        check("the gas pedal builds speed without consuming nitro",
              gas.speedKPH > baseSpeed && gas.speedKPH < baseSpeed + 5 && gas.nitro >= boost.nitro && !gas.isBoosting)
        let firstBoost = step(&boost, seconds: 0.1, input: .init(nitro: true))
        check("nitro pulls much harder than the gas pedal",
              boost.speedKPH - baseSpeed > 4 * (gas.speedKPH - baseSpeed) && boost.nitro < gas.nitro)
        let boostEvents = firstBoost + step(&boost, seconds: 1.4, input: .init(nitro: true))
        check("holding nitro keeps building speed and quickly spends fuel", boost.nitro < 25 && boost.speedKPH > baseSpeed + 145)
        check("holding nitro emits one activation sound", boostEvents.filter { if case .boost = $0 { return true }; return false }.count == 1)
        let fuel = boost.nitro, boostedSpeed = boost.speedKPH
        step(&boost, seconds: 0.5)
        check("releasing nitro coasts down and does not refill it immediately",
              boost.nitro == fuel && !boost.isBoosting && boost.speedKPH < boostedSpeed && boost.speedKPH > boost.cruiseSpeedKPH)
        step(&boost, seconds: 1)
        check("nitro recovers after a continuous break", boost.nitro > fuel)
        step(&boost, seconds: 4, input: .init(nitro: true))
        check("holding an empty tank cannot refill or retrigger nitro", boost.nitro == 0 && !boost.isBoosting)
        step(&boost, seconds: 1)
        check("holding nitro on empty does not count toward the refill delay", boost.nitro == 0)
        let exhaustedEvents = step(&boost, seconds: 0.2, input: .init(nitro: true))
        check("tapping nitro with too little charge does not boost", !boost.isBoosting && exhaustedEvents.allSatisfy { if case .boost = $0 { return false }; return true })
        boost.pause()
        check("pausing clears transient boost and drift flags", !boost.isBoosting && !boost.isDrifting)

        let collision = DriftRules.Traffic(id: 1, x: 0.25, z: 0, tint: 0)
        var hit = DriftRules(seed: 1, traffic: [collision], loot: [])
        hit.start(); let hits = step(&hit, seconds: 0.1)
        check("traffic collision costs one health", hit.health == 2 && hits.contains { if case .hit = $0 { return true }; return false })
        step(&hit, seconds: 0.1)
        check("impact immunity prevents repeated damage from one car", hit.health == 2)
        var hardImpact = DriftRules(seed: 1)
        hardImpact.stagePreview()
        let hardHits = step(&hardImpact, seconds: 1, input: .init(steer: -1, throttle: true))
        check("an impact above 350 km/h takes two hearts even after releasing nitro",
              !hardImpact.isBoosting && hardImpact.health == 1
              && hardHits.contains { if case .hit(2) = $0 { return true }; return false })
        check("overtaken models continue moving toward the bottom instead of freezing at Z zero",
              DriftProjection.depth(-3) > DriftProjection.depth(0))
        let curve = 0.65
        let pointerLinesUp = DriftRules.lanes.allSatisfy { lane in
            let pixel = DriftProjection.position(lane: lane, depth: DriftProjection.playerDepth, curve: curve)
            return abs(DriftProjection.playerLane(at: pixel.x, curve: curve) - lane) < 0.0001
        }
        check("mouse targets line up with all four lane centres on a bend", pointerLinesUp)
        let leftHeading = DriftProjection.playerHeading(lane: -0.75, curve: 0, lateralVelocity: 0, drifting: false)
        let rightHeading = DriftProjection.playerHeading(lane: 0.75, curve: 0, lateralVelocity: 0, drifting: false)
        check("both outer lanes point toward the road in perspective",
              leftHeading > 0 && rightHeading < 0 && abs(leftHeading + rightHeading) < 0.0001)
        let crossing = DriftProjection.playerHeading(lane: -0.75, curve: 0, lateralVelocity: -1, drifting: true)
        check("steering changes the heading relative to the lane", crossing < leftHeading)
        for truck in [false, true] {
            let exit = DriftProjection.exitZ(truck: truck)
            let visible = DriftRules.Traffic(id: 1, x: 0.25, z: exit + 0.01, tint: 0, truck: truck)
            let gone = DriftRules.Traffic(id: 1, x: 0.25, z: exit - 0.01, tint: 0, truck: truck, speedKPH: 300)
            check("the full \(truck ? "truck" : "car") model and collider share their exit boundary", visible.isVisible && !gone.isVisible)
            var ghost = DriftRules(seed: 1, traffic: [gone], loot: [])
            ghost.start(); let events = step(&ghost, seconds: 0.5, input: .init(brake: true))
            check("an off-screen \(truck ? "truck" : "car") cannot reappear or hit after braking",
                  ghost.traffic.isEmpty && ghost.health == 3 && events.isEmpty)
            let farEdge = DriftProjection.horizonY + DriftProjection.depth(exit) * (DriftProjection.roadHeight - (truck ? 98 : 60))
            check("the \(truck ? "truck" : "car") clears the canvas before removal", abs(farEdge - DriftRules.height) < 0.001)
        }
        var passed = DriftRules(seed: 1, traffic: [.init(id: 1, x: -0.05, z: 1, tint: 0)], loot: [])
        passed.start(); let passes = step(&passed, seconds: 1)
        check("despawning awards the clean pass once and removes the same model",
              passed.traffic.isEmpty && passed.overtakes == 1 && passes.filter { if case .nearMiss = $0 { return true }; return false }.count == 1)
        let shield = DriftRules.Loot(id: 2, x: 0.25, z: 0, kind: .shield)
        var shielded = DriftRules(seed: 1, traffic: [collision], loot: [shield])
        shielded.start(); let shieldEvents = step(&shielded, seconds: 0.05)
        check("a just-collected shield absorbs the collision", shielded.health == 3 && !shielded.shield && shieldEvents.contains { if case .shieldBreak = $0 { return true }; return false })
        var edge = DriftRules(seed: 1, traffic: [], loot: [])
        edge.start(); let edgeEvents = step(&edge, seconds: 7, input: .init(steer: 1))
        check("repeated barrier impacts end the race after three hits", edge.phase == .over && edge.health == 0)
        check("a fatal crash is emitted exactly once", edgeEvents.filter { if case .crashed = $0 { return true }; return false }.count == 1)
        let crashedDistance = edge.distance
        step(&edge, seconds: 0.5)
        check("a finished race does not keep scoring", edge.distance == crashedDistance && edge.crashAge > 0)
        check("the vehicle remains within bounded road coordinates", abs(edge.playerX) <= 1.18 && abs(edge.lateralVelocity) <= 2.1)
        var shoulder = DriftRules(seed: 42, traffic: [], loot: [])
        shoulder.start()
        step(&shoulder, seconds: 8, input: .init(throttle: true, targetX: 1.03))
        check("riding the shoulder cannot bypass traffic indefinitely", shoulder.phase == .over)
        var near = DriftRules(seed: 1, traffic: [.init(id: 1, x: -0.05, z: 1, tint: 0)], loot: [])
        near.start(); let nearEvents = step(&near, seconds: 0.9)
        check("a close clean overtake raises the combo", near.combo == 2 && near.health == 3 && nearEvents.contains { if case .nearMiss = $0 { return true }; return false })
        let count = nearEvents.count; let again = step(&near, seconds: 0.1)
        check("one traffic car awards at most one near miss", count == 1 && !again.contains { if case .nearMiss = $0 { return true }; return false })

        var coin = DriftRules(seed: 1, traffic: [], loot: [.init(id: 1, x: 0.25, z: 0, kind: .coin)])
        coin.start(); step(&coin, seconds: 0.1)
        check("a coin is collected once and disappears", coin.coins == 1 && coin.loot.isEmpty && coin.score >= 25)
        step(&coin, seconds: 0.1); check("collected coins cannot be counted twice", coin.coins == 1)
        var quick = DriftRules(seed: 1, traffic: [], loot: [])
        quick.start(); step(&quick, seconds: 0.12, input: .init(steer: -1))
        check("short steering presses react promptly", quick.lateralVelocity < -1.3)
        let releasedX = quick.playerX
        step(&quick, seconds: 0.3)
        check("releasing steering stops within a small fraction of a lane", abs(quick.playerX - releasedX) < 0.12)
        var thread = DriftRules(seed: 1, traffic: [.init(id: 1, x: 0.43, z: 1, tint: 0)], loot: [])
        thread.start(); step(&thread, seconds: 0.5)
        check("a narrow clean gap no longer registers a false side impact", thread.health == 3)
        check("weaving allows a longer interval between clean passes", DriftRules.comboGrace > 4)

        var magnet = DriftRules(seed: 1, traffic: [], loot: [.init(id: 1, x: 0.25, z: 0, kind: .magnet), .init(id: 2, x: -0.25, z: 1, kind: .coin)])
        magnet.start(); step(&magnet, seconds: 0.2)
        check("the magnet collects a coin in a neighboring lane", magnet.coins == 1 && magnet.magnet > 7)
        let nitroLoot = DriftRules.Loot(id: 1, x: 0.25, z: 0, kind: .nitro)
        var tank = DriftRules(seed: 1, traffic: [], loot: [nitroLoot])
        tank.start(); step(&tank, seconds: 0.1)
        check("a nitro pickup caps the tank at 100", tank.nitro == 100)
        var fullRepair = DriftRules(seed: 1, traffic: [], loot: [.init(id: 1, x: 0.25, z: 0, kind: .repair)])
        fullRepair.start(); step(&fullRepair, seconds: 0.1)
        check("repair never exceeds three health", fullRepair.health == 3)
        var rain = DriftRules(track: .rain, seed: 1, traffic: [], loot: [])
        var dry = DriftRules(track: .city, seed: 1, traffic: [], loot: [])
        rain.start(); dry.start()
        step(&rain, seconds: 0.4, input: .init(steer: 1)); step(&dry, seconds: 0.4, input: .init(steer: 1))
        check("wet asphalt has a distinct, more slippery handling model", rain.lateralVelocity > dry.lateralVelocity)

        var preview = DriftRules(seed: 42); preview.stagePreview()
        check("the staged race shows a later pace and level", preview.level == 3 && preview.speedKPH > preview.cruiseSpeedKPH)
        var invalid = DriftRules(seed: 1); invalid.start(); let originalX = invalid.playerX
        check("invalid time does not mutate the world", invalid.advance(by: .nan).isEmpty && invalid.advance(by: -1).isEmpty && invalid.distance == 0)
        step(&invalid, seconds: 0.1, input: .init(steer: .infinity, targetX: .nan))
        check("invalid controls cannot corrupt the vehicle position", invalid.playerX.isFinite && invalid.playerX == originalX)
        var deterministicA = DriftRules(seed: 77), deterministicB = DriftRules(seed: 77)
        deterministicA.start(); deterministicB.start()
        step(&deterministicA, seconds: 4); step(&deterministicB, seconds: 4)
        check("seeded traffic generation is reproducible", deterministicA.traffic.map(\.x) == deterministicB.traffic.map(\.x) && deterministicA.loot.map(\.kind) == deterministicB.loot.map(\.kind))

        var bounded = true, survived = true
        var lateFinishes = 0
        var reachedFinish = false
        var earlyTraffic = 0, lateTraffic = 0, earlyChanges = 0, lateChanges = 0, trafficSamples = 0
        for track in DriftTrack.allCases {
            for seed in [42, 8, 99] as [UInt64] {
                var drive = DriftRules(track: track, seed: seed); drive.start()
                var pilot = DriftTrafficDriver()
                var changesAt15 = 0, changesAt125 = 0
                for frame in 1 ... 150 * 60 {
                    let controls = pilot.input(for: drive, delta: 1.0 / 60)
                    _ = drive.advance(by: 1.0 / 60, input: controls)
                    bounded = bounded && drive.traffic.count <= 45 && drive.loot.count <= 65 && drive.nitro <= 100 && drive.health <= 3
                    guard frame % 60 == 0 else { continue }
                    let second = frame / 60
                    if second == 15 { changesAt15 = drive.laneChangeCount }
                    if (16 ... 40).contains(second) {
                        earlyTraffic += drive.traffic.count
                        trafficSamples += 1
                    }
                    if second == 40 { earlyChanges += drive.laneChangeCount - changesAt15 }
                    if second == 60 {
                        survived = survived && drive.phase == .running && drive.distance > 2100 && drive.level >= 4 && drive.health == 3
                    }
                    if second == 125 { changesAt125 = drive.laneChangeCount }
                    if (126 ... 150).contains(second) { lateTraffic += drive.traffic.count }
                }
                lateChanges += drive.laneChangeCount - changesAt125
                if drive.phase == .running { lateFinishes += 1 }
                print("Course: \(track), seed \(seed), distance \(Int(drive.distance)), health \(drive.health), level \(drive.level)")
                if track == .sunset && seed == 42 {
                    for _ in 0 ..< 270 * 60 where drive.phase == .running {
                        let delta = 1.0 / 60
                        let input = pilot.input(for: drive, delta: delta)
                        _ = drive.advance(by: delta, input: input)
                    }
                    let finishScore = drive.score
                    _ = drive.advance(by: 0.1, input: .init(throttle: true))
                    reachedFinish = drive.phase == .finished && drive.distance == DriftRules.finishDistance
                        && drive.score == finishScore && drive.health > 0
                }
            }
        }
        check("traffic, loot and resource values stay bounded during long runs", bounded)
        check("all tracks permit a clean one-minute run at the lower street speeds", survived)
        check("the denser late traffic still permits runs past two minutes", lateFinishes >= 6)
        check("late traffic contains more vehicles and changes lanes more often", lateTraffic > earlyTraffic && lateChanges > earlyChanges)
        let earlyMean = Double(earlyTraffic) / Double(trafficSamples)
        let lateMean = Double(lateTraffic) / Double(trafficSamples)
        check("traffic starts with room to learn and averages at least 50% denser later",
              earlyMean >= 12 && lateMean >= 20 && lateMean >= earlyMean * 1.5)
        check("a clean run reaches the finish and stops scoring", reachedFinish)
        print("Early/late mean traffic: \(earlyMean) / \(lateMean), lane changes: \(earlyChanges) / \(lateChanges)")

        var fastRun = DriftRules(seed: 3)
        fastRun.start()
        var fastPilot = DriftTrafficDriver()
        var gasPeak = 0.0
        let frameTime = 1.0 / 60
        for _ in 0 ..< 20 * 60 where fastRun.phase == .running {
            let controls = fastPilot.input(for: fastRun, delta: frameTime, throttle: true)
            _ = fastRun.advance(by: frameTime, input: controls)
            gasPeak = max(gasPeak, fastRun.speedKPH)
        }
        check("gas alone accelerates past 350 km/h through traffic", gasPeak > 350 && fastRun.phase == .running)
        var boosting = false, nitroPeak = 0.0
        for _ in 0 ..< 70 * 60 where fastRun.phase == .running {
            if fastRun.speedKPH > 365 && fastRun.nitro >= 78 { boosting = true }
            if fastRun.nitro < 0.01 { boosting = false }
            let controls = fastPilot.input(for: fastRun, delta: frameTime, throttle: true, nitro: boosting)
            _ = fastRun.advance(by: frameTime, input: controls)
            nitroPeak = max(nitroPeak, fastRun.speedKPH)
        }
        check("nitro takes a running car past 440 km/h through traffic", nitroPeak > 440 && fastRun.phase == .running)
        print("Peak speeds through traffic: gas \(Int(gasPeak)) km/h, nitro \(Int(nitroPeak)) km/h")
        func accelerate(from initial: Double, for seconds: Int) -> Double {
            (0 ..< seconds * 120).reduce(initial) { speed, _ in
                DriftRules.nextSpeed(from: speed, cruise: 155, braking: false,
                                     throttle: true, boosting: false, step: 1.0 / 120)
            }
        }
        let through350 = accelerate(from: 350, for: 5)
        let after350 = accelerate(from: through350, for: 5)
        check("throttle pulls smoothly through 350 and gains speed more slowly as drag rises",
              through350 > 360 && after350 > through350 && after350 - through350 < through350 - 350)

        let opening = DriftRules(seed: 42)
        check("opening traffic leaves both middle lanes open", opening.traffic.filter { $0.z < 150 }.allSatisfy { abs($0.x) > 0.5 })
        check("the first wave keeps a calm pace and generous spacing", opening.cruiseSpeedKPH == 155 && opening.spawnInterval == 2.6)
        var gentle = DriftRules(seed: 42); gentle.start()
        step(&gentle, seconds: 10)
        check("a new player gets ten seconds without a forced opening collision", gentle.health == 3 && gentle.phase == .running)
        var openEarlyWaves = true
        for seed in 1 ... 10 {
            var flow = DriftRules(seed: UInt64(seed), traffic: [], loot: [])
            flow.start(); var seen = Set<Int>()
            for _ in 0 ..< 250 {
                _ = flow.advance(by: 0.1)
                let added = flow.traffic.filter { !seen.contains($0.id) }
                openEarlyWaves = openEarlyWaves && added.count <= 2
                seen.formUnion(flow.traffic.map(\.id))
                if flow.phase == .over { break }
            }
        }
        check("early traffic waves keep two lanes open", openEarlyWaves)

        var pops = DriftRules(seed: 42, traffic: [], loot: [])
        check("exhaust cannot fire outside a running race", !pops.popExhaust())
        pops.start(); let beforePop = pops
        check("manual exhaust creates a short flame and throttles repeats", pops.popExhaust() && pops.exhaustRemaining == 0.42 && !pops.popExhaust())
        check("cosmetic exhaust does not spend fuel, health or score", pops.nitro == beforePop.nitro && pops.health == beforePop.health && pops.score == beforePop.score)
        step(&pops, seconds: 0.5)
        check("exhaust flames expire instead of remaining on screen", pops.exhaustRemaining == 0 && pops.exhaustCooldown > 0)
        let exhaustCooldown = pops.exhaustCooldown
        pops.pause(); step(&pops, seconds: 2)
        check("paused exhaust is cleared and its cooldown freezes", pops.exhaustRemaining == 0 && pops.exhaustCooldown == exhaustCooldown && !pops.popExhaust())
        pops.start(); step(&pops, seconds: 0.7)
        check("exhaust can fire again after cooldown", pops.popExhaust())
        var lift = DriftRules(seed: 42, traffic: [], loot: []); lift.start()
        step(&lift, seconds: 0.3, input: .init(nitro: true))
        let liftEvents = step(&lift, seconds: 0.3)
        check("lifting off nitro automatically pops the exhaust once", liftEvents.filter { if case .backfire = $0 { return true }; return false }.count == 1 && lift.exhaustRemaining > 0)
        let steadyEvents = step(&lift, seconds: 2)
        check("steady cruising does not spam automatic exhaust sounds", steadyEvents.allSatisfy { if case .backfire = $0 { return false }; return true })

        var idlingEnds = true
        for seed in [1, 2, 3, 42, 99] as [UInt64] {
            var idle = DriftRules(seed: seed); idle.start()
            step(&idle, seconds: 65)
            idlingEnds = idlingEnds && idle.health < 3
        }
        check("the easier traffic still challenges an idle car", idlingEnds)
        var braking = DriftRules(seed: 1, traffic: [], loot: [])
        braking.start(); let cruiseSpeed = braking.speedKPH
        step(&braking, seconds: 0.2, input: .init(nitro: true, brake: true))
        check("braking overrides nitro and slows progressively", braking.isBraking && !braking.isBoosting
            && braking.speedKPH < cruiseSpeed && braking.speedKPH > braking.cruiseSpeedKPH * 0.62)
        braking.pause(); check("pause clears the brake state", !braking.isBraking)
        var variable = DriftRules(seed: 1, traffic: [
            .init(id: 1, x: -0.75, z: 100, tint: 1, speedKPH: 70),
            .init(id: 2, x: 0.75, z: 100, tint: 2, speedKPH: 130)], loot: [])
        variable.start(); step(&variable, seconds: 0.5)
        check("traffic vehicles move at individual speeds", variable.traffic[0].z < variable.traffic[1].z - 7)
        var queue = DriftRules(seed: 1, traffic: [
            .init(id: 1, x: -0.75, z: 100, tint: 1, speedKPH: 130),
            .init(id: 2, x: -0.75, z: 116, tint: 2, speedKPH: 70)], loot: [])
        queue.start(); step(&queue, seconds: 0.2)
        check("a faster NPC brakes behind slower traffic", queue.traffic[0].braking)

        let brakingSpeed = queue.traffic[0].effectiveSpeedKPH
        check("NPC braking changes speed smoothly instead of snapping", brakingSpeed >= 126.3 && brakingSpeed < 130)
        step(&queue, seconds: 1.5)
        check("a fast follower stays behind its leader even when it needs emergency braking",
              queue.traffic[1].z - queue.traffic[0].z > queue.traffic[0].collisionLength + queue.traffic[1].collisionLength)
        var unsignalled = DriftRules(seed: 42, traffic: [.init(id: 1, x: 0.25, z: 45, tint: 0, driver: .brisk)], loot: [])
        unsignalled.start(); step(&unsignalled, seconds: 1.5)
        check("close traffic never initiates a surprise lane change", unsignalled.traffic.allSatisfy { $0.targetX == nil })
        var closingGap = DriftRules(seed: 42, traffic: [
            .init(id: 1, x: 0.25, z: 100, tint: 0, targetX: -0.25, signalTime: 1),
            .init(id: 2, x: -0.25, z: 50, tint: 1, speedKPH: 200)], loot: [])
        closingGap.start(); step(&closingGap, seconds: 0.1)
        check("a driver cancels its signal if a fast car closes the reserved gap", closingGap.traffic[0].targetX == nil && closingGap.traffic[0].x == 0.25)
        var passingTraffic = DriftRules(seed: 42, traffic: [
            .init(id: 1, x: 0.75, z: 178, tint: 0, speedKPH: 145, driver: .brisk),
            .init(id: 2, x: 0.75, z: 222, tint: 1, truck: true, speedKPH: 85)], loot: [])
        passingTraffic.start(); step(&passingTraffic, seconds: 6)
        check("a faster NPC stuck behind a truck signals and completes a pass to its left",
              passingTraffic.traffic.first { $0.id == 1 }?.x == 0.25 && passingTraffic.laneChangeCount > 0)

        var slalom = DriftRules(seed: 42, traffic: [
            .init(id: 1, x: -0.05, z: 1, tint: 0),
            .init(id: 2, x: -0.25, z: 35, tint: 1)], loot: [])
        slalom.start(); step(&slalom, seconds: 0.9)
        let weaveEvents = step(&slalom, seconds: 2.1, input: .init(targetX: -0.55))
        check("alternating close overtakes awards a weaving series", slalom.weaveStreak == 1 && slalom.bestWeave == 1 && weaveEvents.contains { if case .weave = $0 { return true }; return false })
        var contact = DriftRules(seed: 42, traffic: [collision], loot: [])
        contact.start(); let contactEvents = step(&contact, seconds: 0.5, input: .init(targetX: -0.5))
        check("a collision cannot be scored as a close clean pass", !contactEvents.contains { if case .nearMiss = $0 { return true }; if case .weave = $0 { return true }; return false })

        var lamps = DriftRules(seed: 42, traffic: [.init(id: 1, x: 0.25, z: 70, tint: 0)], loot: [])
        check("headlights cannot move traffic before a race", lamps.flashHeadlights() == .unavailable)
        lamps.start()
        check("flashing makes the nearest car ahead yield into a clear neighboring lane", lamps.flashHeadlights() == .yielded && lamps.traffic[0].targetX == 0.75)
        check("flashing has visible feedback and a cooldown", lamps.highBeamRemaining > 0 && lamps.highBeamCooldown == 4 && lamps.flashHeadlights() == .unavailable)
        let lampX = lamps.traffic[0].x
        step(&lamps, seconds: 0.2)
        check("a yielding NPC signals before moving rather than teleporting", lamps.traffic[0].x == lampX && lamps.traffic[0].signalTime > 0)
        step(&lamps, seconds: 0.4)
        check("a yielding car then moves continuously into the neighboring lane", lamps.traffic[0].x > lampX && lamps.traffic[0].x < 0.75)
        let cooldown = lamps.highBeamCooldown
        lamps.pause(); step(&lamps, seconds: 2)
        check("headlight cooldown freezes on pause", lamps.highBeamCooldown == cooldown)
        lamps.start(); step(&lamps, seconds: 4)
        check("headlights become available again after the cooldown", lamps.highBeamCooldown == 0 && lamps.flashHeadlights() != .unavailable)
        var blocked = DriftRules(seed: 1, traffic: [
            .init(id: 1, x: 0.25, z: 80, tint: 0), .init(id: 2, x: -0.25, z: 82, tint: 1),
            .init(id: 3, x: 0.75, z: 75, tint: 2)], loot: [])
        blocked.start()
        check("headlights do not force an NPC into occupied lanes", blocked.flashHeadlights() == .blocked && blocked.traffic.allSatisfy { $0.targetX == nil })
        var lastOpening = DriftRules(seed: 42, traffic: [
            .init(id: 1, x: 0.25, z: 70, tint: 0),
            .init(id: 2, x: -0.25, z: 70, tint: 1),
            .init(id: 3, x: -0.75, z: 70, tint: 2),
            .init(id: 4, x: 0.25, z: 90, tint: 3),
        ], loot: [])
        lastOpening.start()
        check("a headlight yield cannot close the last passing lane",
              lastOpening.flashHeadlights() == .blocked && lastOpening.traffic.allSatisfy { $0.targetX == nil })
        var leftYield = DriftRules(seed: 1, traffic: [
            .init(id: 1, x: 0.25, z: 80, tint: 0), .init(id: 2, x: 0.75, z: 82, tint: 1)], loot: [])
        leftYield.start()
        check("an NPC can yield left when the right lane is blocked", leftYield.flashHeadlights() == .yielded && leftYield.traffic[0].targetX == -0.25)
        var behind = DriftRules(seed: 1, traffic: [.init(id: 1, x: 0.25, z: -20, tint: 0)], loot: [])
        behind.start()
        check("flashing cannot affect cars behind the player", behind.flashHeadlights() == .flashed && behind.traffic[0].targetX == nil)
        var closest = DriftRules(seed: 1, traffic: [
            .init(id: 1, x: 0.25, z: 65, tint: 0), .init(id: 2, x: 0.25, z: 110, tint: 1)], loot: [])
        closest.start(); _ = closest.flashHeadlights()
        check("one flash affects the closest car rather than clearing the entire highway", closest.traffic[0].targetX != nil && closest.traffic[1].targetX == nil)
        check("tracks and cars have unique persistent identifiers", Set(DriftTrack.allCases.map(\.id)).count == 3 && Set(DriftCar.allCases.map(\.id)).count == 6)
        print(failures == 0 ? "All Hellcat street checks passed" : "Failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
