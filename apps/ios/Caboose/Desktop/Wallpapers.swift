import CabooseKit
import Observation
import SwiftUI
import UIKit

/// A photograph from the Unsplash library, served at any size by Lorem Picsum.
struct Wallpaper: Hashable {
    let id: Int
    let author: String

    func url(width: Int, height: Int) -> URL {
        URL(string: "https://picsum.photos/id/\(id)/\(width)/\(height)")!
    }
}

extension Wallpaper {
    /// Landscapes, coasts, mountains and night skies, each at least 3800 px wide, chosen by
    /// hand from the Lorem Picsum catalog (Unsplash License).
    static let library: [Wallpaper] = [
        Wallpaper(id: 29, author: "Go Wild"),
        Wallpaper(id: 110, author: "Kenneth Thewissen"),
        Wallpaper(id: 128, author: "Matteo Minelli"),
        Wallpaper(id: 184, author: "Tim de Groot"),
        Wallpaper(id: 218, author: "Monika Majkowska"),
        Wallpaper(id: 231, author: "Aleksandra Boguslawska"),
        Wallpaper(id: 235, author: "Paul E. Harrer"),
        Wallpaper(id: 287, author: "Aleksandra Boguslawska"),
        Wallpaper(id: 323, author: "Paweł Wojciechowski"),
        Wallpaper(id: 327, author: "Ryan Schroeder"),
        Wallpaper(id: 374, author: "Ma. Alejandra"),
        Wallpaper(id: 381, author: "Nick West"),
        Wallpaper(id: 386, author: "Topich"),
        Wallpaper(id: 392, author: "Chris Brignola"),
        Wallpaper(id: 412, author: "Samuel Rohl"),
        Wallpaper(id: 426, author: "Ales Krivec"),
        Wallpaper(id: 434, author: "Ales Krivec"),
        Wallpaper(id: 450, author: "Tanvi Malik"),
        Wallpaper(id: 465, author: "Paula Vermeulen"),
        Wallpaper(id: 477, author: "Jasper van der Meij"),
        Wallpaper(id: 482, author: "Danny Froese"),
        Wallpaper(id: 507, author: "Jeff Sheldon"),
        Wallpaper(id: 509, author: "Jeff Sheldon"),
        Wallpaper(id: 511, author: "Jeff Sheldon"),
        Wallpaper(id: 523, author: "Harman Abiwardani"),
        Wallpaper(id: 525, author: "Luca Zanon"),
        Wallpaper(id: 547, author: "Tomasz Paciorek"),
        Wallpaper(id: 558, author: "Ales Krivec"),
        Wallpaper(id: 563, author: "Bec Brown"),
        Wallpaper(id: 667, author: "Joshua Sortino"),
        Wallpaper(id: 676, author: "Drew Patrick Miller"),
        Wallpaper(id: 678, author: "Samuel Zeller"),
        Wallpaper(id: 684, author: "Lee Roylland"),
        Wallpaper(id: 688, author: "Benjamin Sloth Lindgreen"),
        Wallpaper(id: 693, author: "Rob Bye"),
        Wallpaper(id: 702, author: "Dominik Schröder"),
        Wallpaper(id: 715, author: "Leah Tardivel"),
        Wallpaper(id: 724, author: "Nelly Volkovich"),
        Wallpaper(id: 830, author: "Luca Zanon"),
        Wallpaper(id: 866, author: "Samuel Zeller"),
        Wallpaper(id: 867, author: "Stefanus Martanto Setyo Husodo"),
        Wallpaper(id: 871, author: "Stefan Kunze"),
        Wallpaper(id: 872, author: "Brandon Lam"),
        Wallpaper(id: 894, author: "Paula Porto"),
        Wallpaper(id: 896, author: "Jenna Beekhuis"),
        Wallpaper(id: 903, author: "Greg Rakozy"),
        Wallpaper(id: 905, author: "Caitlin Wynne"),
        Wallpaper(id: 906, author: "Andras Toth"),
        Wallpaper(id: 910, author: "Sudarshan Bhat"),
        Wallpaper(id: 916, author: "Larry Chen"),
        Wallpaper(id: 974, author: "Greg Rakozy"),
        Wallpaper(id: 980, author: "Ales Krivec"),
        Wallpaper(id: 984, author: "Sylvain Guiheneuc"),
        Wallpaper(id: 987, author: "Sebastien Gabriel"),
        Wallpaper(id: 1015, author: "Alexey Topolyanskiy"),
        Wallpaper(id: 1016, author: "Philippe Wuyts"),
        Wallpaper(id: 1018, author: "Andrew Ridley"),
        Wallpaper(id: 1022, author: "Vashishtha Jogi"),
        Wallpaper(id: 1035, author: "Jared Erondu"),
        Wallpaper(id: 1036, author: "Wolfgang Lutz"),
        Wallpaper(id: 1039, author: "Andrew Coelho"),
        Wallpaper(id: 1040, author: "Rachel Davis"),
        Wallpaper(id: 1043, author: "Christian Joudrey"),
        Wallpaper(id: 1050, author: "Joseph Barrientos"),
        Wallpaper(id: 1052, author: "Annie Spratt"),
        Wallpaper(id: 1057, author: "Stefan Kunze"),
        Wallpaper(id: 1064, author: "Olivier Miche"),
    ]
}

/// The background of the app and the computer's desktop, the same on the phone and on a TV:
/// the brand gradient, photographs that change every quarter hour, one photograph, or the
/// owner's own picture (`BackgroundChoice`). Photographs are fetched at the display's own pixel
/// size and kept on the phone, and the last one shows again at launch before anything loads.
@MainActor @Observable
final class WallpaperStore {
    static let shared = WallpaperStore()

    /// The photograph showing now; nil shows the gradient.
    private(set) var image: UIImage?
    /// The library photograph showing now, if the image is one.
    private(set) var current: Wallpaper?
    private(set) var choice: BackgroundChoice
    private var pixelSize = CGSize(width: 3840, height: 2160)
    private var rotation: Timer?
    private var loading: Task<Void, Never>?
    private static let lastKey = "caboose.wallpaper.last"
    private static let choiceKey = "caboose.background"

    init() {
        choice = UserDefaults.standard.data(forKey: Self.choiceKey).flatMap { try? JSONDecoder().decode(BackgroundChoice.self, from: $0) } ?? .rotating
        switch choice {
        case .gradient:
            break
        case .custom:
            image = UIImage(contentsOfFile: Self.customFile.path)
        case .rotating, .photo:
            // The last photograph, from the cache, so a screen that shows it never starts black.
            guard let saved = UserDefaults.standard.string(forKey: Self.lastKey) else { return }
            let parts = saved.split(separator: " ")
            guard parts.count == 2, let id = Int(parts[0]), let wallpaper = Wallpaper.library.first(where: { $0.id == id }),
                  let image = UIImage(contentsOfFile: Self.cacheDirectory.appendingPathComponent(String(parts[1])).path) else { return }
            current = wallpaper
            self.image = image
        }
    }

    /// Starts showing the background for a display of this many pixels. A new size keeps the
    /// photograph and fetches it at that size.
    func show(pixelSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = size != pixelSize
        pixelSize = size
        switch choice {
        case .gradient, .custom:
            break
        case .photo(let id):
            if current?.id != id || image == nil || changed, let wallpaper = Wallpaper.library.first(where: { $0.id == id }) { load(wallpaper) }
        case .rotating:
            if image == nil || current == nil { next() } else if changed, let current { load(current) }
        }
        scheduleRotation()
    }

    func stop() {
        rotation?.invalidate()
        rotation = nil
    }

    /// Chooses the background, for the app and the desktop at once.
    func choose(_ choice: BackgroundChoice) {
        self.choice = choice
        if let data = try? JSONEncoder().encode(choice) { UserDefaults.standard.set(data, forKey: Self.choiceKey) }
        loading?.cancel()
        switch choice {
        case .gradient:
            withAnimation(.easeInOut(duration: 0.6)) { image = nil; current = nil }
        case .custom:
            withAnimation(.easeInOut(duration: 0.6)) { image = UIImage(contentsOfFile: Self.customFile.path); current = nil }
        case .photo(let id):
            if let wallpaper = Wallpaper.library.first(where: { $0.id == id }) { load(wallpaper) }
        case .rotating:
            next()
        }
        scheduleRotation()
    }

    /// Makes the owner's own picture the background, scaled to at most 4K and kept on the phone.
    func useCustom(_ data: Data) async throws {
        guard let picture = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let longest = max(picture.size.width, picture.size.height)
        let scale = min(1, 3840 / max(1, longest))
        let size = CGSize(width: (picture.size.width * scale).rounded(), height: (picture.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in picture.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.88) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: Self.customFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: Self.customFile, options: .atomic)
        choose(.custom)
    }

    /// The desktop's "new photograph" control: the next photograph, rotating or fixed.
    func next() {
        let pick = Wallpaper.library.filter { $0 != current }.randomElement() ?? Wallpaper.library[0]
        let chosen = choice.next(choosing: pick.id)
        if chosen != choice {
            choice = chosen
            if let data = try? JSONEncoder().encode(chosen) { UserDefaults.standard.set(data, forKey: Self.choiceKey) }
            scheduleRotation()
        }
        load(pick)
    }

    private func scheduleRotation() {
        rotation?.invalidate()
        rotation = nil
        guard choice.rotates else { return }
        rotation = Timer.scheduledTimer(withTimeInterval: BackgroundChoice.rotationInterval, repeats: true) { _ in
            Task { @MainActor in WallpaperStore.shared.next() }
        }
    }

    private func load(_ choice: Wallpaper) {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        loading?.cancel()
        loading = Task {
            guard let loaded = await Self.load(choice, width: width, height: height), !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                image = loaded
                current = choice
            }
            UserDefaults.standard.set("\(choice.id) \(Self.fileName(choice, width: width, height: height))", forKey: Self.lastKey)
        }
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Wallpapers")
    }

    /// The owner's picture lives with the app's data, not its caches, so iOS never purges it.
    private static var customFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Background/custom.jpg")
    }

    private static func fileName(_ wallpaper: Wallpaper, width: Int, height: Int) -> String { "\(wallpaper.id)-\(width)x\(height).jpg" }

    private static func load(_ wallpaper: Wallpaper, width: Int, height: Int) async -> UIImage? {
        let caches = cacheDirectory
        let file = caches.appendingPathComponent(fileName(wallpaper, width: width, height: height))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return await image.byPreparingForDisplay() }
        do {
            let (data, response) = try await URLSession.shared.data(from: wallpaper.url(width: width, height: height))
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return await image.byPreparingForDisplay()
        } catch {
            return nil
        }
    }
}

/// The background behind the phone's tabs, edge to edge and under the bars: the owner's
/// choice, the same as the desktop's. Over a photograph lies a sheer of the brand gradient so
/// glass controls stay legible over a bright sky or snow; with the gradient chosen, or no
/// photograph yet, it is the brand gradient alone.
struct ShellBackground: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    var store = WallpaperStore.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Backdrop()
                if let image = store.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(store.current?.id ?? -1)
                        .transition(.opacity)
                    Backdrop().opacity(0.38)
                    LinearGradient(colors: [.black.opacity(0.22), .clear, .clear, .black.opacity(0.3)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            // The TV, when one is connected, sets the size photographs are fetched at.
            .onAppear { if !model.externalDisplayActive { store.show(pixelSize: pixels(proxy.size)) } }
            .onChange(of: proxy.size) { _, size in if !model.externalDisplayActive { store.show(pixelSize: pixels(size)) } }
        }
        .ignoresSafeArea()
    }

    private func pixels(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// The background behind a TV's desktop: the same choice, with the gradient until a
/// photograph arrives.
struct WallpaperView: View {
    let store: WallpaperStore

    var body: some View {
        ZStack {
            Backdrop()
            if let image = store.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .id(store.current?.id ?? -1)
                    .transition(.opacity)
            }
            // Keeps white title text and the dock legible over a bright sky or snow.
            LinearGradient(colors: [.black.opacity(0.18), .clear, .clear, .black.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
    }
}
