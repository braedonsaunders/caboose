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

    /// Takes the open windows' pictures now, while the display still holds them.
    func capture(_ model: AppModel) {
        guard let key = model.credentials?.fileDomainIdentifier else { return }
        let running = model.phase == .ready
        var frames: [Frame] = []
        var images: [Int: UIImage] = [:]
        if running {
            for window in model.appWindows.prefix(Self.limit) {
                guard let picture = window.surface.snapshot() else { continue }
                frames.append(Frame(id: window.id, title: window.title, app: model.appName(for: window),
                                    width: window.frame.width, height: window.frame.height))
                images[window.id] = Self.scaled(picture)
            }
        }
        guard let directory = directory(for: key) else { return }
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

    /// Small enough for a tile on any phone at 3×, and for eight of them to load at once.
    private static func scaled(_ picture: CGImage) -> UIImage {
        let longest: CGFloat = 640
        let width = CGFloat(picture.width), height = CGFloat(picture.height)
        let scale = min(1, longest / max(width, height))
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: picture).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
