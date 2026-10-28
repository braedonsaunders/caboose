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

/// The desktop's photograph, the same one on a TV and on the phone: a new one every quarter
/// hour or on request, fetched at the display's own pixel size and kept on the phone so a
/// repeat costs nothing. The last one shows again at launch, before anything loads.
@MainActor @Observable
final class WallpaperStore {
    static let shared = WallpaperStore()

    private(set) var image: UIImage?
    private(set) var current: Wallpaper?
    private var pixelSize = CGSize(width: 3840, height: 2160)
    private var rotation: Timer?
    private var loading: Task<Void, Never>?
    private static let lastKey = "caboose.wallpaper.last"

    init() {
        // The last photograph, from the cache, so a screen that shows it never starts black.
        guard let saved = UserDefaults.standard.string(forKey: Self.lastKey) else { return }
        let parts = saved.split(separator: " ")
        guard parts.count == 2, let id = Int(parts[0]), let wallpaper = Wallpaper.library.first(where: { $0.id == id }),
              let image = UIImage(contentsOfFile: Self.cacheDirectory.appendingPathComponent(String(parts[1])).path) else { return }
        current = wallpaper
        self.image = image
    }

    /// Starts showing photographs for a display of this many pixels. A new size keeps the
    /// photograph and fetches it at that size.
    func show(pixelSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = size != pixelSize
        pixelSize = size
        if image == nil || current == nil { next() } else if changed, let current { load(current) }
        rotation?.invalidate()
        rotation = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in WallpaperStore.shared.next() }
        }
    }

    func stop() {
        rotation?.invalidate()
        rotation = nil
    }

    /// A different photograph, chosen at random.
    func next() {
        load(Wallpaper.library.filter { $0 != current }.randomElement() ?? Wallpaper.library[0])
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

/// The photograph behind the phone's tabs, edge to edge and under the bars, with a sheer of the
/// brand's gradient so glass controls stay legible over a bright sky or snow. It follows the
/// same photograph the TV shows; with none yet, it is the brand gradient alone.
struct ShellWallpaper: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let store: WallpaperStore

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Backdrop()
                if let image = store.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(store.current)
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

/// The photograph behind the desktop, with the gradient backdrop until one arrives.
struct WallpaperView: View {
    let store: WallpaperStore

    var body: some View {
        ZStack {
            Backdrop()
            if let image = store.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .id(store.current)
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
