#if CABOOSE_APP
import CabooseKit
import Foundation

/// Files the phone hands to Linux applications, and files it fetches from the computer's
/// clipboard, through the host's `/v1/fs` relay.
extension HostClient {
    /// The most one transferred file may be; the file service enforces the same.
    static let transferFileLimit: Int64 = 512 * 1024 * 1024

    /// A new transfer id: 32 lowercase hexadecimal digits.
    static func newTransferID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Streams a local file into the computer's transfer area and returns its absolute
    /// path on the computer.
    func uploadTransfer(id: String, name: String, file: URL) async throws -> String {
        struct Uploaded: Decodable { var path: String }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/transfer"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "name", value: Self.transferName(name))]
        var request = URLRequest(url: components.url!, timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data, status: Int
        do { (data, status) = try await BoundedTransfer.upload(request, fromFile: file) }
        catch BoundedTransfer.Failure.redirected { throw Failure.unreachable("The host redirected the upload; it was not sent.") }
        catch { throw Failure.unreachable(error.localizedDescription) }
        switch status {
        case 201:
            guard let uploaded = try? JSONDecoder().decode(Uploaded.self, from: data),
                  ClipboardPolicy.homeRelative(ClipboardPolicy.home + "/" + uploaded.path) == uploaded.path else {
                throw Failure.server(status, "The computer answered the upload with an invalid path.")
            }
            return ClipboardPolicy.home + "/" + uploaded.path
        case 413: throw Failure.server(status, "\(name) is larger than 512 MB.")
        case 507: throw Failure.server(status, "The computer's transfer space is full. Try again later.")
        case 401, 403: throw Failure.unauthorized
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw Failure.server(status, message)
        }
    }

    /// Removes a transfer, for an upload abandoned part way.
    func cancelTransfer(id: String) async {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/transfer"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await BoundedTransfer.fetch(request)
    }

    /// Downloads a home file to disk (never into memory), refusing more than `limit` bytes.
    func downloadHomeFile(_ relative: String, into directory: URL, limit: Int64) async throws -> URL {
        func fsRequest(_ operation: String) -> URLRequest {
            var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/" + operation), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: relative)]
            var request = URLRequest(url: components.url!, timeoutInterval: 60)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        // The size first, so nothing too large is fetched at all.
        struct Item: Decodable { var kind: String; var size: Int64 }
        let name = (relative as NSString).lastPathComponent
        let stat: Data
        do { stat = try await BoundedTransfer.fetch(fsRequest("stat")).0 }
        catch { throw Failure.unreachable(error.localizedDescription) }
        guard let item = try? JSONDecoder().decode(Item.self, from: stat), item.kind == "file" else {
            throw Failure.server(0, "\(name) is not a file the computer can share.")
        }
        guard item.size <= limit else { throw Failure.server(0, "\(name) is too large to copy to iPhone.") }
        // The file can change after the stat: the download itself stops at the limit.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        do { _ = try await BoundedTransfer.download(fsRequest("content"), to: destination, limit: limit) }
        catch BoundedTransfer.Failure.tooLarge { throw Failure.server(0, "\(name) is too large to copy to iPhone.") }
        catch BoundedTransfer.Failure.redirected { throw Failure.unreachable("The host redirected the download; it was refused.") }
        catch BoundedTransfer.Failure.status(let status) { throw Failure.server(status, "Could not copy \(name) from the computer.") }
        catch { throw Failure.unreachable(error.localizedDescription) }
        return destination
    }

    /// A name the file service takes: one path component without control characters.
    static func transferName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.hasPrefix(".caboose-upload-") else { return "file" }
        var bytes = cleaned
        while bytes.utf8.count > 255 { bytes.removeFirst() }
        return bytes
    }
}
#endif
