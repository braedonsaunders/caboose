import AVFoundation
import CabooseKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A file the phone sends for a request, and whether it stays in sync with an original (a
/// document picked in Files) or is new (a photo, a capture, a scan).
struct BridgeUpload {
    let url: URL
    let name: String
    let synced: Bool
}

struct BridgeMediaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Photos, captures and scans written as files in the format `BridgeMedia` chooses, in a
/// temporary folder the caller removes. Originals keep their bytes, metadata included;
/// conversions keep the metadata and are drawn upright.
enum BridgeMediaExport {
    /// An item from the photo picker: a photo (a Live Photo as its still) or a video.
    static func picked(_ provider: NSItemProvider, media: BridgeMedia, into folder: URL) async throws -> BridgeUpload {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        if let image = types.first(where: { $0.conforms(to: .image) }), let conversion = media.photo(image) {
            let loaded = try await load(provider, type: image, into: folder)
            let suggested = provider.suggestedName ?? loaded.name
            switch conversion {
            case .keep:
                let ext = loaded.url.pathExtension.isEmpty ? image.preferredFilenameExtension ?? "jpg" : loaded.url.pathExtension.lowercased()
                return BridgeUpload(url: loaded.url, name: BridgeMediaName.picked(suggested, fallback: "Photo", fileExtension: ext), synced: false)
            case .convert(let format):
                let output = file(in: folder, fileExtension: format.fileExtension)
                try convertImage(loaded.url, to: format, at: output)
                return BridgeUpload(url: output, name: BridgeMediaName.picked(suggested, fallback: "Photo", fileExtension: format.fileExtension), synced: false)
            }
        }
        if let movie = types.first(where: { $0.conforms(to: .movie) }), media.video(movie) != nil {
            let loaded = try await load(provider, type: movie, into: folder)
            let suggested = provider.suggestedName ?? loaded.name
            return try await self.movie(at: loaded.url, original: movie, media: media, into: folder) {
                BridgeMediaName.picked(suggested, fallback: "Video", fileExtension: $0)
            }
        }
        throw BridgeMediaError("The app doesn’t open this kind of item.")
    }

    /// A photo just taken, in the format the request takes, with the camera's metadata.
    static func photo(_ image: UIImage, metadata: [String: Any], media: BridgeMedia, at date: Date, into folder: URL) throws -> BridgeUpload {
        guard let format = media.imageFormat else { throw BridgeMediaError("The app doesn’t open photos.") }
        guard let drawn = upright(image) else { throw BridgeMediaError("The photo couldn’t be read.") }
        let output = file(in: folder, fileExtension: format.fileExtension)
        try write(drawn, properties: uprightProperties(metadata), as: format, to: output)
        return BridgeUpload(url: output, name: BridgeMediaName.capture(.photo, at: date, fileExtension: format.fileExtension), synced: false)
    }

    /// A video just recorded: the camera's file moved into `folder`, then as `movie`.
    static func recorded(_ url: URL, media: BridgeMedia, at date: Date, into folder: URL) async throws -> BridgeUpload {
        let moved = file(in: folder, fileExtension: url.pathExtension)
        try FileManager.default.moveItem(at: url, to: moved)
        let original = UTType(filenameExtension: url.pathExtension) ?? .quickTimeMovie
        return try await movie(at: moved, original: original, media: media, into: folder) {
            BridgeMediaName.capture(.video, at: date, fileExtension: $0)
        }
    }

    /// A video in `folder`: as it is when the request takes it, else converted. `named`
    /// names it from the extension it is sent with.
    static func movie(at source: URL, original: UTType, media: BridgeMedia, into folder: URL, named: (String) -> String) async throws -> BridgeUpload {
        guard let conversion = media.video(original) else { throw BridgeMediaError("The app doesn’t open videos.") }
        switch conversion {
        case .keep:
            let ext = source.pathExtension.isEmpty ? original.preferredFilenameExtension ?? "mov" : source.pathExtension.lowercased()
            return BridgeUpload(url: source, name: named(ext), synced: false)
        case .convert(let format):
            let output = file(in: folder, fileExtension: format.fileExtension)
            guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetHighestQuality) else {
                throw BridgeMediaError("The video couldn’t be converted.")
            }
            try await session.export(to: output, as: format == .mp4 ? .mp4 : .mov)
            return BridgeUpload(url: output, name: named(format.fileExtension), synced: false)
        }
    }

    /// A scan as one PDF or one image per page.
    static func scan(_ pages: [UIImage], as format: BridgeMedia.ScanFormat, at date: Date, into folder: URL) throws -> [BridgeUpload] {
        switch format {
        case .pdf:
            let output = file(in: folder, fileExtension: "pdf")
            try pdf(pages, to: output)
            return [BridgeUpload(url: output, name: BridgeMediaName.capture(.scan, at: date, fileExtension: "pdf"), synced: false)]
        case .pages(let image):
            var uploads: [BridgeUpload] = []
            for (index, page) in pages.enumerated() {
                guard let drawn = upright(page) else { throw BridgeMediaError("A scanned page couldn’t be read.") }
                let output = file(in: folder, fileExtension: image.fileExtension)
                try write(drawn, properties: [:], as: image, to: output)
                let name = BridgeMediaName.capture(.scan, at: date, page: pages.count > 1 ? index + 1 : nil, fileExtension: image.fileExtension)
                uploads.append(BridgeUpload(url: output, name: name, synced: false))
            }
            return uploads
        }
    }

    // Files ---------------------------------------------------------------------------------

    private static func file(in folder: URL, fileExtension: String) -> URL {
        let base = folder.appendingPathComponent(UUID().uuidString)
        return fileExtension.isEmpty ? base : base.appendingPathExtension(fileExtension)
    }

    /// The provider's file of `type`, copied into `folder` (the provider removes its own when
    /// the handler returns), with the name it had.
    private static func load(_ provider: NSItemProvider, type: UTType, into folder: URL) async throws -> (url: URL, name: String) {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? BridgeMediaError("The item couldn’t be read from Photos."))
                    return
                }
                let copy = file(in: folder, fileExtension: url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: (copy, url.lastPathComponent))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Images --------------------------------------------------------------------------------

    /// `source` re-encoded as `format`, drawn upright, with its metadata.
    private static func convertImage(_ source: URL, to format: BridgeMedia.ImageFormat, at destination: URL) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
            throw BridgeMediaError("The photo couldn’t be read.")
        }
        let index = CGImageSourceGetPrimaryImageIndex(image)
        let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [String: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: max(width, height),
        ]
        guard max(width, height) > 0, let drawn = CGImageSourceCreateThumbnailAtIndex(image, index, options as CFDictionary) else {
            throw BridgeMediaError("The photo couldn’t be converted.")
        }
        try write(drawn, properties: uprightProperties(properties), as: format, to: destination)
    }

    /// Metadata for an image already drawn upright.
    private static func uprightProperties(_ metadata: [String: Any]) -> [String: Any] {
        var properties = metadata
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { properties[key as String] = nil }
        return properties
    }

    private static func write(_ image: CGImage, properties: [String: Any], as format: BridgeMedia.ImageFormat, to destination: URL) throws {
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw BridgeMediaError("This iPhone can’t write \(format.rawValue.uppercased()) images.")
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality as String] = 0.9
        CGImageDestinationAddImage(output, image, options as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw BridgeMediaError("The image couldn’t be written.") }
    }

    /// The image's pixels with its orientation applied.
    private static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }

    /// The pages of a scan as a PDF, each page sized as if scanned at 200 dots per inch (a
    /// letter-size page scans at about 1700 pixels wide), each image JPEG-compressed.
    private static func pdf(_ pages: [UIImage], to url: URL) throws {
        let sizes = pages.map { CGSize(width: $0.size.width * $0.scale * 72 / 200, height: $0.size.height * $0.scale * 72 / 200) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sizes.first ?? CGSize(width: 612, height: 792)))
        try renderer.writePDF(to: url) { context in
            for (page, size) in zip(pages, sizes) {
                let bounds = CGRect(origin: .zero, size: size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                let compressed = page.jpegData(compressionQuality: 0.8).flatMap { UIImage(data: $0) } ?? page
                compressed.draw(in: bounds)
            }
        }
    }
}
