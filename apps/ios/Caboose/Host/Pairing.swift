import Foundation

/// A `caboose://connect?host=<url>&code=<code>[&alt=<url>…]` link, shown by the console as a
/// QR code. The code is single-use and short-lived; the host trades it for this phone's own
/// sign-in token, so no token is ever in a link or on a screen.
struct PairingLink: Equatable {
    var hostURL: URL
    var code: String
    var alternateURLs: [URL] = []

    init?(link: URL) {
        guard link.scheme == "caboose", link.host == "connect",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, let url = URL(string: host),
              let code = items.first(where: { $0.name == "code" })?.value, let normalized = Self.normalize(code)
        else { return nil }
        self.init(hostURL: url, code: normalized, alternateURLs: items.filter { $0.name == "alt" }.compactMap { $0.value.flatMap(URL.init(string:)) })
    }

    init(hostURL: URL, code: String, alternateURLs: [URL] = []) {
        self.hostURL = hostURL
        self.code = code
        self.alternateURLs = alternateURLs
    }

    /// A code as the console shows it (`ABCD-2345`) or typed loosely: eight letters and digits,
    /// spaces, dashes and case forgiven. Nil for anything else, such as a sign-in token.
    static func normalize(_ text: String) -> String? {
        let code = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        let alphabet = Set("ABCDEFGHJKMNPQRSTVWXYZ23456789")
        return code.count == 8 && code.allSatisfy(alphabet.contains) ? code : nil
    }

    enum Failure: LocalizedError {
        case expired, tooManyAttempts, rejected(String)
        var errorDescription: String? {
            switch self {
            case .expired: "This pairing code has expired or was already used. Make a new one on the computer's Phones page."
            case .tooManyAttempts: "Too many wrong pairing codes were tried. Wait a minute, then try again."
            case .rejected(let message): message
            }
        }
    }

    /// Trades the code for this phone's token at the first address that answers, and returns
    /// the credentials to keep.
    func redeem(deviceName: String, session: URLSession = .shared) async throws -> Credentials {
        let base = await Credentials(hostURL: hostURL, token: "", alternateURLs: alternateURLs).reachableURL()
        var request = URLRequest(url: base.appendingPathComponent("v1/pair"), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code, "deviceName": String(deviceName.prefix(60))])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 201:
            struct Paired: Decodable {
                struct Computer: Decodable { let id: String; let name: String }
                let token: String
                let computer: Computer?
            }
            let paired = try JSONDecoder().decode(Paired.self, from: data)
            guard !paired.token.isEmpty else { throw Failure.rejected("The computer returned an empty sign-in token.") }
            return Credentials(hostURL: hostURL, token: paired.token, alternateURLs: alternateURLs,
                               computerID: paired.computer?.id, computerName: paired.computer?.name)
        case 404: throw Failure.expired
        case 429: throw Failure.tooManyAttempts
        default:
            struct Problem: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Problem.self, from: data))?.error
            throw Failure.rejected(message.map { "The computer would not pair: \($0)." } ?? "The computer would not pair (HTTP \(status)).")
        }
    }
}
