import AVFoundation
import GameController
import RealityKit
import SwiftUI

@main
struct WindWakerVisionApp: App {
    var body: some SwiftUI.Scene {
        // the TV picture (and the settings overlay). One value, one window, as for the GamePad window: it
        // can be closed while the GamePad window stays, and − / + or the GamePad window's TV button open it again
        WindowGroup(id: "tv", for: String.self) { _ in
            TVWindow()
        } defaultValue: {
            TVWindowState.value
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentSize)

        // the Wii U GamePad's screen; while it is closed the TV window shows it as picture-in-picture.
        // One value, one window: opening it again brings the open one forward.
        WindowGroup(id: "gamepad", for: String.self) { _ in
            GamePadWindow()
        } defaultValue: {
            GamePadWindowState.value
        }
        .defaultSize(width: 640, height: 360)
        .windowResizability(.contentSize)

        // theater mode (Theater.swift): the TV picture on a big screen; The Great Sea (progressive: the
        // Digital Crown brings the room back in) or the room dimmed (mixed)
        ImmersiveSpace(id: "theater") {
            TheaterSpace()
        }
        .immersionStyle(selection: Binding(get: { Theater.shared.immersionStyle }, set: { _ in }),
                        in: .mixed, .progressive)
    }
}

/// Whether the GamePad window is open (its view is in a window).
@Observable final class GamePadWindowState {
    static let shared = GamePadWindowState()
    static let value = "gamepad"
    var open = false
    /// In full screen: the window shows only the full-screen controls (the GamePad picture goes back to
    /// the picture-in-picture on the big screen). Remembered.
    var collapsed = UserDefaults.standard.bool(forKey: "wwhd.gamepadCollapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "wwhd.gamepadCollapsed") }
    }
}

/// Whether the TV window is open.
@Observable final class TVWindowState {
    static let shared = TVWindowState()
    static let value = "tv"
    var open = false
}

/// Opens the windows from controller buttons (ControllerButtonWatcher), with the openWindow action of a
/// window that is open: each window hands over its own when it appears, and the GamePad window again when
/// the TV window closes.
final class WindowOpener {
    static let shared = WindowOpener()
    var openWindow: OpenWindowAction?
    var dismissWindow: DismissWindowAction?
    var openImmersiveSpace: OpenImmersiveSpaceAction?
    var dismissImmersiveSpace: DismissImmersiveSpaceAction?

    func openTV() { openWindow?(id: "tv", value: TVWindowState.value) }
    func openGamePad() { openWindow?(id: "gamepad", value: GamePadWindowState.value) }

    /// + (Start): the TV window if it is closed, otherwise the GamePad window if that is (the game shows
    /// its menus there). − (Settings): the TV window if it is closed. While the TV window is closed the
    /// runtime keeps that press from the game and from Settings (host.mm).
    func buttonPressed(start: Bool) {
        if !TVWindowState.shared.open, !Theater.shared.active { openTV() }
        else if start, !GamePadWindowState.shared.open { openGamePad() }
    }
}

struct TVWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    private let gamepad = GamePadWindowState.shared
    private let library = GameLibrary.shared
    private let resume = ResumeOffer.shared

    var body: some View {
        content
            .onAppear {
                TVWindowState.shared.open = true
                let opener = WindowOpener.shared
                opener.openWindow = openWindow
                opener.dismissWindow = dismissWindow
                opener.openImmersiveSpace = openImmersiveSpace
                opener.dismissImmersiveSpace = dismissImmersiveSpace
                _ = ControllerButtonWatcher.shared
                _ = Theater.shared  // the settings menu's Theater tab reaches the app from now on
                // test switch: WWHD_TEST_THEATER=1 enters full screen at start (=pattern: with colour bars, Theater.swift)
                if let test = ProcessInfo.processInfo.environment["WWHD_TEST_THEATER"], test == "1" || test == "pattern" || test == "stereo", !Theater.shared.active {
                    Task { await Theater.shared.enter() }
                }
            }
            .onDisappear { TVWindowState.shared.open = false }
            .onChange(of: scenePhase) { _, phase in TVWindowState.shared.open = phase != .background }
    }

    @ViewBuilder private var content: some View {
        if library.state != .ready {
            ImportView().frame(minWidth: 960, minHeight: 540)
        } else if resume.pending {
            ResumeView().frame(minWidth: 960, minHeight: 540)
        } else {
            game
        }
    }

    private var game: some View {
        GameView()
            .ornament(attachmentAnchor: .scene(.bottom)) {
                HStack {
                    Button { wwhd_visionos_toggle_settings() } label: { Label("Settings", systemImage: "gearshape") }
                    Button { Task { await Theater.shared.enter() } } label: { Label("Full Screen", systemImage: "mountain.2") }
                    Button {
                        if gamepad.open { dismissWindow(id: "gamepad", value: GamePadWindowState.value) } else { openGamePad() }
                    } label: {
                        Label(gamepad.open ? "Close GamePad screen" : "Open GamePad screen", systemImage: "gamecontroller")
                    }
                }
                .labelStyle(.iconOnly)
                .padding(8)
                .glassBackgroundEffect()
            }
    }
}

extension TVWindow {
    private func openGamePad() { openWindow(id: "gamepad", value: GamePadWindowState.value) }
}

/// The TV picture: hands its layer to the runtime while the window is open (closed: the game runs on).
struct GameView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var view = GameLayerView()
    /// 3D (Settings > Vision Pro > 3D): the window shows the per-eye screen over its layer view (which stays:
    /// the runtime started from it, the controller and the keyboard go through it); checked twice a second
    @State private var stereo = wwhd_visionos_depth3d() != 0
    private let check = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            MetalLayerView { view }
            if stereo, !Theater.shared.active { StereoWindowScreen() }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay { ShaderPreparationView() }
        .onAppear { view.attach(true) }
        .onDisappear { view.attach(false) }
        .onChange(of: scenePhase) { _, phase in view.attach(phase != .background) }
        .onReceive(check) { _ in
            let on = wwhd_visionos_depth3d() != 0
            if on != stereo { stereo = on }
        }
    }
}

/// The game window in 3D: a flat RealityKit screen filling the window, with the same picture and per-eye
/// material as Full Screen (Theater.swift ScreenPicture). While it shows, the runtime draws into its
/// texture instead of the window's layer (host.mm: the screen texture, when set, wins).
struct StereoWindowScreen: View {
    @Environment(\.physicalMetrics) private var metrics
    @State private var screen = Entity()
    @State private var state = Holder()

    final class Holder {
        var picture: ScreenPicture?
        var frames: EventSubscription?
        var size = CGSize.zero
    }

    var body: some View {
        GeometryReader { geometry in
            RealityView { content in
                content.add(screen)
                state.picture = ScreenPicture(screen: screen, reflection: Entity(), pattern: false)
                let state = state
                state.frames = content.subscribe(to: SceneEvents.Update.self) { _ in state.picture?.check() }
            } update: { _ in
                // the screen fills the view (points to metres)
                guard geometry.size != state.size, geometry.size.width > 0 else { return }
                state.size = geometry.size
                let w = Float(metrics.convert(geometry.size.width, to: .meters)), h = Float(metrics.convert(geometry.size.height, to: .meters))
                if var model = screen.components[ModelComponent.self] {
                    model.mesh = .generatePlane(width: w, height: h)
                    screen.components.set(model)
                }
            }
        }
        .onDisappear { state.picture?.release() }
    }
}

/// The app was ended in the background (the system needed the memory, or the headset was off a long
/// time): the runtime wrote a "Last session" state when the app left the front (host.mm), so the next
/// start offers to continue from it. Asked before the runtime starts: it picks the at-start choice.
@Observable final class ResumeOffer {
    static let shared = ResumeOffer()
    private static let key = "wwhd.resumePending"
    var pending = UserDefaults.standard.string(forKey: ResumeOffer.key) == "1"

    func answer(_ resume: Bool) {
        // savestate.cpp: "last" loads the Last session state once a Quest Log is being played;
        // "intro" starts as usual this time (the at-start setting itself is not changed)
        setenv("WWHD_AT_START", resume ? "last" : "intro", 1)
        UserDefaults.standard.set("0", forKey: ResumeOffer.key)
        pending = false
    }
}

struct ResumeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.uturn.forward.circle").font(.system(size: 56))
            Text("Resume where you left off?").font(.largeTitle)
            Text("The app was closed while you were away. Choose your Quest Log on the title screen and the game continues from the moment you left. Your saved games are not changed either way.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            HStack(spacing: 16) {
                Button("Start as Usual") { ResumeOffer.shared.answer(false) }
                Button("Resume") { ResumeOffer.shared.answer(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}

/// The first start with a shader head start compiles it before the game starts (main.cpp): its progress,
/// over the still black game picture.
struct ShaderPreparationView: View {
    @State private var fraction: Double?

    var body: some View {
        ZStack {
            if let fraction {
                VStack(spacing: 16) {
                    Text("Preparing shaders").font(.title)
                    Text("Only the first time: this keeps new areas from stuttering later.")
                        .foregroundStyle(.secondary)
                    ProgressView(value: fraction).frame(maxWidth: 420)
                    Text("\(Int(fraction * 100)) %").monospacedDigit()
                }
                .padding(32)
                .glassBackgroundEffect()
            }
        }
        .task {
            // the runtime reports progress for a few seconds to minutes; nothing to poll after that
            var seen = false
            while !Task.isCancelled {
                var f = 0.0
                if wwhd_visionos_shader_progress(&f) != 0 {
                    seen = true
                    fraction = f
                } else {
                    fraction = nil
                    if seen { break }
                }
                try? await Task.sleep(for: .milliseconds(250))
                if !seen, Date().timeIntervalSince(started) > 30 { break }
            }
        }
    }

    private let started = Date()
}

/// Tells WindowOpener when Start (+, Menu) or − (Options) is pressed on any game controller. The runtime
/// polls the controllers itself; this only watches the two buttons.
final class ControllerButtonWatcher {
    static let shared = ControllerButtonWatcher()

    private init() {
        for c in GCController.controllers() { watch(c) }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.watch(c) }
        }
    }

    private func watch(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        pad.buttonMenu.pressedChangedHandler = { _, _, pressed in
            if pressed { DispatchQueue.main.async { WindowOpener.shared.buttonPressed(start: true) } }
        }
        pad.buttonOptions?.pressedChangedHandler = { _, _, pressed in
            if pressed { DispatchQueue.main.async { WindowOpener.shared.buttonPressed(start: false) } }
        }
    }
}

struct GamePadWindow: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    private let tv = TVWindowState.shared
    private let state = GamePadWindowState.shared

    var body: some View {
        content
            // a closed window may keep its view: follow the window itself
            .onAppear {
                state.open = true
                if !tv.open { register() }
            }
            .onDisappear { state.open = false }
            .onChange(of: scenePhase) { _, phase in state.open = phase != .background }
            // the TV window closed: its openWindow action may go with it, use this window's
            .onChange(of: tv.open) { _, open in if !open { register() } }
    }

    // In full screen this one window carries the full-screen controls under the GamePad picture, or only
    // the controls (the picture collapsed); otherwise the GamePad picture with its buttons.
    @ViewBuilder private var content: some View {
        if Theater.shared.active, state.collapsed {
            TheaterControls(inGamePadWindow: true)
        } else {
            GamePadPicture()
                .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: Theater.shared.active ? .top : .center) {
                    if Theater.shared.active { TheaterControls(inGamePadWindow: true).padding(.top, 12) } else { gamepadButtons }
                }
        }
    }

    private var gamepadButtons: some View {
        HStack {
            Button { wwhd_visionos_toggle_settings() } label: { Label("Settings", systemImage: "gearshape") }
            if !tv.open, !Theater.shared.active {
                Button { openWindow(id: "tv", value: TVWindowState.value) } label: { Label("Open TV screen", systemImage: "tv") }
            }
        }
        .labelStyle(.iconOnly)
        .padding(8)
        .glassBackgroundEffect()
    }

    /// The TV window closed: its actions may go with it, use this window's.
    private func register() {
        let opener = WindowOpener.shared
        opener.openWindow = openWindow
        opener.dismissWindow = dismissWindow
        opener.openImmersiveSpace = openImmersiveSpace
        opener.dismissImmersiveSpace = dismissImmersiveSpace
    }
}

/// The GamePad picture: hands its layer to the runtime while it shows (hidden: picture-in-picture).
struct GamePadPicture: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var view = GamePadLayerView()

    var body: some View {
        MetalLayerView { view }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .onAppear { view.attach(true) }
            .onDisappear { view.attach(false) }
            .onChange(of: scenePhase) { _, phase in view.attach(phase != .background) }
    }
}

struct MetalLayerView<V: UIView>: UIViewRepresentable {
    let make: () -> V
    init(_ make: @escaping () -> V) { self.make = make }
    func makeUIView(context: Context) -> V { make() }
    func updateUIView(_ uiView: V, context: Context) {}
}

/// A view backed by a CAMetalLayer whose game controller events go to GameController.framework (the
/// runtime polls the controllers), not to UIKit, which would take A, B and the sticks for its own taps
/// and navigation.
class GameControllerLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let interaction = GCEventInteraction()
        interaction.handledEventTypes = .gamepad
        addInteraction(interaction)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var scale: Double { traitCollection.displayScale > 0 ? Double(traitCollection.displayScale) : 2 }
}

/// The TV picture: starts the runtime when it first appears; a later TV window (one closed and opened
/// again) hands its layer to the running game.
final class GameLayerView: GameControllerLayerView {
    private static var started = false

    /// The window is open (the runtime presents the TV picture here) or closed.
    func attach(_ open: Bool) {
        guard Self.started else { return }
        wwhd_visionos_set_layer(open ? Unmanaged.passUnretained(layer).toOpaque() : nil)
        if open { updateDrawableSize() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !Self.started else { return }
        Self.started = true
        updateDrawableSize()
        wwhd_visionos_set_layer(Unmanaged.passUnretained(layer).toOpaque())
        // let the layout settle (drawable size) before the runtime starts on the main thread
        DispatchQueue.main.async { Self.startRuntime() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        wwhd_visionos_set_drawable_size(Double(bounds.width), Double(bounds.height), scale)
    }

    private static func startRuntime() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        // Documents holds game/ (the extracted game, copied onto the device) and save/; relative paths
        // (logs, captures) resolve there too
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        FileManager.default.changeCurrentDirectoryPath(docs.path)
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("save"), withIntermediateDirectories: true)
        let game = GameLibrary.shared.gameFolder  // checked by GameLibrary before this view exists
        let args = ["wwhd", "--game", game.path, "--save", docs.appendingPathComponent("save").path]
        var cargs = args.map { strdup($0) }
        let result = wwhd_runtime_main(Int32(cargs.count), &cargs)
        print("[visionos] runtime start-up returned \(result)")
    }
}

/// The GamePad screen: a pinch or touch on it is a GamePad touch.
final class GamePadLayerView: GameControllerLayerView {
    /// The window is open (the runtime presents the GamePad screen here) or closed.
    func attach(_ open: Bool) {
        wwhd_visionos_set_drc_layer(open ? Unmanaged.passUnretained(layer).toOpaque() : nil)
        if open { updateDrawableSize() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        wwhd_visionos_set_drc_drawable_size(Double(bounds.width), Double(bounds.height), scale)
    }

    private func touch(_ touches: Set<UITouch>, down: Bool) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        wwhd_visionos_drc_touch(down ? 1 : 0, Double(p.x), Double(p.y), Double(bounds.width), Double(bounds.height))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touch(touches, down: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touch(touches, down: true) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touch(touches, down: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touch(touches, down: false) }
}
