import CabooseKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Where a Linux application's Open dialog takes its file from: Files, Photos, the camera
/// or the document scanner, as the request accepts them, or the computer's own dialog.
struct BridgeSourceSheet: View {
    enum Choice { case source(BridgeSource), computer, cancel }

    let request: BridgeRequest
    let sources: [BridgeSource]
    let choose: (Choice) -> Void

    private var media: BridgeMedia { BridgeMedia(request) }
    private var title: String { request.title.isEmpty ? "Open" : request.title }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sources) { source in
                        Button { choose(.source(source)) } label: { row(source) }
                            .tint(.primary)
                    }
                }
                Section {
                    Button { choose(.computer) } label: {
                        Label("Use Computer Dialog", systemImage: "desktopcomputer")
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(request.appName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { choose(.cancel) }
                }
            }
        }
    }

    private func row(_ source: BridgeSource) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name(source))
                Text(detail(source)).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon(source)).foregroundStyle(Color.accentColor)
        }
    }

    private func name(_ source: BridgeSource) -> String {
        switch source {
        case .files: "Files"
        case .photos: "Photos"
        case .camera: "Camera"
        case .scan: "Scan Document"
        }
    }

    private func icon(_ source: BridgeSource) -> String {
        switch source {
        case .files: "folder"
        case .photos: "photo.on.rectangle"
        case .camera: "camera"
        case .scan: "doc.viewfinder"
        }
    }

    private func detail(_ source: BridgeSource) -> String {
        let images = media.imageFormat != nil, videos = media.movieFormat != nil
        switch source {
        case .files: return "iCloud Drive, this computer and other locations"
        case .photos: return images && videos ? "A photo or video from your library" : images ? "A photo from your library" : "A video from your library"
        case .camera: return images && videos ? "Take a photo or video" : images ? "Take a photo" : "Record a video"
        case .scan:
            switch media.scanFormat {
            case .pages(let format): return "Saved as \(format.rawValue.uppercased()) images, one per page"
            case .pdf, nil: return "Saved as a PDF"
            }
        }
    }
}

/// The photo picker for a request: photos and videos as it accepts them, several when it
/// takes several. Items come as they are stored (no transcoding by the picker); Live Photos
/// as their still.
@MainActor
func bridgePhotoPicker(for request: BridgeRequest, delegate: PHPickerViewControllerDelegate) -> PHPickerViewController {
    let media = BridgeMedia(request)
    var configuration = PHPickerConfiguration()
    var filters: [PHPickerFilter] = []
    if media.imageFormat != nil { filters.append(.images) }
    if media.movieFormat != nil { filters.append(.videos) }
    configuration.filter = .any(of: filters)
    configuration.selectionLimit = request.multiple ? 64 : 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = delegate
    return picker
}

/// The camera for a request: photos, videos or both, as it accepts them.
@MainActor
func bridgeCamera(for request: BridgeRequest, delegate: UIImagePickerControllerDelegate & UINavigationControllerDelegate) -> UIImagePickerController {
    let media = BridgeMedia(request)
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    var types: [String] = []
    if media.imageFormat != nil { types.append(UTType.image.identifier) }
    if media.movieFormat != nil { types.append(UTType.movie.identifier) }
    picker.mediaTypes = types
    picker.videoQuality = .typeHigh
    picker.delegate = delegate
    return picker
}

final class BridgeDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let done: ([URL]) -> Void
    init(done: @escaping ([URL]) -> Void) { self.done = done }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
}

final class BridgePhotosDelegate: NSObject, PHPickerViewControllerDelegate {
    let done: ([PHPickerResult]) -> Void
    init(done: @escaping ([PHPickerResult]) -> Void) { self.done = done }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { done(results) }
}

/// `done` gets the capture, or nil when cancelled.
final class BridgeCameraDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let done: ([UIImagePickerController.InfoKey: Any]?) -> Void
    init(done: @escaping ([UIImagePickerController.InfoKey: Any]?) -> Void) { self.done = done }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { done(info) }
}

/// `done` gets the scanned pages, an error, or nil when cancelled.
final class BridgeScannerDelegate: NSObject, VNDocumentCameraViewControllerDelegate {
    let done: (Result<[UIImage], Error>?) -> Void
    init(done: @escaping (Result<[UIImage], Error>?) -> Void) { self.done = done }
    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        done(.success((0..<scan.pageCount).map { scan.imageOfPage(at: $0) }))
    }
    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done(nil) }
    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done(.failure(error)) }
}
