import SwiftUI
import UniformTypeIdentifiers

/// The game in the app's Documents/game: checked against the version the app was built for, and
/// imported from a folder the player picks (Files: iCloud Drive, On My Apple Vision Pro, a server...).
@Observable final class GameLibrary {
    static let shared = GameLibrary()

    enum State: Equatable {
        case missing(String)                 // no usable game; why
        case importing(Double, String)       // progress 0..1, what is being copied
        case ready
    }
    var state: State = .missing("")

    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var gameFolder: URL { documents.appendingPathComponent("game") }
    let buildName = String(cString: wwhd_visionos_build_name())
    let buildTitle = String(cString: wwhd_visionos_build_title_id())

    private init() { check() }

    /// Documents/game holds the version of the game this app was built for.
    func check() {
        if let problem = problem(in: gameFolder) {
            state = .missing(FileManager.default.fileExists(atPath: gameFolder.path) ? problem : "")
        } else {
            state = .ready
        }
    }

    /// nil when `folder` is a game folder of the right version, otherwise what is wrong with it.
    func problem(in folder: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("code/cking.rpx").path),
              fm.fileExists(atPath: folder.appendingPathComponent("content").path) else {
            return "\(folder.lastPathComponent) is not an extracted game folder: it needs code/cking.rpx, content/ and meta/."
        }
        guard let meta = try? String(contentsOf: folder.appendingPathComponent("meta/meta.xml"), encoding: .utf8),
              let title = meta.range(of: #"(?<=<title_id[^>]{0,64}>)[0-9A-Fa-f]{16}"#, options: .regularExpression) else {
            return "\(folder.lastPathComponent) has no meta/meta.xml with the game's title id."
        }
        let found = meta[title].uppercased()
        if found != buildTitle.uppercased() {
            return "This app was built for the \(buildName) version of the game (title \(buildTitle)); the folder holds title \(found). Rebuild the app from that folder's code/cking.rpx (tools/visionos/build.sh), or import the \(buildName) version."
        }
        return nil
    }

    /// Copies the picked folder (or its game/ subfolder) into Documents/game.
    func importGame(from picked: URL) {
        let scoped = picked.startAccessingSecurityScopedResource()
        var source = picked
        if problem(in: source) != nil, problem(in: picked.appendingPathComponent("game")) == nil {
            source = picked.appendingPathComponent("game")
        }
        if let problem = problem(in: source) {
            if scoped { picked.stopAccessingSecurityScopedResource() }
            state = .missing(problem)
            return
        }
        state = .importing(0, "Preparing")
        let destination = gameFolder
        let staging = documents.appendingPathComponent("game.importing")
        Task.detached(priority: .userInitiated) {
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            do {
                try Self.copy(source, to: staging) { done, name in
                    Task { @MainActor in GameLibrary.shared.state = .importing(done, name) }
                }
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: staging, to: destination)
                await MainActor.run { GameLibrary.shared.check() }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run { GameLibrary.shared.state = .missing("Import failed: \(error.localizedDescription)") }
            }
        }
    }

    /// File-by-file copy with progress by bytes (the game is about 1.7 GB in over a thousand files).
    private static func copy(_ source: URL, to destination: URL, progress: @escaping (Double, String) -> Void) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int)] = []
        var total = 0
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true { continue }
            files.append((url, values.fileSize ?? 0))
            total += values.fileSize ?? 0
        }
        let base = source.standardizedFileURL.path
        var done = 0
        var lastReport = Date.distantPast
        for (url, size) in files {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: target)
            done += size
            if Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                progress(total > 0 ? Double(done) / Double(total) : 1, relative)
            }
        }
        progress(1, "Done")
    }
}

/// First run (or a game that does not fit): what is needed, and the folder picker.
struct ImportView: View {
    private let library = GameLibrary.shared
    @State private var picking = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sailboat").font(.system(size: 56))
            Text("No game found").font(.largeTitle)
            switch library.state {
            case .importing(let done, let name):
                ProgressView(value: done) { Text("Importing your game…") } currentValueLabel: { Text(name).lineLimit(1) }
                    .frame(maxWidth: 480)
            case .missing(let problem):
                Text("Import your game folder: the extracted \(library.buildName) version of The Wind Waker HD, with code, content and meta inside (tools/visionos/build.sh leaves it in build-visionos/game). Put it in iCloud Drive or another Files location, then choose it here.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                if !problem.isEmpty {
                    Text(problem).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 560)
                }
                Button("Import Game Folder…") { picking = true }
                    .buttonStyle(.borderedProminent)
            case .ready:
                EmptyView()
            }
        }
        .padding(40)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.importGame(from: url) }
        }
    }
}
