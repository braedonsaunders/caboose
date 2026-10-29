import Foundation

@main struct RemoteAddressesTests {
    static func main() {
        func url(_ value: String) -> URL { Credentials.normalizedAddress(value)! }
        precondition(url(" HTTPS://Example.COM:443/base/ ").absoluteString == "https://example.com/base")
        for invalid in ["", "file:///tmp/x", "https://", "https://user:pass@example.com", "https://example.com/?x=1", "https://example.com/#x"] {
            precondition(Credentials.normalizedAddress(invalid) == nil, invalid)
        }
        var credentials = Credentials(hostURL: URL(string: "http://home:7310/")!, token: "phone-token")
        let primary = credentials.hostURL
        let identity = credentials.fileDomainIdentifier
        credentials.addAlternate(url("HTTP://HOME:7310"))
        precondition(credentials.alternateURLs.isEmpty)
        credentials.addAlternate(url("https://vpn.example:443/"))
        credentials.addAlternate(url("https://VPN.EXAMPLE"))
        precondition(credentials.alternateURLs.count == 1)
        precondition(credentials.hostURL == primary && credentials.token == "phone-token" && credentials.fileDomainIdentifier == identity)
        credentials.alternateURLs.removeAll()
        precondition(credentials.hostURL == primary && credentials.fileDomainIdentifier == identity)
        precondition(Credentials.isHealthResponse(status: 401, data: Data("{\"error\":\"unauthorized\"}".utf8)))
        precondition(!Credentials.isHealthResponse(status: 200, data: Data("<html>login</html>".utf8)))
        precondition(!Credentials.isHealthResponse(status: 302, data: Data("{\"error\":\"unauthorized\"}".utf8)))
        print("Remote address tests passed")
    }
}
