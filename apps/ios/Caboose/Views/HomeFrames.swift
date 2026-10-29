import CabooseKit
import SwiftUI

/// The last picture of each open window, kept on the phone so Home can show the computer as
/// it was while it is parked, waking or out of reach. Taken as the app leaves the screen and
/// before a park, in the order the windows were last used, and replaced each time; forgotten
/// when the running computer has no windows (`HomeToday.keptUpdate`). They are pictures
/// only, never a window's identity: a window id kept from before may name another app's
/// window after a cold boot. Stored in Caches per computer, written in the order taken; the
/// system may clear them, and Home then shows no strip until the computer runs again.
@MainActor @Observable
final class HomeFrames {
    static let shared = HomeFrames()
    static let limit = 8

    struct Frame: Codable, Identifiable, Equatable {
        let id: Int
        let title: String
        let app: String
        let width: Double
        let height: Double
    }

    /// Writes one after another, so a park's pictures never land under older ones.
    private static let writer = DispatchQueue(label: "caboose.home-frames", qos: .utility)

    private struct Manifest: Codable {
        var takenAt: Date
        var frames: [Frame]
    }

    private(set) var frames: [Frame] = []
    private(set) var takenAt: Date?
    private(set) var images: [Int: UIImage] = [:]
    private var computer: String?

    /// Reads what was kept for `computer` (its file domain), once per computer.
    func load(for computer: String?) {
        guard computer != self.computer else { return }
        self.computer = computer
        frames = []
        images = [:]
        takenAt = nil
        guard let directory = directory(for: computer),
              let data = try? Data(contentsOf: directory.appending(path: "frames.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        frames = manifest.frames
        takenAt = manifest.takenAt
        for frame in manifest.frames {
            if let image = UIImage(contentsOfFile: directory.appending(path: "\(frame.id).jpg").path) { images[frame.id] = image }
        }
    }

    /// Which capture is the latest; an earlier one still gathering its pictures stands down.
    private var captureEpoch = 0

    /// Takes the open windows' pictures now, while the display still holds them. The pictures
    /// are reduced on the GPU and arrive off the main thread, so leaving the screen never
    /// waits for a full-size readback of every window.
    func capture(_ model: AppModel) {
        guard let key = model.credentials?.fileDomainIdentifier, let directory = directory(for: key) else { return }
        let running = model.phase == .ready
        captureEpoch += 1
        let epoch = captureEpoch
        guard running else {
            keep(key: key, directory: directory, running: false, frames: [], images: [:])
            return
        }
        let windows = Array(model.appWindows.prefix(Self.limit))
        let frames = windows.map { window in
            Frame(id: window.id, title: window.title, app: model.appName(for: window),
                  width: window.frame.width, height: window.frame.height)
        }
        let surfaces = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.surface) })
        WindowSurface.snapshots(of: surfaces, longEdgeAtMost: Self.longestEdge) { [weak self] pictures in
            Task { @MainActor in
                guard let self, self.captureEpoch == epoch else { return }
                self.keep(key: key, directory: directory, running: true,
                          frames: frames.filter { pictures[$0.id] != nil },
                          images: pictures.mapValues { UIImage(cgImage: $0) })
            }
        }
    }

    /// Small enough for a tile on any phone at 3×, and for eight of them to load at once.
    private static let longestEdge = 640

    private func keep(key: String, directory: URL, running: Bool, frames: [Frame], images: [Int: UIImage]) {
        switch HomeToday.keptUpdate(running: running, pictures: frames.count) {
        case .leave:
            return
        case .clear:
            computer = key
            self.frames = []
            self.images = [:]
            takenAt = nil
            Self.writer.async { try? FileManager.default.removeItem(at: directory) }
        case .replace:
            computer = key
            self.frames = frames
            self.images = images
            let manifest = Manifest(takenAt: Date(), frames: frames)
            takenAt = manifest.takenAt
            let jpegs = images.compactMapValues { $0.jpegData(compressionQuality: 0.72) }
            Self.writer.async {
                let files = FileManager.default
                try? files.removeItem(at: directory)
                try? files.createDirectory(at: directory, withIntermediateDirectories: true)
                for (id, data) in jpegs { try? data.write(to: directory.appending(path: "\(id).jpg")) }
                if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: directory.appending(path: "frames.json")) }
            }
        }
    }

    private func directory(for computer: String?) -> URL? {
        guard let computer, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appending(path: "HomeFrames", directoryHint: .isDirectory).appending(path: computer, directoryHint: .isDirectory)
    }
}
