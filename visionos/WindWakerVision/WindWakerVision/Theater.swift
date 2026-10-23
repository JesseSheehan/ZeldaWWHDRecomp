import Metal
import RealityKit
import SwiftUI

/// Theater mode: the TV picture on a large, slightly curved screen in an immersive space, in a sky over a
/// calm sea (the Digital Crown brings your room back in) or in your own room, dimmed. The runtime draws its
/// TV picture straight into the screen's texture (a DrawableQueue: runtime/src/platform/visionos/theater.mm),
/// so the picture costs no copy; the TV window closes meanwhile and comes back when theater mode ends. The
/// GamePad window stays a window. Everything around the screen is drawn here from simple shapes.
@Observable final class Theater {
    static let shared = Theater()

    enum Size: Int, CaseIterable {
        case small, medium, huge
        var width: Float { [3, 5, 12][rawValue] }       // m
        var distance: Float { [4, 7, 12][rawValue] }    // m, also the screen's curve radius
        var label: String { ["Small", "Medium", "Huge"][rawValue] }
    }
    enum Surroundings: Int, CaseIterable {
        case sky, dimmed
        var label: String { ["Sky and sea", "Dimmed room"][rawValue] }
    }

    /// The immersive space is open, or opening.
    private(set) var active = false
    var size: Size { didSet { save() } }
    var surroundings: Surroundings { didSet { save() } }

    private init() {
        let d = UserDefaults.standard
        size = Size(rawValue: d.integer(forKey: "wwhd.theaterSize", default: 1)) ?? .medium
        surroundings = Surroundings(rawValue: d.integer(forKey: "wwhd.theaterSurroundings", default: 0)) ?? .sky
        // the settings menu's Theater tab (runtime) asks through this
        wwhd_visionos_set_theater_actions { action, value in
            Task { @MainActor in Theater.shared.perform(action: Int(action), value: Int(value)) }
        }
        report()
    }

    var immersionStyle: any ImmersionStyle {
        surroundings == .sky ? ProgressiveImmersionStyle(immersion: 0.2...1, initialAmount: 1) : MixedImmersionStyle()
    }

    @MainActor func perform(action: Int, value: Int) {
        switch action {
        case 0: Task { value != 0 ? await enter() : await leave() }
        case 1: size = Size(rawValue: value) ?? size
        case 2: surroundings = Surroundings(rawValue: value) ?? surroundings
        default: break
        }
    }

    @MainActor func enter() async {
        let opener = WindowOpener.shared
        guard !active, let open = opener.openImmersiveSpace else { return }
        active = true
        report()
        switch await open(id: "theater") {
        case .opened:
            opener.dismissWindow?(id: "tv", value: TVWindowState.value)
        default:
            active = false
            report()
        }
    }

    @MainActor func leave() async {
        guard active else { return }
        WindowOpener.shared.openTV()
        await WindowOpener.shared.dismissImmersiveSpace?()
    }

    /// The immersive space went (left here, or by the system: the Digital Crown pressed, the app in the
    /// background).
    @MainActor func ended() {
        active = false
        report()
    }

    private func save() {
        UserDefaults.standard.set(size.rawValue, forKey: "wwhd.theaterSize")
        UserDefaults.standard.set(surroundings.rawValue, forKey: "wwhd.theaterSurroundings")
        report()
    }

    private func report() { wwhd_visionos_theater_state(active ? 1 : 0, Int32(size.rawValue), Int32(surroundings.rawValue)) }
}

private extension UserDefaults {
    func integer(forKey key: String, default value: Int) -> Int { object(forKey: key) == nil ? value : integer(forKey: key) }
}

/// The screen's texture between RealityKit and the runtime's render thread (theater.mm calls next and
/// present there).
enum TheaterOutput {
    static let width = 1920, height = 1080
    private static let lock = NSLock()
    private static var queue: TextureResource.DrawableQueue?
    private static var pending: TextureResource.Drawable?

    @MainActor static func start(on texture: TextureResource) throws {
        let descriptor = TextureResource.DrawableQueue.Descriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height,
                                                                  usage: [.renderTarget, .shaderRead], mipmapsMode: .none)
        let q = try TextureResource.DrawableQueue(descriptor)
        q.allowsNextDrawableTimeout = true  // the render thread never waits long for a free texture
        texture.replace(withDrawables: q)
        lock.withLock { queue = q }
        wwhd_visionos_set_theater(next, present, Int32(width), Int32(height))
    }

    static func stop() {
        wwhd_visionos_set_theater(nil, nil, 0, 0)  // returns once no frame is being drawn into it
        lock.withLock {
            queue = nil
            pending = nil
        }
    }

    private static let next: wwhd_theater_next_fn = {
        lock.withLock {
            guard let q = queue, let d = try? q.nextDrawable() else { return nil }
            pending = d
            return Unmanaged.passUnretained(d.texture as AnyObject).toOpaque()
        }
    }

    private static let present: wwhd_theater_present_fn = { buffer in
        lock.withLock {
            guard let d = pending, let buffer else { return }
            pending = nil
            (Unmanaged<AnyObject>.fromOpaque(buffer).takeUnretainedValue() as? MTLCommandBuffer)?.present(d)
        }
    }
}

/// The immersive space: the screen, the controls under it, and the sky, sea and clouds.
struct TheaterSpace: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    private let theater = Theater.shared
    @State private var screen = Entity()
    @State private var world = Entity()

    var body: some View {
        RealityView { content, attachments in
            let texture = try? TextureResource(image: Self.solid(red: 0, green: 0, blue: 0), options: .init(semantic: .color))
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            if let texture {
                material.color = .init(tint: .white, texture: .init(texture))
                try? TheaterOutput.start(on: texture)
            }
            screen.components.set(ModelComponent(mesh: Self.screenMesh(theater.size), materials: [material]))
            content.add(screen)
            world = Self.makeWorld()
            content.add(world)
            if let controls = attachments.entity(for: "controls") {
                controls.position = [0, 0.95, -0.9]
                controls.orientation = simd_quatf(angle: -.pi / 9, axis: [1, 0, 0])
                content.add(controls)
            }
            update()
        } update: { _, _ in
            update()
        } attachments: {
            Attachment(id: "controls") { TheaterControls() }
        }
        .preferredSurroundingsEffect(theater.surroundings == .dimmed ? .systemDark : nil)
        .onAppear {
            // the TV window closes now: this space's actions stand in for its own
            WindowOpener.shared.openWindow = openWindow
            WindowOpener.shared.openImmersiveSpace = openImmersiveSpace
            WindowOpener.shared.dismissImmersiveSpace = dismissImmersiveSpace
        }
        .onDisappear {
            TheaterOutput.stop()
            Theater.shared.ended()
            // the TV window again, whoever closed the space
            if !TVWindowState.shared.open { openWindow(id: "tv", value: TVWindowState.value) }
        }
    }

    private func update() {
        let size = theater.size
        if let model = screen.components[ModelComponent.self], screen.name != "\(size.rawValue)" {
            var m = model
            m.mesh = Self.screenMesh(size)
            screen.components.set(m)
            screen.name = "\(size.rawValue)"
        }
        world.isEnabled = theater.surroundings == .sky
    }

    /// A screen of `size.width` (16:9) on a cylinder around the viewer, at eye height or above for the large ones.
    static func screenMesh(_ size: Theater.Size) -> MeshResource {
        let r = size.distance, w = size.width, h = w * 9 / 16
        let centerY = max(1.4, h / 2 + 0.4)
        let span = w / r, columns = 48
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for i in 0...columns {
            let u = Float(i) / Float(columns), a = (u - 0.5) * span
            let x = r * sin(a), z = -r * cos(a)
            for (row, y) in [(0, centerY + h / 2), (1, centerY - h / 2)] {
                positions.append([x, y, z])
                normals.append([-sin(a), 0, cos(a)])
                uvs.append([u, row == 0 ? 1 : 0])
            }
        }
        for i in 0..<UInt32(columns) {
            let t0 = 2 * i, b0 = t0 + 1, t1 = t0 + 2, b1 = t0 + 3
            indices += [t0, b0, t1, t1, b0, b1]
        }
        var d = MeshDescriptor(name: "screen")
        d.positions = .init(positions)
        d.normals = .init(normals)
        d.textureCoordinates = .init(uvs)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d])) ?? .generatePlane(width: w, height: h)
    }

    // ---- the sky over the sea: unlit shapes in flat toon colours (cheap: no lights, no shadows)
    static func makeWorld() -> Entity {
        let world = Entity()
        func unlit(_ color: UIColor) -> UnlitMaterial {  // the colours as given (no tone mapping)
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: color)
            return m
        }

        // sky dome: a big sphere seen from inside, a vertical gradient from deep blue to a pale horizon
        let sky = ModelEntity(mesh: .generateSphere(radius: 150))
        if let gradient = try? TextureResource(image: skyGradient(), options: .init(semantic: .color)) {
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: .white, texture: .init(gradient))
            sky.model?.materials = [m]
        }
        sky.scale = [-1, 1, 1]
        world.addChild(sky)

        // sun
        let sun = ModelEntity(mesh: .generateSphere(radius: 6), materials: [unlit(UIColor(red: 1, green: 0.97, blue: 0.8, alpha: 1))])
        sun.position = [-60, 70, -100]
        world.addChild(sun)

        // the sea, and a little round deck to stand on
        let sea = ModelEntity(mesh: .generatePlane(width: 400, depth: 400), materials: [unlit(UIColor(red: 0.10, green: 0.45, blue: 0.70, alpha: 1))])
        sea.position = [0, -0.6, 0]
        world.addChild(sea)
        let foam = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 1.9), materials: [unlit(UIColor(white: 0.95, alpha: 1))])
        foam.position = [0, -0.59, 0]
        world.addChild(foam)
        let deck = ModelEntity(mesh: .generateCylinder(height: 0.6, radius: 1.6), materials: [unlit(UIColor(red: 0.55, green: 0.38, blue: 0.22, alpha: 1))])
        deck.position = [0, -0.31, 0]
        world.addChild(deck)
        let deckTop = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 1.5), materials: [unlit(UIColor(red: 0.66, green: 0.47, blue: 0.28, alpha: 1))])
        deckTop.position = [0, 0.0, 0]
        world.addChild(deckTop)

        // clouds: puffs of flattened spheres around the horizon, kept away from behind the screen
        var seed: UInt64 = 7
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 40) / Float(1 << 24)
        }
        let white = unlit(UIColor(white: 1, alpha: 1)), shade = unlit(UIColor(red: 0.86, green: 0.9, blue: 0.97, alpha: 1))
        for i in 0..<14 {
            let a = Float(i) / 14 * 2 * .pi + random() * 0.3
            if abs(remainder(a, 2 * .pi)) < 0.5 { continue }  // straight ahead: the screen
            let cloud = Entity()
            cloud.position = [sin(a) * 90, 18 + random() * 22, -cos(a) * 90]
            for p in 0..<4 {
                let r = 4 + random() * 4
                let puff = ModelEntity(mesh: .generateSphere(radius: r), materials: [p == 0 ? shade : white])
                puff.position = [(Float(p) - 1.5) * 5 + random() * 2, Float(p == 0 ? -1 : 0) + random() * 2, random() * 3]
                puff.scale = [1.3, 0.6, 1]
                cloud.addChild(puff)
            }
            cloud.look(at: [0, cloud.position.y, 0], from: cloud.position, relativeTo: nil)
            world.addChild(cloud)
        }
        return world
    }

    private static func skyGradient() -> CGImage {
        let h = 256
        var pixels = [UInt8](repeating: 255, count: h * 4)
        for y in 0..<h {
            // image row 0 is the top of the texture: the sphere's top (the zenith)
            let t = Float(y) / Float(h - 1)  // 0 zenith .. 1 nadir
            let horizon = max(0, 1 - abs(t - 0.5) * 6)  // a pale band at the horizon
            let up = t < 0.5 ? 1 - t * 2 : 0
            let r = 0.35 + 0.5 * horizon - 0.15 * up, g = 0.62 + 0.3 * horizon - 0.1 * up, b = 0.95 + 0.05 * horizon
            pixels[y * 4] = UInt8(min(1, r) * 255)
            pixels[y * 4 + 1] = UInt8(min(1, g) * 255)
            pixels[y * 4 + 2] = UInt8(min(1, b) * 255)
        }
        return image(width: 1, height: h, pixels: pixels)
    }

    static func solid(red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        image(width: 16, height: 9, pixels: [UInt8]((0..<16 * 9).flatMap { _ in [red, green, blue, 255] }))
    }

    private static func image(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
        let data = CFDataCreate(nil, pixels, pixels.count)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// Under the screen, within reach: leave, the screen size, the surroundings, Settings.
struct TheaterControls: View {
    private let theater = Theater.shared

    var body: some View {
        @Bindable var theater = theater
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { Task { await theater.leave() } } label: { Label("Leave Theater", systemImage: "rectangle.on.rectangle") }
                Button { wwhd_visionos_toggle_settings() } label: { Label("Settings", systemImage: "gearshape") }
            }
            Picker("Screen", selection: $theater.size) {
                ForEach(Theater.Size.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Surroundings", selection: $theater.surroundings) {
                ForEach(Theater.Surroundings.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .frame(width: 460)
        .padding(20)
        .glassBackgroundEffect()
    }
}
