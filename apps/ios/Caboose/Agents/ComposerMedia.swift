import CabooseKit
import AVFoundation
import Observation
import PhotosUI
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Unsent input belongs to one chat, including while its send is in flight.
@MainActor @Observable
final class AgentComposerDraft {
    struct File: Identifiable {
        let id = UUID()
        let attachment: AgentAttachment
        var thumbnail: UIImage? {
            attachment.type.hasPrefix("image/") ? UIImage(data: attachment.data) : nil
        }
    }
    var text = ""
    var files: [File] = []
    var sending = false
    var importing = false
    var error: String?

    func add(name: String, type: String, data: Data) {
        guard files.count < 4 else { error = "You can attach up to four files to a message."; return }
        guard !data.isEmpty else { error = "This file is empty."; return }
        guard files.reduce(0, { $0 + $1.attachment.data.count }) + data.count <= 10 * 1024 * 1024 else {
            error = "Attachments can total up to 10 MB per message."; return
        }
        files.append(File(attachment: AgentAttachment(name: name, type: type, data: data)))
        error = nil
    }

    func add(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            guard (info.fileSize ?? 0) <= 10 * 1024 * 1024 else { error = "This file is larger than 10 MB."; return }
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var readError: Error?
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                do { add(name: url.lastPathComponent, type: info.contentType?.preferredMIMEType ?? "application/octet-stream", data: try Data(contentsOf: readable)) }
                catch { readError = error }
            }
            if let error = coordinationError ?? readError as NSError? { throw error }
        } catch { self.error = error.localizedDescription }
    }
}

/// Explicit speech input. It never sends; the owner can edit the recognized text first.
@MainActor @Observable
final class AgentDictation {
    private(set) var listening = false
    private(set) var requesting = false
    var error: String?
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var hasTap = false
    private var audioActive = false
    private var audioLease: UUID?
    private var generation = UUID()

    func start(update: @escaping @MainActor (String) -> Void) async {
        guard !listening, !requesting else { return }
        requesting = true
        error = nil
        let attempt = UUID()
        generation = attempt
        defer { requesting = false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard generation == attempt else { return }
        guard speech, microphone else {
            error = "Enable Microphone and Speech Recognition for Caboose in Settings to dictate."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            error = "Speech recognition is unavailable right now. You can still type your message."
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            audioLease = try CabooseAudioSession.acquire(.init(.playAndRecord, mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]))
            try audio.setActive(true)
            audioActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                stop(); error = "No microphone is available."; return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true
            listening = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.generation == attempt else { return }
                    if let text { update(text) }
                    if finished || failure != nil {
                        self.stop()
                        if let failure, !finished { self.error = failure.localizedDescription }
                    }
                }
            }
            engine.prepare()
            try engine.start()
        } catch { stop(); self.error = error.localizedDescription }
    }

    func stop() {
        generation = UUID()
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        recognition?.cancel()
        request = nil; recognition = nil
        listening = false
        if let lease = audioLease {
            audioLease = nil
            do { try CabooseAudioSession.release(lease) }
            catch { self.error = "Could not restore playback after dictation: \(error.localizedDescription)" }
            audioActive = false
        }
    }
}

struct AgentCamera: UIViewControllerRepresentable {
    let captured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: AgentCamera
        init(_ parent: AgentCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.captured(image) }
            parent.dismiss()
        }
    }
}
