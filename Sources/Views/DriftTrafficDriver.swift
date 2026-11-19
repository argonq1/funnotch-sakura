import Foundation

/// A short-horizon driver used only for deterministic course validation and
/// rendering/performance probes. It has no access to future random spawns.
struct DriftTrafficDriver {
    private var planIn = 0.0
    private var controls = DriftRules.Input()

    mutating func input(for world: DriftRules, delta: Double, throttle: Bool = false, nitro: Bool = false) -> DriftRules.Input {
        planIn -= delta
        guard planIn <= 0 else { return controls }
        planIn = 0.09
        let goals = [-0.82, -0.65, -0.5, -0.35, -0.25, -0.12, 0, 0.12, 0.25, 0.35, 0.5, 0.65, 0.82, world.playerX]
        let cars = world.traffic.filter { $0.z > -12 && $0.z < 200 }
        var bestCost = Double.infinity
        for brake in [false, true] {
            // Forecast the same gradual braking and speed recovery as the
            // simulation before comparing possible steering paths.
            let interval = 0.09
            var speed = world.speedKPH
            var metres = 0.0
            let travel = (1 ... 30).map { _ in
                speed = DriftRules.nextSpeed(from: speed, cruise: world.cruiseSpeedKPH,
                                             braking: brake, throttle: throttle, boosting: nitro, step: interval)
                metres += speed / 3.6 * interval
                return metres
            }
            for goal in goals {
                var x = world.playerX, velocity = world.lateralVelocity
                var cost = abs(goal - x) * 2 + (brake ? 14.0 : 0)
                for i in 1 ... 30 {
                    let t = Double(i) * interval
                    for _ in 0 ..< 3 {
                        let steer = max(-1, min(1, (goal - x) * 5.5 - velocity * 0.85))
                        velocity += (steer * DriftRules.steeringAcceleration(drifting: false) - velocity * DriftRules.steeringDamping(track: world.track, drifting: false)) * 0.03
                        velocity = max(-2.1, min(2.1, velocity)); x += velocity * 0.03
                    }
                    if abs(x) > 1.02 { cost += 1_000 }
                    for car in cars {
                        let z = car.z + car.effectiveSpeedKPH / 3.6 * t - travel[i - 1]
                        guard abs(z) < (car.truck ? 11 : 9) else { continue }
                        let separation = abs(x - world.predictedX(of: car, after: t))
                        let clearance = separation - car.halfWidth - DriftRules.playerHalfWidth
                        if clearance < 0.015 { cost += 15_000 * (1 - t / 4) }
                        else { cost += exp(-clearance * 18) * 8 }
                    }
                }
                if cost < bestCost {
                    bestCost = cost
                    controls = DriftRules.Input(throttle: throttle, nitro: nitro, brake: brake, targetX: goal)
                }
            }
        }
        return controls
    }
}
