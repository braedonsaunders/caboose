import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

@MainActor
final class PairingModel: ObservableObject {
    @Published var message = "Connecting to Caboose…"
    @Published var failure: String?
    @Published var code = ""
    @Published var link = ""
    @Published var imageMessage = ""
    @Published var progress: Double?
    @Published var connected: String?
    @Published var needsSetup = false
    @Published var tailscaleInstalled = false
    @Published var tailscaleServing = false
    @Published var busy = false
    private var expires = Date.distantPast
    private var known: Set<String>?
    private var addresses: [String] = []
    private let directory: URL
    private let port: Int

    init(directory: URL, port: Int) { self.directory = directory; self.port = port }

    private func request(_ path: String, method: String = "GET", body: [String: Bool]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        if path != "/v1/setup" {
            let token = try String(contentsOf: directory.appendingPathComponent("disks/owner-token"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "Caboose", code: 1, userInfo: [NSLocalizedDescriptionKey: detail ?? "The host could not complete this request."])
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func poll() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let setup = try await request("/v1/setup")
            needsSetup = setup["claimed"] as? Bool != true
            if needsSetup { message = "Create your account to finish setting up Caboose."; failure = nil; return }
            let health = try await request("/v1/health")
            if let image = health["image"] as? [String: Any] {
                imageMessage = image["message"] as? String ?? ""
                if image["state"] as? String == "fetching" {
                    if let received = image["receivedBytes"] as? Double, let total = image["totalBytes"] as? Double, total > 0 {
                        progress = min(1, received / total)
                    } else {
                    progress = nil
                    switch image["state"] as? String {
                    case "missing": imageMessage = "The computer image is missing and this host has no image reference to download. Open the console to check the installation."
                    case "failed": imageMessage = "Image download failed: " + (image["message"] as? String ?? "unknown error")
                    case "ready": imageMessage = "The computer image is ready."
                    default: break
                    }
                }
                    if imageMessage.isEmpty { imageMessage = "Downloading the computer image…" }
                } else { progress = nil }
            }
            let reach = try await request("/v1/host/reach")
            addresses = (reach["addresses"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            let tailscale = reach["tailscale"] as? [String: Any] ?? [:]
            tailscaleInstalled = tailscale["installed"] as? Bool == true
            tailscaleServing = tailscale["serving"] as? Bool == true
            let phones = try await request("/v1/computers/owner/phones")
            let entries = phones["phones"] as? [[String: Any]] ?? []
            let ids = Set(entries.compactMap { $0["id"] as? String })
            if let known, let joined = entries.first(where: { row in
                guard let id = row["id"] as? String else { return false }
                return !known.contains(id)
            }) {
                connected = joined["name"] as? String ?? "Your iPhone"
                code = ""; link = ""
            }
            if known == nil { known = ids }
            if connected == nil {
                if code.isEmpty { try await mint() }
                if Date() >= expires { link = ""; message = "This code has expired. Choose New Code to continue." }
                else {
                    updateLink()
                    message = addresses.isEmpty ? "No phone address is available. Enable remote access or check the Mac’s network connection." : "Scan with your iPhone’s camera. This code works once, for ten minutes."
                }
            }
            failure = nil
        } catch {
            if Date() >= expires { link = "" }
            failure = error.localizedDescription
        }
    }

    private func mint() async throws {
        let result = try await request("/v1/computers/owner/pairing", method: "POST")
        guard let value = result["code"] as? String, let expiry = result["expiresAt"] as? String,
              let date = PairingLink.expiry(expiry) else { throw URLError(.cannotParseResponse) }
        code = value; expires = date; connected = nil
        updateLink()
    }

    private func updateLink() {
        link = PairingLink.make(addresses: addresses, code: code)
    }

    func renew() async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        do {
            let phones = try await request("/v1/computers/owner/phones")
            known = Set((phones["phones"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            try await mint(); failure = nil
        } catch { failure = error.localizedDescription }
    }

    func enableTailscale() async {
        guard !busy else { return }; busy = true
        do { _ = try await request("/v1/host/reach/tailscale", method: "PUT", body: ["enabled": true]); failure = nil }
        catch { failure = error.localizedDescription }
        busy = false
        await poll()
    }

    var qr: NSImage? {
        guard !link.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 220, height: 220))
    }
}

struct PairingView: View {
    @ObservedObject var model: PairingModel
    let openConsole: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("Caboose").font(.largeTitle.bold())
            if let connected = model.connected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                Text("\(connected) is connected").font(.title2)
            } else {
                Text(model.needsSetup ? "Welcome to your phone’s computer" : "Pair your iPhone").font(.title2)
                Text(model.message).multilineTextAlignment(.center)
                if let qr = model.qr {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(16).background(.white).accessibilityLabel("iPhone pairing QR code")
                    Text(model.code.count == 8 ? String(model.code.prefix(4)) + "-" + String(model.code.suffix(4)) : model.code)
                        .font(.title.monospaced()).textSelection(.enabled)
                    Button("Copy Pairing Link") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.link, forType: .string)
                    }
                }
            }
            if !model.imageMessage.isEmpty {
                Text(model.imageMessage).font(.callout)
                if let progress = model.progress { ProgressView(value: progress) }
            }
            if let failure = model.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if !model.needsSetup {
                if model.tailscaleInstalled && !model.tailscaleServing {
                    Button("Enable Tailscale HTTPS") { Task { await model.enableTailscale() } }.disabled(model.busy)
                } else if model.tailscaleServing { Text("Tailscale HTTPS is enabled").foregroundStyle(.secondary) }
                else { Link("Get Tailscale for access away from home", destination: URL(string: "https://tailscale.com/download")!) }
                Button("New Code") { Task { await model.renew() } }.disabled(model.busy)
            }
            Button(model.needsSetup ? "Create Account in Web Console" : "Open Web Console", action: openConsole)
                .buttonStyle(.borderedProminent)
        }
        .padding(28).frame(width: 440)
        .task {
            while !Task.isCancelled {
                await model.poll()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }
}
