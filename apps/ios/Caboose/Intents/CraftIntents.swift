import AppIntents
import Foundation
import UniformTypeIdentifiers

enum ImageCraftFormat: String, AppEnum {
    case png, jpg, tif, webp
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Image Format")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.png: "PNG", .jpg: "JPEG", .tif: "TIFF", .webp: "WebP"]
}
enum FilmCraftFormat: String, AppEnum {
    case mp4, mov
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Video Format")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.mp4: "MP4", .mov: "MOV"]
}

private func craftRun(_ app: String, files: [IntentFile], format: String) async throws -> (files: [IntentFile], warnings: [String]) {
    guard let credentials = Credentials.load() else { throw HostClient.Failure.unauthorized }
    guard !files.isEmpty else { throw HostClient.Failure.server(400, "Choose input files.") }
    let fs = HostShortcutFiles(credentials: credentials)
    let job = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let directory = ".caboose-jobs/" + job
    try await fs.mkdir(".caboose-jobs", allowExisting: true)
    try await fs.mkdir(directory)
    var names: [String] = []
    for (index, file) in files.enumerated() {
        let supplied = (file.filename as NSString).pathExtension.lowercased()
        let ext = supplied.isEmpty ? (file.type?.preferredFilenameExtension ?? "") : supplied
        guard !ext.isEmpty, ext.count <= 12, ext.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0) }) else {
            throw HostClient.Failure.server(400, "Each file needs a supported filename extension.")
        }
        let name = "input-\(index).\(ext)"
        let temporary: URL?
        let source: URL
        if let url = file.fileURL { source = url; temporary = nil }
        else {
            source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try file.data.write(to: source, options: .atomic)
            temporary = source
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try await fs.upload(directory + "/" + name, from: source)
        names.append(name)
    }
    struct Result: Decodable { var job: String; var outputs: [String]; var warnings: [String] }
    let client = HostClient(baseURL: await credentials.reachableURL(), token: credentials.token)
    let result: Result = try await client.request("POST", "/v1/catalog/\(app)/run", body: [
        "job": .string(job), "inputs": .array(names.map { .string($0) }), "format": .string(format),
    ], timeout: 3600)
    var output: [IntentFile] = []
    for path in result.outputs {
        guard path.hasPrefix(directory + "/output-") else { throw HostClient.Failure.server(502, "Invalid output path.") }
        let url = try await fs.download(path)
        var file = IntentFile(fileURL: url, filename: (path as NSString).lastPathComponent)
        file.removedOnCompletion = true
        output.append(file)
    }
    // Successful downloads are independent of the staged files. Failed jobs remain for inspection.
    try? await fs.remove(directory)
    return (output, result.warnings)
}

struct PhotoCraftConvertIntent: AppIntent {
    static var title: LocalizedStringResource = "Convert Images with PhotoCraft"
    @Parameter(title: "Images") var files: [IntentFile]
    @Parameter(title: "Format", default: .png) var format: ImageCraftFormat
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let result = try await craftRun("photocraft", files: files, format: format.rawValue)
        return .result(value: result.files, dialog: IntentDialog(stringLiteral: result.warnings.isEmpty ? "Finished." : result.warnings.joined(separator: "\n")))
    }
}
struct PDFCraftCombineIntent: AppIntent {
    static var title: LocalizedStringResource = "Combine PDFs with PDFCraft"
    @Parameter(title: "PDFs") var files: [IntentFile]
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let result = try await craftRun("pdfcraft", files: files, format: "pdf")
        return .result(value: result.files, dialog: IntentDialog(stringLiteral: result.warnings.isEmpty ? "Finished." : result.warnings.joined(separator: "\n")))
    }
}
struct LightCraftRenderIntent: AppIntent {
    static var title: LocalizedStringResource = "Develop Photo with LightCraft"
    @Parameter(title: "Photo") var file: IntentFile
    @Parameter(title: "Format", default: .jpg) var format: ImageCraftFormat
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let result = try await craftRun("lightcraft", files: [file], format: format.rawValue)
        return .result(value: result.files, dialog: IntentDialog(stringLiteral: result.warnings.isEmpty ? "Finished." : result.warnings.joined(separator: "\n")))
    }
}
struct FilmCraftExportIntent: AppIntent {
    static var title: LocalizedStringResource = "Export FilmCraft Project"
    @Parameter(title: "Project") var file: IntentFile
    @Parameter(title: "Format", default: .mp4) var format: FilmCraftFormat
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> & ProvidesDialog {
        let result = try await craftRun("filmcraft", files: [file], format: format.rawValue)
        return .result(value: result.files, dialog: IntentDialog(stringLiteral: result.warnings.isEmpty ? "Finished." : result.warnings.joined(separator: "\n")))
    }
}
