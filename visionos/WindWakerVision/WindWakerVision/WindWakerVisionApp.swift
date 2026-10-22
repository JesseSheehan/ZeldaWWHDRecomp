import AVFoundation
import GameController
import SwiftUI

@main
struct WindWakerVisionApp: App {
    var body: some Scene {
        // the TV picture (and the settings overlay)
        WindowGroup(id: "tv") {
            TVWindow()
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
    }
}

/// Whether the GamePad window is open (its view is in a window).
@Observable final class GamePadWindowState {
    static let shared = GamePadWindowState()
    static let value = "gamepad"
    var open = false
}

struct TVWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private let gamepad = GamePadWindowState.shared

    var body: some View {
        MetalLayerView { GameLayerView() }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .onAppear {
                openGamePad()
                // Start (+) brings the GamePad window back: the game shows its menus there
                StartButtonWatcher.shared.onPress = { [openWindow] in
                    if !GamePadWindowState.shared.open { openWindow(id: "gamepad", value: GamePadWindowState.value) }
                }
            }
            .ornament(attachmentAnchor: .scene(.bottom)) {
                HStack {
                    Button { wwhd_visionos_toggle_settings() } label: { Label("Settings", systemImage: "gearshape") }
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

/// Calls onPress when Start (+, Menu) is pressed on any game controller. The runtime polls the controllers
/// itself; this only watches the button.
final class StartButtonWatcher {
    static let shared = StartButtonWatcher()
    var onPress: (() -> Void)?

    private init() {
        for c in GCController.controllers() { watch(c) }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.watch(c) }
        }
    }

    private func watch(_ c: GCController) {
        c.extendedGamepad?.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { DispatchQueue.main.async { self?.onPress?() } }
        }
    }
}

struct GamePadWindow: View {
    var body: some View {
        MetalLayerView { GamePadLayerView() }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .ornament(attachmentAnchor: .scene(.bottom)) {
                Button { wwhd_visionos_toggle_settings() } label: { Label("Settings", systemImage: "gearshape") }
                    .labelStyle(.iconOnly)
                    .padding(8)
                    .glassBackgroundEffect()
            }
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

/// The TV picture: starts the runtime when it first appears.
final class GameLayerView: GameControllerLayerView {
    private static var started = false

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
        let game = docs.appendingPathComponent("game")
        guard FileManager.default.fileExists(atPath: game.appendingPathComponent("code/cking.rpx").path) else {
            print("[visionos] no game data at \(game.path) (copy data/game there)")
            return
        }
        let args = ["wwhd", "--game", game.path, "--save", docs.appendingPathComponent("save").path]
        var cargs = args.map { strdup($0) }
        let result = wwhd_runtime_main(Int32(cargs.count), &cargs)
        print("[visionos] runtime start-up returned \(result)")
    }
}

/// The GamePad screen: a pinch or touch on it is a GamePad touch.
final class GamePadLayerView: GameControllerLayerView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            wwhd_visionos_set_drc_layer(Unmanaged.passUnretained(layer).toOpaque())
            updateDrawableSize()
        } else {
            wwhd_visionos_set_drc_layer(nil)  // closed: picture-in-picture in the TV window
        }
        GamePadWindowState.shared.open = window != nil
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
