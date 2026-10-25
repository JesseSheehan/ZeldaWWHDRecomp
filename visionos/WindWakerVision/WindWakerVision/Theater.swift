import AVFoundation
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
        case sky, dimmed, room
        var label: String { ["The Great Sea", "Dimmed room", "Your room"][rawValue] }
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
            // the GamePad window carries the full-screen controls: one window to move around
            if !GamePadWindowState.shared.open { opener.openGamePad() }
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
    /// the texture's size, chosen at each start: the game picture's (Graphics > Internal resolution), at
    /// least 2560 x 1440 (room for MetalFX's sharpening) and at most 3840 x 2160
    static private(set) var width = 2560, height = 1440
    private static let lock = NSLock()
    private static var queue: TextureResource.DrawableQueue?
    private static var pending: TextureResource.Drawable?
    /// queues just replaced (3D switched): RealityKit still finishes presenting their last frames on the
    /// GPU's completion, after the runtime let go of them; freeing them at once crashed in that handler
    private static var retired: [(TextureResource.DrawableQueue, Date)] = []

    /// `stereo`: 3D, both eyes side by side (twice as wide)
    @MainActor static func start(on texture: TextureResource, stereo: Bool = false) throws {
        var w: Int32 = 0, h: Int32 = 0
        wwhd_visionos_tv_picture_size(&w, &h)
        let eye = min(3840, max(2560, Int(w)))
        height = min(2160, Int(Double(eye) / ScreenPicture.shared.aspect) / 2 * 2)
        width = stereo ? 2 * eye : eye
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
            let now = Date()
            retired.removeAll { now.timeIntervalSince($0.1) > 5 }
            if let q = queue { retired.append((q, now)) }
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

/// The screen's picture, for whichever screen shows it now: Full Screen's or the game window's (one for the
/// app: a view attaches its screen, and reflection, when it appears and detaches when it goes; only the
/// screen attached last gets the picture). The texture is always two pictures wide: the runtime draws the
/// two eye pictures into it with 3D on (Settings > Vision Pro > 3D) and the same picture twice with it off
/// (host.mm compose_tv_sbs), so switching 3D changes nothing here: no texture, view or material is
/// replaced, from one frame to the next. The screen's material (Resources/StereoScreen.usda) shows each eye
/// its half; until it has loaded, a plain one shows the left half. The reflection shows the left half.
@MainActor final class ScreenPicture {
    static let shared = ScreenPicture()
    let reflectionScaleX: Float = 0.5
    private var stereoLook: ShaderGraphMaterial?
    private var texture: TextureResource?
    private var showsStereoLook = false
    private var screen: Entity?, reflection: Entity?
    private var owner: ObjectIdentifier?
    private var pattern = false
    /// The game window's shape while its screen has the picture (nil: Full Screen's)
    var windowShape: Double?
    /// The picture's shape now: the Aspect ratio setting, or with "Match window" the window's (Full Screen: 16:9)
    var aspect: Double {
        let a = PictureShape.shared.aspect
        return a > 0 ? a : windowShape ?? 16.0 / 9.0
    }
    private var textureAspect = 0.0  // the shape the texture was made for

    private init() {
        Task { @MainActor in
            self.stereoLook = try? await ShaderGraphMaterial(named: "/Root/StereoScreen", from: "StereoScreen.usda", in: .main)
            if self.stereoLook == nil { print("[visionos] 3D: the per-eye material did not load") }
        }
    }

    func attach(screen: Entity, reflection: Entity?, pattern: Bool, owner: AnyObject) {
        self.screen = screen
        self.reflection = reflection
        self.pattern = pattern
        self.owner = ObjectIdentifier(owner)
        if !pattern { TheaterOutput.stop() }
        texture = try? TextureResource(image: pattern ? TheaterSpace.colorBarsTwice() : TheaterSpace.solid(red: 0, green: 0, blue: 0),
                                       options: .init(semantic: .color))
        guard let texture else { return }
        if !pattern { try? TheaterOutput.start(on: texture, stereo: true) }
        textureAspect = aspect
        showsStereoLook = false
        applyLook()
        if let reflection {
            for mirror in reflection.children {
                guard var model = mirror.components[ModelComponent.self] else { continue }
                model.materials = [TheaterSpace.reflectionMaterial(texture)]
                mirror.components.set(model)
            }
        }
    }

    func detach(owner: AnyObject) {
        guard self.owner == ObjectIdentifier(owner) else { return }  // (another view has the picture now)
        self.owner = nil
        screen = nil
        reflection = nil
        texture = nil
        if !pattern { TheaterOutput.stop() }
    }

    /// every frame: the per-eye material once it has loaded (a material change only, once)
    func check() {
        if !showsStereoLook, stereoLook != nil, screen != nil { applyLook() }
        // the picture changed shape (Settings > Graphics > Aspect ratio, or the window with "Match window"):
        // a texture of that shape, so the picture fills the screen without bars
        if let texture, !pattern, abs(aspect - textureAspect) > 0.005 {
            textureAspect = aspect
            TheaterOutput.stop()
            try? TheaterOutput.start(on: texture, stereo: true)
        }
    }

    private func applyLook() {
        guard let screen, let texture else { return }
        var look: any RealityKit.Material
        if var m = stereoLook, (try? m.setParameter(name: "Picture", value: .textureResource(texture))) != nil {
            look = m
            showsStereoLook = true
        } else {
            var m = UnlitMaterial(applyPostProcessToneMap: false)
            m.color = .init(tint: .white, texture: .init(texture))
            m.textureCoordinateTransform = .init(scale: [0.5, 1])  // the left half (2D: the same in both)
            look = m
        }
        if var model = screen.components[ModelComponent.self] {
            model.materials = [look]
            screen.components.set(model)
        } else {
            screen.components.set(ModelComponent(mesh: .generatePlane(width: 1, height: 1), materials: [look]))
        }
    }
}

/// The immersive space: the screen, the controls under it, and the sky, sea and clouds.
struct TheaterSpace: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    private let theater = Theater.shared
    private let gamepad = GamePadWindowState.shared
    @State private var screen = Entity()
    @State private var world = Entity()
    @State private var reflection = Entity()  // holds the reflection (its mesh follows the screen size)
    @State private var controls: Entity?
    @State private var frames: EventSubscription?
    @State private var animation = Animation()
    @State private var sound: TheaterSound?

    /// What moves each frame: the game's scenery (GameScenery) and the reflection's ripple.
    final class Animation {
        var scenery: (Double) -> Void = { _ in }
        var shown = false  // (this space has attached its screen to ScreenPicture)
        let start = Date()
    }

    var body: some View {
        RealityView { content, attachments in
            // test switch: WWHD_TEST_THEATER=pattern shows colour bars instead of the game (simulator)
            let pattern = ProcessInfo.processInfo.environment["WWHD_TEST_THEATER"] == "pattern"
            screen.components.set(ModelComponent(mesh: Self.screenMesh(theater.size, onSea: theater.surroundings == .sky), materials: []))
            content.add(screen)
            world = Self.makeWorld()
            content.add(world)
            // the screen's reflection in the sea: the same texture (no copy), darker, fading with depth
            reflection.addChild(ModelEntity(mesh: Self.reflectionMesh(theater.size), materials: []))
            world.addChild(reflection)
            // the picture on both, 2D or 3D (ScreenPicture)
            ScreenPicture.shared.windowShape = nil
            ScreenPicture.shared.attach(screen: screen, reflection: reflection, pattern: pattern, owner: animation)
            animation.shown = true
            if ProcessInfo.processInfo.environment["WWHD_TEST_THEATER"] == "stereo" { Self.testStereoMaterial(on: screen) }
            // the game's own waves, clouds and sun, from the game folder (GameScenery), once decoded
            let animation = animation, world = world, folder = GameLibrary.shared.gameFolder.path
            Task.detached(priority: .utility) {
                let pictures = GameScenery.load(gameFolder: folder)
                await MainActor.run { animation.scenery = GameScenery.build(pictures, into: world, seaLevel: Self.seaLevel) }
            }
            let sound = TheaterSound()
            content.add(sound.root)
            self.sound = sound
            let reflection = reflection, sky = SkyClock(world: world)
            frames = content.subscribe(to: SceneEvents.Update.self) { _ in
                let t = Date().timeIntervalSince(animation.start)
                animation.scenery(t)
                sky.update()
                ScreenPicture.shared.check()
                sound.update(size: Theater.shared.size, onSea: Theater.shared.surroundings == .sky)
                // the reflection sways a little, as on moving water (in 3D it shows the left eye's half)
                let scaleX = ScreenPicture.shared.reflectionScaleX
                for strip in reflection.children {
                    guard var model = strip.components[ModelComponent.self], var m = model.materials.first as? UnlitMaterial else { continue }
                    m.textureCoordinateTransform = .init(offset: [Float(sin(t * 1.7)) * 0.004, Float(sin(t * 1.1)) * 0.006],
                                                         scale: [scaleX, 1])
                    model.materials = [m]
                    strip.components.set(model)
                }
            }
            if let panel = attachments.entity(for: "controls") {
                content.add(panel)
                controls = panel
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
            ScreenPicture.shared.detach(owner: animation)
            sound?.stop()
            Theater.shared.ended()
            // the TV window again, whoever closed the space
            if !TVWindowState.shared.open { openWindow(id: "tv", value: TVWindowState.value) }
        }
    }

    private func update() {
        let size = theater.size, onSea = theater.surroundings == .sky
        // the controls float here only while the GamePad window (which carries them) is closed
        controls?.isEnabled = !gamepad.open
        let key = "\(size.rawValue) \(onSea) \(PictureShape.shared.fullScreenAspect)"
        if let model = screen.components[ModelComponent.self], screen.name != key {
            var m = model
            m.mesh = Self.screenMesh(size, onSea: onSea)
            screen.components.set(m)
            screen.name = key
            // the reflection follows the screen's size (its material, with the live picture, stays)
            if let mirror = reflection.children.first, var model = mirror.components[ModelComponent.self] {
                model.mesh = Self.reflectionMesh(size)
                mirror.components.set(model)
            }
        }
        if let controls {
            if onSea {
                // the screen stands on the water: the controls float closer, low, below it as you look,
                // where they hide only the near end of the reflection
                controls.position = [0, 0.4, -1.2]
                controls.scale = .init(repeating: 1)
                controls.orientation = simd_quatf(angle: -atan2(1.3 - 0.4, 1.2), axis: [1, 0, 0])
            } else {
                // just under the screen's bottom edge, as large as a panel 2 m away would look
                let layout = Self.layout(size, onSea: false), scale = size.distance / 2
                let y = layout.bottom - 0.05 - 0.15 * scale, z = -(size.distance - 0.1)
                controls.position = [0, y, z]
                controls.scale = .init(repeating: scale)
                controls.orientation = simd_quatf(angle: -atan2(1.3 - y, -z), axis: [1, 0, 0])
            }
        }
        world.isEnabled = onSea
    }

    /// Where the screen is: its centre and bottom edge (m up). On the sea it stands just above the water,
    /// so its reflection starts right under it; in the room it leaves space under it for the controls.
    static func layout(_ size: Theater.Size, onSea: Bool) -> (center: Float, bottom: Float) {
        let h = size.width / Float(PictureShape.shared.fullScreenAspect)
        let center = onSea ? seaLevel + 0.12 + h / 2 : max(1.4, h / 2 + 0.7)
        return (center, center - h / 2)
    }

    /// A screen of `size.width` (16:9) on a cylinder around the viewer, at eye height or above for the large ones.
    static func screenMesh(_ size: Theater.Size, onSea: Bool) -> MeshResource { curvedMesh(size, onSea: onSea, name: "screen") { $0 } }

    static let seaLevel: Float = -0.6

    /// The screen mirrored in the sea, laid onto the water's surface as the eyes (about 1.2 m up, seated)
    /// see it: each mirrored point is moved along its line of sight to just above the water.
    static func reflectionMesh(_ size: Theater.Size, rows: ClosedRange<Float> = 0...1) -> MeshResource {
        let eye: Float = 1.2, surface = seaLevel + 0.001
        return curvedMesh(size, onSea: true, name: "reflection", rows: rows) { p in
            let mirrored = SIMD3<Float>(p.x, 2 * seaLevel - p.y, p.z)
            let t = (eye - surface) / (eye - mirrored.y)
            return SIMD3<Float>(0, eye, 0) + t * (mirrored - SIMD3<Float>(0, eye, 0))
        }
    }


    /// The reflection's look: the game picture darkened and tinted by the water, most visible at the
    /// waterline and fading out toward the far (top) edge of the picture.
    static func reflectionMaterial(_ texture: TextureResource) -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        m.faceCulling = .none  // lying flat, seen from above: either winding
        m.color = .init(tint: UIColor(red: 0.42, green: 0.58, blue: 0.72, alpha: 1), texture: .init(texture))
        let h = 64
        var fade = [UInt8](repeating: 255, count: h * 4)
        for y in 0..<h {
            // image row 0 is the picture's top (v = 1, nearest the viewer): transparent; the waterline about 55 %
            let a = UInt8(145 * pow(Float(y) / Float(h - 1), 1.2))
            fade[y * 4] = a; fade[y * 4 + 1] = a; fade[y * 4 + 2] = a
        }
        if let opacity = try? TextureResource(image: image(width: 1, height: h, pixels: fade), options: .init(semantic: .raw)) {
            m.blending = .transparent(opacity: .init(scale: 1, texture: .init(opacity)))
        } else {
            m.blending = .transparent(opacity: .init(floatLiteral: 0.3))
        }
        return m
    }

    /// The screen's curved quad strip; `place` moves each vertex (the reflection lays it onto the sea).
    private static func curvedMesh(_ size: Theater.Size, onSea: Bool, name: String, rows: ClosedRange<Float> = 0...1,
                                   place: (SIMD3<Float>) -> SIMD3<Float>) -> MeshResource {
        let r = size.distance, w = size.width, h = w / Float(PictureShape.shared.fullScreenAspect)
        let centerY = layout(size, onSea: onSea).center, bottomY = centerY - h / 2
        let span = w / r, columns = 48
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for i in 0...columns {
            let u = Float(i) / Float(columns), a = (u - 0.5) * span
            let x = r * sin(a), z = -r * cos(a)
            for v in [rows.upperBound, rows.lowerBound] {
                let p = place([x, bottomY + v * h, z])
                positions.append(p)
                normals.append(p.y < bottomY ? [0, 1, 0] : [-sin(a), 0, cos(a)])
                uvs.append([u, v])
            }
        }
        for i in 0..<UInt32(columns) {
            let t0 = 2 * i, b0 = t0 + 1, t1 = t0 + 2, b1 = t0 + 3
            indices += [t0, b0, t1, t1, b0, b1]
        }
        var d = MeshDescriptor(name: name)
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
        sky.name = "sky"
        world.addChild(sky)

        // sun (the game's replaces it: GameScenery)
        let sun = ModelEntity(mesh: .generateSphere(radius: 6), materials: [unlit(UIColor(red: 1, green: 0.97, blue: 0.8, alpha: 1))])
        sun.position = [-60, 70, -100]
        sun.name = "plainSun"
        world.addChild(sun)

        // the sea, and a little round deck to stand on
        let sea = ModelEntity(mesh: .generatePlane(width: 400, depth: 400), materials: [unlit(UIColor(red: 0.10, green: 0.45, blue: 0.70, alpha: 1))])
        sea.position = [0, seaLevel, 0]
        sea.name = "sea"
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
        let clouds = Entity()  // (the game's replace them: GameScenery)
        clouds.name = "plainClouds"
        world.addChild(clouds)
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
            clouds.addChild(cloud)
        }
        return world
    }

    /// The sky dome's picture: `zenith` overhead blending into `horizon` at the horizon (SkyClock sets the
    /// colours through the day), a little darker below it.
    static func skyGradient(zenith: SIMD3<Float> = [0.25, 0.52, 0.93], horizon: SIMD3<Float> = [0.80, 0.90, 0.99]) -> CGImage {
        let h = 256
        var pixels = [UInt8](repeating: 255, count: h * 4)
        for y in 0..<h {
            // image row 0 is the top of the texture: the sphere's top (the zenith)
            let t = Float(y) / Float(h - 1)  // 0 zenith .. 1 nadir
            let c: SIMD3<Float>
            if t < 0.5 {
                let f = pow(t * 2, 2.2)  // most of the sky keeps the zenith colour, the horizon colour near it
                c = zenith + (horizon - zenith) * f
            } else {
                c = horizon * (1 - (t - 0.5) * 0.6)
            }
            pixels[y * 4] = UInt8(min(1, max(0, c.x)) * 255)
            pixels[y * 4 + 1] = UInt8(min(1, max(0, c.y)) * 255)
            pixels[y * 4 + 2] = UInt8(min(1, max(0, c.z)) * 255)
        }
        return image(width: 1, height: h, pixels: pixels)
    }

    /// Test (WWHD_TEST_THEATER=stereo): the 3D material with a side-by-side picture, left half colour
    /// bars, right half grey; what happened goes to Documents/captures/stereo-test.txt.
    @MainActor static func testStereoMaterial(on screen: Entity) {
        Task { @MainActor in
            let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("captures/stereo-test.txt")
            try? FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                var m = try await ShaderGraphMaterial(named: "/Root/StereoScreen", from: "StereoScreen.usda", in: .main)
                let bars = colorBars()
                var pixels: [UInt8] = []
                for y in 0..<bars.height {
                    for x in 0..<32 {
                        if x < 16 {
                            let c = (bars.dataProvider!.data! as Data)
                            let i = (y * 16 + x) * 4
                            pixels += [c[i], c[i + 1], c[i + 2], 255]
                        } else {
                            pixels += [128, 128, 128, 255]
                        }
                    }
                }
                let sbs = try await TextureResource(image: image(width: 32, height: bars.height, pixels: pixels), options: .init(semantic: .color))
                try m.setParameter(name: "Picture", value: .textureResource(sbs))
                if var model = screen.components[ModelComponent.self] {
                    model.materials = [m]
                    screen.components.set(model)
                }
                try? "loaded".write(to: report, atomically: true, encoding: .utf8)
            } catch {
                try? "failed: \(error)".write(to: report, atomically: true, encoding: .utf8)
            }
        }
    }

    /// The colour bars side by side, as the runtime's two-picture texture holds them (tests).
    static func colorBarsTwice() -> CGImage {
        let bars = colorBars(), data = bars.dataProvider!.data! as Data
        var pixels: [UInt8] = []
        for y in 0..<bars.height {
            for x in 0..<2 * bars.width {
                let i = (y * bars.width + x % bars.width) * 4
                pixels += [data[i], data[i + 1], data[i + 2], 255]
            }
        }
        return image(width: 2 * bars.width, height: bars.height, pixels: pixels)
    }

    /// Colour bars, brighter at the top (tests: which way up the picture and its reflection are).
    static func colorBars() -> CGImage {
        let w = 16, h = 9
        let bars: [[UInt8]] = [[255, 255, 255], [255, 220, 0], [0, 220, 255], [0, 200, 0], [255, 0, 200], [230, 0, 0], [0, 0, 230], [40, 40, 40]]
        var pixels: [UInt8] = []
        for y in 0..<h {
            for x in 0..<w {
                let c = y < 2 ? [UInt8(255), 255, 255] : bars[x / 2]
                pixels += [c[0], c[1], c[2], 255]
            }
        }
        return image(width: w, height: h, pixels: pixels)
    }

    static func solid(red: UInt8, green: UInt8, blue: UInt8) -> CGImage {
        image(width: 16, height: 9, pixels: [UInt8]((0..<16 * 9).flatMap { _ in [red, green, blue, 255] }))
    }

    static func image(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
        let data = CFDataCreate(nil, pixels, pixels.count)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// The full-screen controls: leave, the screen size, the surroundings, Settings. Under the GamePad window
/// (WindWakerVisionApp.swift), or under the screen while that window is closed.
struct TheaterControls: View {
    var inGamePadWindow = false
    private let theater = Theater.shared
    private let gamepad = GamePadWindowState.shared

    var body: some View {
        @Bindable var theater = theater
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { Task { await theater.leave() } } label: { Label("Leave Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") }
                Button { wwhd_visionos_toggle_settings() } label: { Label("Settings", systemImage: "gearshape") }
                if inGamePadWindow {
                    Button { gamepad.collapsed.toggle() } label: {
                        Label(gamepad.collapsed ? "Show GamePad Screen" : "Hide GamePad Screen",
                              systemImage: gamepad.collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    }
                }
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
        .frame(width: inGamePadWindow ? 560 : 460)
        .padding(20)
        .glassBackgroundEffect()
    }
}

/// Full Screen's sound: the game's channels as sound sources in the immersive space instead of the window
/// output (runtime/src/audio_out.cpp wwhd_visionos_audio_source). Front left and right at the screen's
/// sides, the centre at its middle, the surround channels behind you to the sides (Surround 5.1); the
/// headset keeps them in place as you turn your head. Settings > Vision Pro turns it off: the window output
/// as before. If a source cannot start, the window output stays.
@MainActor final class TheaterSound {
    let root = Entity()  // in the space's coordinates (the viewer's feet at the origin)
    private var sources: [Entity] = []
    private var controllers: [AudioGeneratorController] = []
    private var placed = ""
    private var boost: Double = -1  // the gain the sources have (dB)

    init() { root.name = "sound" }

    /// Each frame: on or off as the setting says, and placed for the screen.
    func update(size: Theater.Size, onSea: Bool) {
        let wanted = wwhd_visionos_spatial_sound() != 0
        if wanted, controllers.isEmpty { start() } else if !wanted, !controllers.isEmpty { stop() }
        guard !sources.isEmpty else { return }
        let gain = wwhd_visionos_spatial_boost()
        if gain != boost {
            boost = gain
            for e in sources { e.components[SpatialAudioComponent.self]?.gain = gain }
        }
        let key = "\(size.rawValue) \(onSea) \(sources.count)"
        guard key != placed else { return }
        placed = key
        let d = size.distance, y = TheaterSpace.layout(size, onSea: onSea).center
        let side = size.width * 0.42 / d  // the front sources' angle, near the screen's edges
        let spots: [SIMD3<Float>] = [[-sin(side) * d, y, -cos(side) * d], [sin(side) * d, y, -cos(side) * d], [0, y, -d],
                                     [-1.6, 1.3, 0.9], [1.6, 1.3, 0.9]]
        for (i, e) in sources.enumerated() { e.position = spots[i] }
    }

    private func start() {
        let count = wwhd_visionos_audio_channels() == 6 ? 5 : 2
        do {
            for i in 0..<count {
                let e = Entity()
                // the same loudness at every screen size: no fall-off with distance
                e.components.set(SpatialAudioComponent(gain: wwhd_visionos_spatial_boost(), directLevel: .zero, reverbLevel: -12, directivity: .beam(focus: 0),
                                                       distanceAttenuation: .rolloff(factor: 0)))
                root.addChild(e)
                sources.append(e)
                controllers.append(try e.playAudio(configuration: .init(layoutTag: kAudioChannelLayoutTag_Mono), Self.renderer(Int32(i))))
            }
            wwhd_visionos_audio_external(1)
            placed = ""
            boost = wwhd_visionos_spatial_boost()  // (set on each source from the start: changes only later)
        } catch {
            NSLog("[audio] Full Screen sound sources: %@", error.localizedDescription)
            stop()
        }
    }

    func stop() {
        wwhd_visionos_audio_external(0)
        controllers.forEach { $0.stop() }
        controllers = []
        sources.forEach { $0.removeFromParent() }
        sources = []
    }

    /// Source `source`'s render block (RealityKit's audio thread; nothing of the main actor in it).
    nonisolated private static func renderer(_ source: Int32) -> Audio.GeneratorRenderHandler {
        { _, _, frameCount, data in
            for buffer in UnsafeMutableAudioBufferListPointer(data) {
                guard let p = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                wwhd_visionos_audio_source(source, p, Int32(min(frameCount, buffer.mDataByteSize / 4)))
            }
            return noErr
        }
    }
}

/// The TV picture's shape (Settings > Graphics > Aspect ratio), polled twice a second: the game window takes
/// it (keeping its height; resizing keeps it), and so do Full Screen's screen and the picture's texture
/// (ScreenPicture), so the picture fills them with no bars. "Match window" (0): the window is resized
/// freely and the game draws to its shape; Full Screen stays 16:9. Bars the game draws itself stay.
@Observable @MainActor final class PictureShape {
    static let shared = PictureShape()
    private(set) var aspect = 16.0 / 9.0  // 0: "Match window"
    var fullScreenAspect: Double { aspect > 0 ? aspect : 16.0 / 9.0 }
    @ObservationIgnored weak var windowScene: UIWindowScene?  // the game window's (GameLayerView)
    @ObservationIgnored private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { PictureShape.shared.poll() } }
    }

    private func poll() {
        let a = wwhd_visionos_picture_aspect()
        guard a.isFinite, abs(a - aspect) > 0.005 else { return }
        aspect = a
        shapeWindow()
    }

    /// The game window to the picture's shape, at its height (or free with "Match window").
    func shapeWindow() {
        guard let scene = windowScene else { return }
        let size = scene.effectiveGeometry.coordinateSpace.bounds.size
        let preferences: UIWindowScene.GeometryPreferences.Vision
        if aspect > 0, size.height > 0 {
            preferences = .init(size: CGSize(width: size.height * aspect, height: size.height), minimumSize: nil, maximumSize: nil,
                                resizingRestrictions: .uniform)
        } else {
            preferences = .init(size: nil, minimumSize: nil, maximumSize: nil, resizingRestrictions: .freeform)
        }
        scene.requestGeometryUpdate(preferences) { error in NSLog("[visionos] window shape: %@", error.localizedDescription) }
    }
}
