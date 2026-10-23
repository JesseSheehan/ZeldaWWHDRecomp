import RealityKit
import SwiftUI

/// Full Screen's sky through the day: it follows the game's own clock (the time of day in the save info,
/// wwhd_visionos_time_of_day), or the headset's local time before a game is loaded. Dawn, day, dusk and
/// night colour the sky dome, the sea, its waves and the clouds, and the sun rises and sets. About once a
/// second at most, and only when the time moved: a gradient picture and a few material tints.
@MainActor final class SkyClock {
    private let world: Entity
    private var shownHour: Float = -100
    private var shownParts = 0  // the world's entities when last coloured (the game's scenery arrives later)
    private var lastCheck = Date.distantPast

    init(world: Entity) { self.world = world }

    func update() {
        guard Date().timeIntervalSince(lastCheck) > 1 else { return }
        lastCheck = Date()
        let hour = Self.hourNow()
        let moved = abs(hour - shownHour)
        guard min(moved, 24 - moved) > 0.05 || world.children.count != shownParts else { return }  // about 3 game minutes
        shownHour = hour
        shownParts = world.children.count
        apply(Self.look(at: hour), hour: hour)
    }

    static func hourNow() -> Float {
        // test switch: WWHD_TEST_HOUR=6.5 shows that hour
        if let test = ProcessInfo.processInfo.environment["WWHD_TEST_HOUR"], let h = Float(test) { return h }
        let degrees = wwhd_visionos_time_of_day()
        if degrees >= 0 { return Float(degrees / 15).truncatingRemainder(dividingBy: 24) }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Float(c.hour ?? 12) + Float(c.minute ?? 0) / 60
    }

    struct Look {
        var zenith, horizon, sea, light: SIMD3<Float>
    }

    /// The colours at `hour`, between keyframes in the spirit of the game's palettes: deep blue night,
    /// orange dawn and dusk at the horizon, clear blue day.
    static func look(at hour: Float) -> Look {
        let night = Look(zenith: [0.03, 0.05, 0.16], horizon: [0.10, 0.14, 0.30], sea: [0.03, 0.09, 0.20], light: [0.35, 0.40, 0.60])
        let dawn = Look(zenith: [0.30, 0.40, 0.72], horizon: [1.00, 0.70, 0.50], sea: [0.12, 0.30, 0.50], light: [1.00, 0.82, 0.72])
        let day = Look(zenith: [0.25, 0.50, 0.92], horizon: [0.78, 0.89, 0.98], sea: [0.10, 0.45, 0.70], light: [1, 1, 1])
        let dusk = Look(zenith: [0.30, 0.30, 0.62], horizon: [1.00, 0.55, 0.30], sea: [0.15, 0.25, 0.45], light: [1.00, 0.78, 0.65])
        let keys: [(Float, Look)] = [(0, night), (4.5, night), (6, dawn), (8, day), (16, day), (18, dusk), (19.5, night), (24, night)]
        for k in 0..<keys.count - 1 where hour >= keys[k].0 && hour <= keys[k + 1].0 {
            let (h0, a) = keys[k], (h1, b) = keys[k + 1]
            let f = h1 > h0 ? (hour - h0) / (h1 - h0) : 0
            func mix(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> SIMD3<Float> { x + (y - x) * f }
            return Look(zenith: mix(a.zenith, b.zenith), horizon: mix(a.horizon, b.horizon), sea: mix(a.sea, b.sea), light: mix(a.light, b.light))
        }
        return day
    }

    private func apply(_ look: Look, hour: Float) {
        func color(_ c: SIMD3<Float>, _ alpha: CGFloat = 1) -> UIColor {
            UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
        }
        // sky dome
        if let sky = world.findEntity(named: "sky") as? ModelEntity,
           let texture = try? TextureResource(image: TheaterSpace.skyGradient(zenith: look.zenith, horizon: look.horizon), options: .init(semantic: .color)) {
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: .white, texture: .init(texture))
            sky.model?.materials = [m]
        }
        // the sea and its waves
        if let sea = world.findEntity(named: "sea") as? ModelEntity {
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: color(look.sea))
            sea.model?.materials = [m]
        }
        tint("gameWaves", color(look.light * [0.55, 0.85, 1], 0.75))
        tint("gameShimmer", color(look.light * [0.8, 0.95, 1], 0.35))
        // clouds take the light of the hour
        for name in ["gameClouds", "gameHorizon", "plainClouds"] { tint(name, color(look.light)) }
        // the sun on its arc: up at 6, highest at noon, down at 18
        let a = (hour - 6) / 12 * .pi
        for name in ["gameSun", "plainSun"] {
            guard let sun = world.findEntity(named: name) else { continue }
            let p = SIMD3<Float>(-cos(a) * 95, sin(a) * 95, -75)
            sun.isEnabled = p.y > -8 && (name == "plainSun" ? world.findEntity(named: "gameSun") == nil : true)
            sun.position = p
            sun.look(at: .zero, from: p, relativeTo: nil)
            if name == "gameSun" { sun.transform.rotation *= simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        }
    }

    /// Sets the tint of every unlit material under the entity `name` (their pictures stay).
    private func tint(_ name: String, _ color: UIColor) {
        guard let root = world.findEntity(named: name) else { return }
        var stack = [root]
        while let e = stack.popLast() {
            stack += e.children
            guard var model = e.components[ModelComponent.self] else { continue }
            model.materials = model.materials.map { material in
                guard var m = material as? UnlitMaterial else { return material }
                m.color = .init(tint: color, texture: m.color.texture)
                return m
            }
            e.components.set(model)
        }
    }
}
