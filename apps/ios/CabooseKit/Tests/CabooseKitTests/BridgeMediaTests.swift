import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CabooseKit

private func request(type: String = "file.open", filters: [[String: Any]], current: Int? = nil,
                     multiple: Bool = false, directory: Bool = false) throws -> BridgeRequest {
    let value: [String: Any] = [
        "id": "0123456789abcdef0123456789abcdef", "type": type, "app": "org.gimp.GIMP", "title": "Open Image",
        "acceptLabel": "", "multiple": multiple, "directory": directory, "filters": filters,
        "currentFilter": current.map { $0 as Any } ?? NSNull(), "currentName": "", "currentFolder": "", "created": 1,
    ]
    return try JSONDecoder().decode(BridgeRequest.self, from: JSONSerialization.data(withJSONObject: value))
}

private func filter(_ name: String, _ patterns: [String] = [], _ mimeTypes: [String] = []) -> [String: Any] {
    ["name": name, "patterns": patterns, "mimeTypes": mimeTypes]
}

private let allFiles = filter("All files", ["*"])
private let images = filter("Images", ["*.png", "*.jpg", "*.jpeg", "*.xcf"], ["image/png", "image/jpeg"])
private let documents = filter("Documents", ["*.odt", "*.pdf"], ["application/pdf"])

@Suite struct BridgeMediaTests {
    @Test func offersSourcesWhoseOutputIsAccepted() throws {
        let gimp = try request(filters: [allFiles, images], current: 1, multiple: true)
        #expect(BridgeMedia.sources(for: gimp, camera: true, scanner: true) == [.files, .photos, .camera, .scan])
        #expect(BridgeMedia.sources(for: gimp, camera: false, scanner: false) == [.files, .photos])
        // Text only: nothing the phone makes is accepted, so only Files.
        let text = try request(filters: [filter("Text", ["*.txt"], ["text/plain"])])
        #expect(BridgeMedia.sources(for: text, camera: true, scanner: true) == [.files])
        // PDF only: scanning, not photos.
        let pdf = try request(filters: [filter("PDF", ["*.pdf"])])
        #expect(BridgeMedia.sources(for: pdf, camera: true, scanner: true) == [.files, .scan])
        #expect(BridgeMedia.sources(for: pdf, camera: true, scanner: false) == [.files])
        // Video only: Photos and the camera, not the scanner.
        let video = try request(filters: [filter("Video", [], ["video/*"])])
        #expect(BridgeMedia.sources(for: video, camera: true, scanner: true) == [.files, .photos, .camera])
        // No filters: anything.
        #expect(BridgeMedia.sources(for: try request(filters: []), camera: true, scanner: true) == [.files, .photos, .camera, .scan])
    }

    @Test func offersNoSourcesForFoldersSavesOrScans() throws {
        #expect(BridgeMedia.sources(for: try request(filters: [], directory: true), camera: true, scanner: true).isEmpty)
        #expect(BridgeMedia.sources(for: try request(type: "file.save", filters: []), camera: true, scanner: true).isEmpty)
    }

    @Test func theCurrentFilterDecides() throws {
        let pdfCurrent = try request(filters: [images, documents], current: 1)
        #expect(BridgeMedia(pdfCurrent).imageFormat == nil)
        #expect(BridgeMedia(pdfCurrent).scanFormat == .pdf)
        let none = try request(filters: [images, documents])
        #expect(BridgeMedia(none).imageFormat == .jpeg)
        #expect(BridgeMedia(none).scanFormat == .pdf)
    }

    @Test func acceptance() {
        let media = BridgeMedia(filters: [BridgeRequest.Filter(name: "A", patterns: ["*.png"], mimeTypes: ["video/*"])])
        #expect(media.acceptance(of: .png) == .named)
        #expect(media.acceptance(of: .jpeg) == .no)
        #expect(media.acceptance(of: .quickTimeMovie) == .any)
        let wildcard = BridgeMedia(filters: [BridgeRequest.Filter(name: "All", patterns: ["*.*"], mimeTypes: [])])
        #expect(wildcard.acceptance(of: .heic) == .any)
        let octet = BridgeMedia(filters: [BridgeRequest.Filter(name: "All", patterns: [], mimeTypes: ["application/octet-stream"])])
        #expect(octet.acceptance(of: .pdf) == .any)
        #expect(BridgeMedia(filters: []).acceptance(of: .pdf) == .any)
    }

    @Test func photosKeepTheirOriginalOrConvert() {
        let jpegOnly = BridgeMedia(filters: [BridgeRequest.Filter(name: "JPEG", patterns: ["*.jpg"], mimeTypes: [])])
        #expect(jpegOnly.photo(.heic) == .convert(.jpeg))
        #expect(jpegOnly.photo(.jpeg) == .keep)
        #expect(jpegOnly.photo(.png) == .convert(.jpeg))
        let pngOnly = BridgeMedia(filters: [BridgeRequest.Filter(name: "PNG", patterns: [], mimeTypes: ["image/png"])])
        #expect(pngOnly.photo(.heic) == .convert(.png))
        #expect(pngOnly.imageFormat == .png)
        let heif = BridgeMedia(filters: [BridgeRequest.Filter(name: "HEIF", patterns: ["*.heic", "*.png"], mimeTypes: [])])
        #expect(heif.photo(.heic) == .keep)
        // Accepted as anything: widely readable originals are kept, HEIC becomes JPEG.
        let any = BridgeMedia(filters: [])
        #expect(any.photo(.heic) == .convert(.jpeg))
        #expect(any.photo(.png) == .keep)
        #expect(any.photo(.gif) == .keep)
        let family = BridgeMedia(filters: [BridgeRequest.Filter(name: "Images", patterns: [], mimeTypes: ["image/*"])])
        #expect(family.photo(.heic) == .convert(.jpeg))
        #expect(family.photo(.jpeg) == .keep)
        let pdf = BridgeMedia(filters: [BridgeRequest.Filter(name: "PDF", patterns: ["*.pdf"], mimeTypes: [])])
        #expect(pdf.photo(.jpeg) == nil)
    }

    @Test func videosKeepTheirOriginalOrConvert() {
        let mp4 = BridgeMedia(filters: [BridgeRequest.Filter(name: "MP4", patterns: ["*.mp4"], mimeTypes: [])])
        #expect(mp4.video(.quickTimeMovie) == .convert(.mp4))
        #expect(mp4.video(.mpeg4Movie) == .keep)
        let mov = BridgeMedia(filters: [BridgeRequest.Filter(name: "QuickTime", patterns: [], mimeTypes: ["video/quicktime"])])
        #expect(mov.video(.mpeg4Movie) == .convert(.mov))
        #expect(BridgeMedia(filters: []).video(.quickTimeMovie) == .keep)
        #expect(BridgeMedia(filters: [BridgeRequest.Filter(name: "PNG", patterns: ["*.png"], mimeTypes: [])]).video(.quickTimeMovie) == nil)
    }

    @Test func scansArePDFWhenAcceptedElseImages() {
        let documents = BridgeMedia(filters: [BridgeRequest.Filter(name: "Docs", patterns: ["*.odt", "*.pdf"], mimeTypes: [])])
        #expect(documents.scanFormat == .pdf)
        let pictures = BridgeMedia(filters: [BridgeRequest.Filter(name: "Pictures", patterns: ["*.png", "*.tif"], mimeTypes: [])])
        #expect(pictures.scanFormat == .pages(.png))
        // Images by name beat a PDF that is only accepted as anything.
        let mixed = BridgeMedia(filters: [BridgeRequest.Filter(name: "All", patterns: ["*"], mimeTypes: []),
                                          BridgeRequest.Filter(name: "JPEG", patterns: ["*.jpeg"], mimeTypes: [])])
        #expect(mixed.scanFormat == .pages(.jpeg))
        #expect(BridgeMedia(filters: []).scanFormat == .pdf)
        #expect(BridgeMedia(filters: [BridgeRequest.Filter(name: "Images", patterns: [], mimeTypes: ["image/*"])]).scanFormat == .pages(.jpeg))
        #expect(BridgeMedia(filters: [BridgeRequest.Filter(name: "Text", patterns: ["*.txt"], mimeTypes: [])]).scanFormat == nil)
        #expect(BridgeMedia.ScanFormat.pages(.jpeg).fileExtension == "jpg")
    }

    @Test func scanRequestsAskForTheirFormat() throws {
        let pdf = try request(type: "scan", filters: [filter("PDF", ["*.pdf"], ["application/pdf"])], current: 0)
        #expect(pdf.type == .scan)
        #expect(BridgeMedia(pdf).scanFormat == .pdf)
        let pages = try request(type: "scan", filters: [filter("JPEG", ["*.jpg", "*.jpeg"], ["image/jpeg"])], current: 0, multiple: true)
        #expect(BridgeMedia(pages).scanFormat == .pages(.jpeg))
        for bad: (filters: [[String: Any]], current: Int?, multiple: Bool, directory: Bool) in [
            ([filter("PDF", ["*.pdf"], ["application/pdf"])], 0, true, false),
            ([filter("JPEG", ["*.jpg", "*.jpeg"], ["image/jpeg"])], 0, false, false),
            ([filter("PDF", ["*.pdf"], ["application/pdf"])], nil, false, false),
            ([filter("PDF", ["*.pdf"], ["application/pdf"])], 0, false, true),
            ([filter("PNG", ["*.png"], ["image/png"])], 0, true, false),
            ([], nil, false, false),
        ] {
            #expect(throws: (any Error).self) {
                try request(type: "scan", filters: bad.filters, current: bad.current, multiple: bad.multiple, directory: bad.directory)
            }
        }
    }

    @Test func names() {
        let date = Date(timeIntervalSince1970: 1_793_369_100) // 2026-10-30 14:05 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(BridgeMediaName.capture(.scan, at: date, fileExtension: "pdf", timeZone: utc) == "Scan 2026-10-30 14.05.pdf")
        #expect(BridgeMediaName.capture(.scan, at: date, page: 2, fileExtension: "jpg", timeZone: utc) == "Scan 2026-10-30 14.05 Page 2.jpg")
        #expect(BridgeMediaName.capture(.video, at: date, fileExtension: "mov", timeZone: utc) == "Video 2026-10-30 14.05.mov")
        #expect(BridgeMediaName.picked("IMG_1234", fallback: "Photo", fileExtension: "heic") == "IMG_1234.heic")
        #expect(BridgeMediaName.picked("IMG_1234.HEIC", fallback: "Photo", fileExtension: "jpg") == "IMG_1234.jpg")
        #expect(BridgeMediaName.picked("Trip v1.2", fallback: "Photo", fileExtension: "jpg") == "Trip v1.2.jpg")
        #expect(BridgeMediaName.picked("a/b\u{7}", fallback: "Photo", fileExtension: "png") == "ab.png")
        #expect(BridgeMediaName.picked("..", fallback: "Photo", fileExtension: "png") == "Photo.png")
        #expect(BridgeMediaName.picked(nil, fallback: "Video", fileExtension: "mov") == "Video.mov")
        let long = BridgeMediaName.picked(String(repeating: "é", count: 200), fallback: "Photo", fileExtension: "jpg")
        #expect(long.utf8.count <= 255 && long.hasSuffix(".jpg"))
    }
}
