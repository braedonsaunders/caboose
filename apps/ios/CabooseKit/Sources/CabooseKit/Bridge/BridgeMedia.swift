import Foundation
import UniformTypeIdentifiers

/// Where the file for a Linux application's Open dialog can come from on the phone.
public enum BridgeSource: String, CaseIterable, Sendable, Identifiable {
    /// The document picker: iCloud Drive, the computer and every other location.
    case files
    /// Photos, through the system photo picker.
    case photos
    /// A new photo or video.
    case camera
    /// The document scanner.
    case scan

    public var id: String { rawValue }
}

/// The phone's own media as files a request accepts (docs/native-bridge.md § Open and Save):
/// which sources apply to a request, and the format each one produces.
///
/// A request accepts a type by name when a filter lists it (`*.jpg`, `image/jpeg`), and as
/// anything when a filter is a wildcard (`*`, `*/*`), there are no filters, or a filter names
/// the type's family (`image/*`, `video/*`) or a broad type (`application/octet-stream`). An original is kept when it is accepted by name,
/// or accepted as anything and widely readable (JPEG, PNG, GIF, TIFF, BMP; QuickTime, MPEG-4);
/// otherwise it is converted to the first format accepted by name, else to the first accepted
/// at all (JPEG, then PNG, HEIC, TIFF for images; MPEG-4, then QuickTime for videos).
public struct BridgeMedia: Equatable, Sendable {
    public enum ImageFormat: String, CaseIterable, Sendable {
        case jpeg, png, heic, tiff

        public var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .tiff: .tiff
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .heic: "heic"
            case .tiff: "tiff"
            }
        }
    }

    public enum MovieFormat: String, CaseIterable, Sendable {
        case mp4, mov

        public var type: UTType { self == .mp4 ? .mpeg4Movie : .quickTimeMovie }
        public var fileExtension: String { rawValue }
    }

    /// What a scan becomes: one PDF of every page, or one image per page.
    public enum ScanFormat: Equatable, Sendable {
        case pdf
        case pages(ImageFormat)

        public var fileExtension: String {
            switch self {
            case .pdf: "pdf"
            case .pages(let format): format.fileExtension
            }
        }
    }

    /// What happens to an item that already has a type: sent as it is, or converted.
    public enum Conversion<Format: Equatable & Sendable>: Equatable, Sendable {
        case keep
        case convert(Format)
    }

    /// How a request accepts one type.
    public enum Acceptance: Int, Comparable, Sendable {
        case no, any, named
        public static func < (a: Acceptance, b: Acceptance) -> Bool { a.rawValue < b.rawValue }
    }

    private static let broad: [UTType] = [.item, .data, .content, .compositeContent, .image, .movie, .video, .audiovisualContent, .audio, .text]
    private static let portableImages: [UTType] = [.jpeg, .png, .gif, .tiff, .bmp]
    private static let portableMovies: [UTType] = [.quickTimeMovie, .mpeg4Movie]

    /// The filters that decide: the current one, else all of them.
    public let filters: [BridgeRequest.Filter]

    public init(_ request: BridgeRequest) {
        filters = request.currentFilter.map { [request.filters[$0]] } ?? request.filters
    }

    public init(filters: [BridgeRequest.Filter]) { self.filters = filters }

    public func acceptance(of type: UTType) -> Acceptance {
        if filters.isEmpty { return .any }
        var best = Acceptance.no
        for filter in filters {
            if filter.mimeTypes.contains("*/*") || filter.patterns.contains("*") || filter.patterns.contains("*.*") { best = max(best, .any) }
            for mime in filter.mimeTypes where mime.hasSuffix("/*") {
                if let family = Self.family(String(mime.dropLast(2))), type.conforms(to: family) { best = max(best, .any) }
            }
            let named: [UTType] = filter.mimeTypes.filter { !$0.hasSuffix("/*") }.compactMap { UTType(mimeType: $0) }
                + filter.extensions.compactMap { UTType(filenameExtension: $0) }
            for listed in named where !listed.isDynamic && type.conforms(to: listed) {
                // A broad type (application/octet-stream is public.data) accepts as a wildcard does.
                if Self.broad.contains(listed) { best = max(best, .any) } else { return .named }
            }
        }
        return best
    }

    /// The format a new image is written in (a camera photo, a converted one); nil when the
    /// request accepts no image.
    public var imageFormat: ImageFormat? { Self.first(ImageFormat.allCases, by: { acceptance(of: $0.type) }) }

    /// The format a converted video is written in; nil when the request accepts no video.
    public var movieFormat: MovieFormat? { Self.first(MovieFormat.allCases, by: { acceptance(of: $0.type) }) }

    /// What a scan becomes: a PDF when PDF is accepted by name, else images accepted by name,
    /// else a PDF, else images, accepted as anything; nil when neither is accepted.
    public var scanFormat: ScanFormat? {
        let pdf = acceptance(of: .pdf)
        if pdf == .named { return .pdf }
        if let image = imageFormat, acceptance(of: image.type) == .named { return .pages(image) }
        if pdf == .any { return .pdf }
        return imageFormat.map(ScanFormat.pages)
    }

    /// What a photo of type `original` becomes; nil when the request accepts no image.
    public func photo(_ original: UTType) -> Conversion<ImageFormat>? {
        guard let format = imageFormat else { return nil }
        return keeps(original, portable: Self.portableImages) ? .keep : .convert(format)
    }

    /// What a video of type `original` becomes; nil when the request accepts no video.
    public func video(_ original: UTType) -> Conversion<MovieFormat>? {
        guard let format = movieFormat else { return nil }
        return keeps(original, portable: Self.portableMovies) ? .keep : .convert(format)
    }

    /// The sources to offer for `request`, in order: always Files for opening files (none
    /// for anything else); Photos and Camera when it accepts an image or a video, Camera only
    /// with a camera; Scan Document when it accepts a scan, only with the document scanner.
    public static func sources(for request: BridgeRequest, camera: Bool, scanner: Bool) -> [BridgeSource] {
        guard request.type == .open, !request.directory else { return [] }
        let media = BridgeMedia(request)
        let visual = media.imageFormat != nil || media.movieFormat != nil
        var sources: [BridgeSource] = [.files]
        if visual { sources.append(.photos) }
        if visual && camera { sources.append(.camera) }
        if scanner && media.scanFormat != nil { sources.append(.scan) }
        return sources
    }

    private func keeps(_ original: UTType, portable: [UTType]) -> Bool {
        switch acceptance(of: original) {
        case .named: true
        case .any: portable.contains { original.conforms(to: $0) }
        case .no: false
        }
    }

    /// The first format accepted by name, else the first accepted at all.
    private static func first<Format>(_ formats: [Format], by acceptance: (Format) -> Acceptance) -> Format? {
        formats.first { acceptance($0) == .named } ?? formats.first { acceptance($0) == .any }
    }

    private static func family(_ prefix: String) -> UTType? {
        switch prefix {
        case "image": .image
        case "video": .movie
        case "audio": .audio
        case "text": .text
        case "font": .font
        default: nil
        }
    }
}

/// Names for the files the phone makes for the computer.
public enum BridgeMediaName {
    public enum Capture: String, Sendable {
        case scan = "Scan", photo = "Photo", video = "Video"
    }

    /// "Scan 2026-10-30 14.05.pdf"; a page of several, "Scan 2026-10-30 14.05 Page 2.jpg".
    public static func capture(_ kind: Capture, at date: Date, page: Int? = nil, fileExtension: String, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let page = page.map { " Page \($0)" } ?? ""
        return "\(kind.rawValue) \(formatter.string(from: date))\(page).\(fileExtension)"
    }

    /// A picked item's name with the extension of what is sent: its own name ("IMG_1234",
    /// "IMG_1234.HEIC") when it has a usable one, else `fallback`; at most 255 bytes, one
    /// path segment, not hidden.
    public static func picked(_ suggested: String?, fallback: String, fileExtension: String) -> String {
        var base = (suggested ?? "").unicodeScalars
            .filter { $0 != "/" && $0.properties.generalCategory != .control }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
        let ext = (base as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .image) || type.conforms(to: .audiovisualContent) {
            base = (base as NSString).deletingPathExtension
        }
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = fallback }
        let suffix = "." + fileExtension
        while base.utf8.count + suffix.utf8.count > 255, !base.isEmpty { base.removeLast() }
        return base + suffix
    }
}
