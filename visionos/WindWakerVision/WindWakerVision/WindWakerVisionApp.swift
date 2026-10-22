import AVFoundation
import GameController
import SwiftUI

@main
struct WindWakerVisionApp: App {
    var body: some Scene {
        WindowGroup {
            GameView()
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentSize)
    }
}

struct GameView: UIViewRepresentable {
    func makeUIView(context: Context) -> GameLayerView { GameLayerView() }
    func updateUIView(_ uiView: GameLayerView, context: Context) {}
}

/// A view backed by the CAMetalLayer the runtime presents the game to.
final class GameLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private static var started = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // game controllers go to GameController.framework (the runtime polls them), not to UIKit, which
        // would take A, B and the sticks for its own taps and navigation
        let interaction = GCEventInteraction()
        interaction.handledEventTypes = .gamepad
        addInteraction(interaction)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        wwhd_visionos_set_drawable_size(Double(bounds.width), Double(bounds.height), Double(scale))
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
