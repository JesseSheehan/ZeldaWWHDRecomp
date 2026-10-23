import RealityKit
import SwiftUI

/// Full Screen's sky and sea dressed with the game's own pictures: its wave patterns on the sea, its clouds
/// in the sky and on the horizon, its sun. They are read from the imported game folder on the device when
/// Full Screen opens (runtime/src/platform/visionos/game_textures.cpp); nothing from the game is part of
/// the app. Without them (no game folder, a file not found) the plain shapes of Theater.swift stay.
enum GameScenery {
    struct Pictures {
        var waves: CGImage?     // the sea's wave pattern (grey: the waves' light parts)
        var shimmer: CGImage?   // a finer ripple pattern, scrolling the other way
        var sun: CGImage?
        var clouds: [CGImage] = []     // single clouds (with alpha)
        var horizon: [CGImage] = []    // long strips of cloud bank along the horizon
        var complete: Bool { waves != nil && !clouds.isEmpty }
    }

    /// Reads and decodes the pictures (a second or so of CPU: call off the main thread).
    static func load(gameFolder: String) -> Pictures {
        func picture(_ file: String, _ members: String, _ name: String) -> CGImage? {
            var w: Int32 = 0, h: Int32 = 0
            guard let rgba = wwhd_visionos_game_texture(gameFolder, file, members, name, &w, &h) else { return nil }
            defer { wwhd_visionos_free(rgba) }
            let data = CFDataCreate(nil, rgba, Int(w) * Int(h) * 4)!
            return CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                           provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        let always = ("content/Common/Pack/permanent_3d.pack", "Always.szs/Always.bfres")
        let sea = ("content/Common/Stage/sea_T_Stage.szs", "Stage.bfres")
        var p = Pictures()
        p.waves = picture(always.0, always.1, "umipt")
        p.shimmer = picture(always.0, always.1, "b_wyurayura_tex1")
        p.sun = picture(always.0, always.1, "txa_taiyo")
        p.clouds = ["cloudtx_01", "cloudtx_02", "cloudtx_03"].compactMap { picture(sea.0, sea.1, $0) }
        p.horizon = ["ws_mae08", "ws_mae09", "ws_naka06"].compactMap { picture(sea.0, sea.1, $0) }
        return p
    }

    /// Adds the game's scenery to `world` (and hides the plain clouds and sun it replaces); returns what
    /// animates it each frame (seconds since Full Screen opened).
    @MainActor static func build(_ p: Pictures, into world: Entity, seaLevel: Float) -> (Double) -> Void {
        guard p.complete else { return { _ in } }
        world.findEntity(named: "plainClouds")?.isEnabled = false
        world.findEntity(named: "plainSun")?.isEnabled = false
        var animations: [(Double) -> Void] = []

        // the sea: two layers of the game's wave patterns over the plain sea colour, drifting apart
        func waveLayer(_ image: CGImage, height: Float, tint: UIColor, tiles: Float, drift: SIMD2<Float>, name: String) {
            guard let texture = try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
            else { return }
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: tint, texture: .init(texture, sampler: repeating))
            m.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture, sampler: repeating)))
            m.textureCoordinateTransform = .init(scale: [tiles, tiles])
            let layer = ModelEntity(mesh: .generatePlane(width: 400, depth: 400), materials: [m])
            layer.name = name
            layer.position = [0, height, 0]
            world.addChild(layer)
            animations.append { t in
                guard var model = layer.model, var material = model.materials.first as? UnlitMaterial else { return }
                let o = drift * Float(t.truncatingRemainder(dividingBy: 10_000))
                material.textureCoordinateTransform = .init(offset: [o.x - o.x.rounded(.down), o.y - o.y.rounded(.down)], scale: [tiles, tiles])
                model.materials = [material]
                layer.model = model
            }
        }
        if let waves = p.waves {
            waveLayer(waves, height: seaLevel + 0.002, tint: UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 0.75), tiles: 60,
                      drift: [0.004, 0.010], name: "gameWaves")
        }
        if let shimmer = p.shimmer {
            waveLayer(shimmer, height: seaLevel + 0.003, tint: UIColor(red: 0.8, green: 0.95, blue: 1, alpha: 0.35), tiles: 90,
                      drift: [-0.012, 0.006], name: "gameShimmer")
        }

        // clouds: the game's cloud pictures on upright cards around the sky, turning slowly overhead
        let ring = Entity()
        ring.name = "gameClouds"
        world.addChild(ring)
        let cloudMaterials: [UnlitMaterial] = p.clouds.compactMap { image in
            guard let texture = try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
            else { return nil }
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture)))
            return m
        }
        var seed: UInt64 = 11
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        for i in 0..<18 where !cloudMaterials.isEmpty {
            let a = Float(i) / 18 * 2 * .pi + random() * 0.25
            let size = 22 + random() * 18, distance = 95 + random() * 25
            let card = ModelEntity(mesh: .generatePlane(width: size, height: size), materials: [cloudMaterials[i % cloudMaterials.count]])
            card.position = [sin(a) * distance, 14 + random() * 30, -cos(a) * distance]
            card.look(at: [0, card.position.y * 0.6, 0], from: card.position, relativeTo: nil)
            card.transform.rotation *= simd_quatf(angle: .pi, axis: [0, 1, 0])  // the picture's front toward the viewer
            ring.addChild(card)
        }
        animations.append { t in ring.orientation = simd_quatf(angle: Float(t) * 0.004, axis: [0, 1, 0]) }

        // the horizon: the game's cloud bank strips on a low band all around
        if !p.horizon.isEmpty {
            let band = ModelEntity(mesh: horizonBand(radius: 140, bottom: -2, top: 26, segments: 48))
            band.name = "gameHorizon"
            if let texture = try? TextureResource(image: p.horizon[0], options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)) {
                var m = UnlitMaterial(applyPostProcessToneMap: false)
                m.faceCulling = .none
                m.color = .init(tint: .white, texture: .init(texture, sampler: repeating))
                m.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture, sampler: repeating)))
                band.model?.materials = [m]
            }
            world.addChild(band)
        }

        // the sun
        if let sunImage = p.sun, let texture = try? TextureResource(image: sunImage, options: .init(semantic: .color)) {
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: UIColor(red: 1, green: 0.96, blue: 0.82, alpha: 1), texture: .init(texture))
            m.blending = .transparent(opacity: .init(scale: 1, texture: .init(texture)))
            let sun = ModelEntity(mesh: .generatePlane(width: 30, height: 30), materials: [m])
            sun.name = "gameSun"
            sun.position = [-60, 70, -100]
            sun.look(at: .zero, from: sun.position, relativeTo: nil)
            sun.transform.rotation *= simd_quatf(angle: .pi, axis: [0, 1, 0])
            world.addChild(sun)
        }
        return { t in animations.forEach { $0(t) } }
    }

    private static var repeating: MaterialParameters.Texture.Sampler {
        let d = MTLSamplerDescriptor()
        d.sAddressMode = .repeat
        d.tAddressMode = .repeat
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        return .init(d)
    }

    /// A cylinder band around the viewer seen from inside, its picture repeated four times around.
    private static func horizonBand(radius: Float, bottom: Float, top: Float, segments: Int) -> MeshResource {
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        for i in 0...segments {
            let u = Float(i) / Float(segments), a = u * 2 * .pi
            positions += [[sin(a) * radius, top, -cos(a) * radius], [sin(a) * radius, bottom, -cos(a) * radius]]
            uvs += [[u * 4, 1], [u * 4, 0]]
        }
        for i in 0..<UInt32(segments) {
            let t0 = 2 * i, b0 = t0 + 1, t1 = t0 + 2, b1 = t0 + 3
            indices += [t0, b0, t1, t1, b0, b1]
        }
        var d = MeshDescriptor(name: "horizon")
        d.positions = .init(positions)
        d.textureCoordinates = .init(uvs)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d])) ?? .generateBox(size: 0.01)
    }
}
