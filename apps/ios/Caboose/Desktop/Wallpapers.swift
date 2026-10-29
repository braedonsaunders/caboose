import CabooseKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Observation
import SwiftUI
import UIKit

/// A curated Unsplash photograph served by Lorem Picsum, or an on-device gradient scene.
struct Wallpaper: Hashable, Identifiable {
    let id: Int
    let name: String
    let author: String?

    init(id: Int, author: String) {
        self.id = id
        self.name = author
        self.author = author
        self.stops = []
        self.accent = Tint(red: 0, green: 0, blue: 0)
        self.angle = 0
    }

    init(id: Int, name: String, stops: [Tint], accent: Tint, angle: Double) {
        self.id = id
        self.name = name
        self.author = nil
        self.stops = stops
        self.accent = accent
        self.angle = angle
    }

    var isPhotograph: Bool { author != nil }

    func url(width: Int, height: Int) -> URL {
        URL(string: "https://picsum.photos/id/\(id)/\(width)/\(height)")!
    }
    /// The base gradient's colours, in order along `angle`.
    let stops: [Tint]
    /// The colour of the glows laid over the base and of the light across it.
    let accent: Tint
    /// The direction the base gradient runs in, in degrees anticlockwise from rightward;
    /// 270 runs top to bottom.
    let angle: Double

    /// An sRGB colour, components 0 to 1.
    struct Tint: Hashable {
        let red: Double, green: Double, blue: Double

        func cgColor(alpha: Double = 1) -> CGColor {
            CGColor(colorSpace: WallpaperRenderer.colorSpace, components: [red, green, blue, alpha])!
        }

        /// Towards white, for a glow lighter than the surface it lies on.
        func lightened(_ amount: Double) -> Tint {
            Tint(red: red + (1 - red) * amount, green: green + (1 - green) * amount, blue: blue + (1 - blue) * amount)
        }
    }

    static func scene(_ id: Int) -> Wallpaper? { (library + generated).first { $0.id == id } }
}

extension Wallpaper {
    /// The original curated landscapes, coasts, mountains and night skies (Unsplash License).
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

    /// Twelve scenes, mid to dark in tone with soft highlights, so glass controls stay legible
    /// over them in light and dark appearance alike.
    static let generated: [Wallpaper] = [
        Wallpaper(id: 1, name: "Dawn", stops: [Tint(red: 0.16, green: 0.14, blue: 0.32), Tint(red: 0.52, green: 0.30, blue: 0.44), Tint(red: 0.88, green: 0.56, blue: 0.46)],
                  accent: Tint(red: 0.98, green: 0.78, blue: 0.46), angle: 262),
        Wallpaper(id: 2, name: "Harbour", stops: [Tint(red: 0.08, green: 0.16, blue: 0.28), Tint(red: 0.14, green: 0.36, blue: 0.46), Tint(red: 0.22, green: 0.50, blue: 0.54)],
                  accent: Tint(red: 0.64, green: 0.80, blue: 0.82), angle: 250),
        Wallpaper(id: 3, name: "Moss", stops: [Tint(red: 0.07, green: 0.15, blue: 0.11), Tint(red: 0.20, green: 0.36, blue: 0.26), Tint(red: 0.40, green: 0.54, blue: 0.38)],
                  accent: Tint(red: 0.74, green: 0.82, blue: 0.48), angle: 290),
        Wallpaper(id: 4, name: "Ember", stops: [Tint(red: 0.20, green: 0.05, blue: 0.08), Tint(red: 0.52, green: 0.18, blue: 0.12), Tint(red: 0.80, green: 0.38, blue: 0.16)],
                  accent: Tint(red: 0.98, green: 0.68, blue: 0.32), angle: 240),
        Wallpaper(id: 5, name: "Glacier", stops: [Tint(red: 0.06, green: 0.12, blue: 0.26), Tint(red: 0.28, green: 0.46, blue: 0.64), Tint(red: 0.60, green: 0.76, blue: 0.86)],
                  accent: Tint(red: 0.88, green: 0.95, blue: 0.98), angle: 280),
        Wallpaper(id: 6, name: "Lavender", stops: [Tint(red: 0.20, green: 0.11, blue: 0.30), Tint(red: 0.42, green: 0.30, blue: 0.56), Tint(red: 0.68, green: 0.54, blue: 0.78)],
                  accent: Tint(red: 0.94, green: 0.74, blue: 0.86), angle: 265),
        Wallpaper(id: 7, name: "Slate", stops: [Tint(red: 0.09, green: 0.10, blue: 0.12), Tint(red: 0.22, green: 0.25, blue: 0.29), Tint(red: 0.38, green: 0.42, blue: 0.48)],
                  accent: Tint(red: 0.72, green: 0.76, blue: 0.80), angle: 300),
        Wallpaper(id: 8, name: "Aurora", stops: [Tint(red: 0.03, green: 0.05, blue: 0.14), Tint(red: 0.05, green: 0.26, blue: 0.30), Tint(red: 0.12, green: 0.52, blue: 0.44)],
                  accent: Tint(red: 0.56, green: 0.34, blue: 0.78), angle: 275),
        Wallpaper(id: 9, name: "Dune", stops: [Tint(red: 0.28, green: 0.16, blue: 0.09), Tint(red: 0.58, green: 0.42, blue: 0.26), Tint(red: 0.84, green: 0.70, blue: 0.48)],
                  accent: Tint(red: 0.98, green: 0.90, blue: 0.74), angle: 255),
        Wallpaper(id: 10, name: "Midnight", stops: [Tint(red: 0.02, green: 0.03, blue: 0.08), Tint(red: 0.05, green: 0.09, blue: 0.22), Tint(red: 0.12, green: 0.18, blue: 0.38)],
                  accent: Tint(red: 0.46, green: 0.58, blue: 0.88), angle: 270),
        Wallpaper(id: 11, name: "Peach", stops: [Tint(red: 0.76, green: 0.36, blue: 0.34), Tint(red: 0.90, green: 0.58, blue: 0.48), Tint(red: 0.98, green: 0.80, blue: 0.64)],
                  accent: Tint(red: 1.00, green: 0.94, blue: 0.84), angle: 285),
        Wallpaper(id: 12, name: "Reef", stops: [Tint(red: 0.03, green: 0.20, blue: 0.26), Tint(red: 0.08, green: 0.42, blue: 0.48), Tint(red: 0.18, green: 0.64, blue: 0.66)],
                  accent: Tint(red: 0.62, green: 0.92, blue: 0.88), angle: 245),
    ]
}

/// Draws a `Wallpaper` at a pixel size: the base gradient and a light across it, three glows
/// placed by a generator seeded with the scene's id, then soft large-scale noise blended in
/// and a trace of fine grain against banding. Core Graphics lays the gradients, Core Image
/// shapes the noise. The same scene comes out the same on every screen, at every size.
enum WallpaperRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: colorSpace, .outputColorSpace: colorSpace])

    static func render(_ wallpaper: Wallpaper, size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard !wallpaper.isPhotograph, width > 0, height > 0, let base = gradients(of: wallpaper, width: width, height: height) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var random = SeededGenerator(seed: wallpaper.id)
        var image = CIImage(cgImage: base)
        if let noise = noise(width: width, height: height, using: &random) {
            let blend = CIFilter.softLightBlendMode()
            blend.inputImage = noise
            blend.backgroundImage = image
            image = blend.outputImage ?? image
        }
        if let grain = grain(in: extent) {
            let blend = CIFilter.softLightBlendMode()
            blend.inputImage = grain
            blend.backgroundImage = image
            image = blend.outputImage ?? image
        }
        return context.createCGImage(image.cropped(to: extent), from: extent)
    }

    /// The base gradient along the scene's angle, a lighter cross light at right angles to it,
    /// and three glows.
    private static func gradients(of wallpaper: Wallpaper, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let size = CGSize(width: width, height: height)
        let long = max(size.width, size.height)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        var random = SeededGenerator(seed: wallpaper.id)

        func span(_ degrees: Double) -> (from: CGPoint, to: CGPoint) {
            let radians = degrees * .pi / 180
            let direction = CGPoint(x: cos(radians), y: sin(radians))
            // Half the picture's extent along the direction, so the ends reach its corners.
            let half = (abs(size.width * direction.x) + abs(size.height * direction.y)) / 2
            return (CGPoint(x: centre.x - direction.x * half, y: centre.y - direction.y * half),
                    CGPoint(x: centre.x + direction.x * half, y: centre.y + direction.y * half))
        }

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: wallpaper.stops.map { $0.cgColor() } as CFArray, locations: nil) {
            let line = span(wallpaper.angle)
            context.drawLinearGradient(gradient, start: line.from, end: line.to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [wallpaper.accent.cgColor(alpha: 0.26), wallpaper.accent.cgColor(alpha: 0)] as CFArray, locations: [0, 0.7]) {
            let line = span(wallpaper.angle + (random.unit() < 0.5 ? 90 : -90))
            context.drawLinearGradient(gradient, start: line.from, end: line.to, options: [.drawsBeforeStartLocation])
        }
        let glows = [wallpaper.accent, wallpaper.stops[wallpaper.stops.count - 1].lightened(0.35), wallpaper.accent]
        for tint in glows {
            let at = CGPoint(x: size.width * (0.15 + 0.7 * random.unit()), y: size.height * (0.15 + 0.7 * random.unit()))
            let radius = long * (0.28 + 0.27 * random.unit())
            let alpha = 0.26 + 0.26 * random.unit()
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: [tint.cgColor(alpha: alpha), tint.cgColor(alpha: 0)] as CFArray, locations: nil) else { continue }
            context.drawRadialGradient(gradient, startCenter: at, startRadius: 0, endCenter: at, endRadius: radius, options: [])
        }
        return context.makeImage()
    }

    /// Grey noise a dozen cells across, blurred at a small size and stretched over the picture:
    /// slow, soft variation like light through cloud, from the scene's own generator.
    private static func noise(width: Int, height: Int, using random: inout SeededGenerator) -> CIImage? {
        let columns = 12, rows = max(2, Int((Double(columns) * Double(height) / Double(width)).rounded()))
        // Soft light with mid grey leaves the base alone; this much either side shades it gently.
        let swing = 0.18
        let cells = (0 ..< columns * rows).map { _ in UInt8(((0.5 + (random.unit() * 2 - 1) * swing) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(cells) as CFData),
              let small = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: columns,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        // Blurring at a quarter of the final size costs a fraction of blurring at full size and looks the same.
        let working = 256.0
        let scale = working / Double(max(width, height))
        let workingExtent = CGRect(x: 0, y: 0, width: Double(width) * scale, height: Double(height) * scale)
        let blurred = CIImage(cgImage: small)
            .transformed(by: CGAffineTransform(scaleX: workingExtent.width / Double(columns), y: workingExtent.height / Double(rows)))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: working / 18)
            .cropped(to: workingExtent)
        return blurred.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
    }

    /// Faint per-pixel grain, so a slow gradient does not band on an 8-bit screen.
    private static func grain(in extent: CGRect) -> CIImage? {
        guard let random = CIFilter.randomGenerator().outputImage else { return nil }
        let grey = CIFilter.colorMatrix()
        grey.inputImage = random
        let weights = CIVector(x: 1 / 3, y: 1 / 3, z: 1 / 3, w: 0)
        grey.rVector = weights
        grey.gVector = weights
        grey.bVector = weights
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        grey.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0.06)
        return grey.outputImage?.cropped(to: extent)
    }
}

/// SplitMix64: a small generator whose sequence depends on its seed alone, so a scene's
/// glows and noise fall the same way on every render.
struct SeededGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// The background of the app and the computer's desktop, the same on the phone and on a TV:
/// the brand gradient, wallpapers that change every quarter hour, one wallpaper, or the
/// owner's own picture (`BackgroundChoice`). Photographs are fetched and scenes are drawn
/// at the display's pixel size (up to 4K) and kept on the phone. The last one shows again
/// at launch before anything loads.
@MainActor @Observable
final class WallpaperStore {
    static let shared = WallpaperStore()

    /// The picture showing now; nil shows the gradient.
    private(set) var image: UIImage?
    /// The library wallpaper showing now, if the picture is one.
    private(set) var current: Wallpaper?
    private(set) var choice: BackgroundChoice
    private var pixelSize = CGSize(width: 3840, height: 2160)
    private var rotation: Timer?
    private var loading: Task<Void, Never>?
    /// Small previews for the picker, kept once fetched or drawn.
    @ObservationIgnored private var thumbnails: [Int: UIImage] = [:]
    @ObservationIgnored private var thumbnailRenders: [Int: Task<UIImage?, Never>] = [:]
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
            if let saved = BackgroundSnapshot.load(from: Self.retainedFile, choice: choice),
               let wallpaper = Wallpaper.scene(saved.id), let picture = UIImage(data: saved.image) {
                current = wallpaper
                image = picture
                return
            }
            // Migrate the previous cache-only storage while its picture still exists.
            guard let saved = UserDefaults.standard.string(forKey: Self.lastKey) else { return }
            let parts = saved.split(separator: " ")
            guard parts.count == 2, let id = Int(parts[0]), let wallpaper = Wallpaper.scene(id),
                  choice.libraryPhoto(current: id) == id,
                  let image = UIImage(contentsOfFile: Self.cacheDirectory.appendingPathComponent(String(parts[1])).path) else { return }
            current = wallpaper
            self.image = image
            retain(image, for: wallpaper)
        }
    }

    /// Starts showing the background for a display of this many pixels. A new size keeps the
    /// wallpaper and loads it at that size.
    func show(pixelSize size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let factor = min(1, 3840 / max(size.width, size.height))
        let bounded = CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
        let changed = bounded != pixelSize
        pixelSize = bounded
        switch choice {
        case .gradient:
            break
        case .custom:
            if image == nil { image = UIImage(contentsOfFile: Self.customFile.path) }
        case .photo(let id):
            // A chosen id the library no longer has moves on to one it does.
            guard let wallpaper = Wallpaper.scene(id) else { next(); break }
            if current?.id != id || image == nil || changed { load(wallpaper) }
        case .rotating:
            if image == nil || current?.isPhotograph != true { next() } else if changed, let current { load(current) }
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
            if let wallpaper = Wallpaper.scene(id) {
                // Keep even the selected preview durably if the full-size download fails.
                if current?.id != id, let preview = thumbnails[id] {
                    retain(preview, for: wallpaper)
                    withAnimation(.easeInOut(duration: 0.6)) { image = preview; current = wallpaper }
                }
                load(wallpaper)
            } else { next() }
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

    /// The desktop's "new wallpaper" control: the next wallpaper, rotating or fixed.
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

    /// A small preview for the picker, fetched or drawn once and kept.
    func thumbnail(_ wallpaper: Wallpaper, size: CGSize) async -> UIImage? {
        if let image = thumbnails[wallpaper.id] { return image }
        let render = thumbnailRenders[wallpaper.id] ?? Task {
            await Self.load(wallpaper, width: Int(size.width), height: Int(size.height))
        }
        thumbnailRenders[wallpaper.id] = render
        let image = await render.value
        thumbnails[wallpaper.id] = image
        thumbnailRenders[wallpaper.id] = nil
        return image
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
            retain(loaded, for: choice)
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

    private static var retainedFile: URL {
        customFile.deletingLastPathComponent().appendingPathComponent("library.plist")
    }

    private func retain(_ image: UIImage, for wallpaper: Wallpaper) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try? BackgroundSnapshot(id: wallpaper.id, image: data).save(to: Self.retainedFile)
    }

    /// The owner's picture lives with the app's data, not its caches, so iOS never purges it.
    private static var customFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Background/custom.jpg")
    }

    private static func fileName(_ wallpaper: Wallpaper, width: Int, height: Int) -> String {
        "\(wallpaper.isPhotograph ? "" : "scene-")\(wallpaper.id)-\(width)x\(height).jpg"
    }

    /// The wallpaper at this size from the cache, else fetched or drawn and kept there.
    private static func load(_ wallpaper: Wallpaper, width: Int, height: Int) async -> UIImage? {
        let caches = cacheDirectory
        let file = caches.appendingPathComponent(fileName(wallpaper, width: width, height: height))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return await image.byPreparingForDisplay() }
        if wallpaper.isPhotograph {
            return await fetchPhotograph(wallpaper, width: width, height: height, file: file)
        }
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let drawn = WallpaperRenderer.render(wallpaper, size: CGSize(width: width, height: height)) else { return nil }
            let image = UIImage(cgImage: drawn)
            if let jpeg = image.jpegData(compressionQuality: 0.9) {
                try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
                try? jpeg.write(to: file, options: .atomic)
            }
            return await image.byPreparingForDisplay()
        }.value
    }

    /// Bound both transfer size and decode size, including responses without Content-Length.
    nonisolated private static func fetchPhotograph(_ wallpaper: Wallpaper, width: Int, height: Int, file: URL) async -> UIImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: wallpaper.url(width: width, height: height))
            let limit = 12 * 1024 * 1024
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https",
                  response.mimeType?.hasPrefix("image/") == true,
                  response.expectedContentLength <= Int64(limit) else { return nil }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { return nil }
                data.append(byte)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
                  sourceWidth > 0, sourceHeight > 0, sourceWidth <= 16384, sourceHeight <= 16384,
                  sourceWidth * sourceHeight <= 40_000_000,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(3840, max(width, height)),
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            try Task.checkCancellation()
            let image = UIImage(cgImage: decoded)
            if let jpeg = image.jpegData(compressionQuality: 0.9) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: file, options: .atomic)
            }
            return await image.byPreparingForDisplay()
        } catch {
            return nil
        }
    }
}

/// The background behind the phone's tabs, edge to edge and under the bars: the owner's
/// choice, the same as the desktop's. Over a wallpaper lies a sheer of the brand gradient so
/// glass controls stay legible over its lightest reaches; with the gradient chosen, or no
/// picture yet, it is the brand gradient alone.
struct ShellBackground: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.shellWallpaperWidth) private var wallpaperWidth
    var store = WallpaperStore.shared

    var body: some View {
        wallpaper
    }

    private var wallpaper: some View {
        GeometryReader { proxy in
            let size = CGSize(width: max(proxy.size.width, wallpaperWidth), height: proxy.size.height)
            ZStack {
                Backdrop()
                if let image = store.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .id(store.current?.id ?? -1)
                        .transition(.opacity)
                    Backdrop().opacity(0.38)
                    LinearGradient(colors: [.black.opacity(0.22), .clear, .clear, .black.opacity(0.3)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            // The TV, when one is connected, sets the size wallpapers are drawn at.
            .onAppear { if !model.externalDisplayActive { store.show(pixelSize: pixels(size)) } }
            .onChange(of: size) { _, size in if !model.externalDisplayActive { store.show(pixelSize: pixels(size)) } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !model.externalDisplayActive { store.show(pixelSize: pixels(size)) }
            }
        }
        .ignoresSafeArea()
    }

    private func pixels(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// The background behind a TV's desktop: the same choice, with the gradient until a
/// wallpaper is drawn.
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
            // Keeps white title text and the dock legible over the lightest scenes.
            LinearGradient(colors: [.black.opacity(0.18), .clear, .clear, .black.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
    }
}
