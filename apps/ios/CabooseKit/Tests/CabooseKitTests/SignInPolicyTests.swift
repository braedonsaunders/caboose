import Foundation
import Testing
@testable import CabooseKit

struct SignInPolicyTests {
    private let tailnet = URL(string: "https://lucid-gpu.tailea5249.ts.net")!
    private let lan = URL(string: "http://192.168.1.20:7310")!

    @Test func titlesBySentNameBeforeAddress() {
        #expect(SignInTitle.host(learned: "Den", address: tailnet) == "Den")
        #expect(SignInTitle.host(learned: "  ", address: tailnet) == "lucid-gpu.tailea5249.ts.net")
        #expect(SignInTitle.host(learned: nil, address: tailnet) == "lucid-gpu.tailea5249.ts.net")
        #expect(SignInTitle.computer(name: "Kids", learned: "Den", address: tailnet) == "Kids")
        #expect(SignInTitle.computer(name: "", learned: "Den", address: tailnet) == "Den")
        #expect(SignInTitle.computer(name: nil, learned: nil, address: lan) == "192.168.1.20")
    }

    @Test func cleansSentNames() {
        #expect(SignInTitle.cleaned(" Den ") == "Den")
        #expect(SignInTitle.cleaned("") == nil)
        #expect(SignInTitle.cleaned("Bad\u{7}Name") == nil)
        #expect(SignInTitle.cleaned(String(repeating: "a", count: 200))?.count == 80)
    }

    @Test func hostListCarriesItsName() throws {
        let body = Data(#"{"computers":[],"canCreate":true,"host":{"name":"Den"}}"#.utf8)
        #expect(try JSONDecoder().decode(HostComputerList.self, from: body).hostName == "Den")
        let old = Data(#"{"computers":[],"canCreate":true}"#.utf8)
        #expect(try JSONDecoder().decode(HostComputerList.self, from: old).hostName == nil)
    }

    @Test func onlyTheRevokedAnswerRemovesASignIn() {
        let revoked = Data(#"{"error":"unauthorized","code":"sign-in-revoked"}"#.utf8)
        #expect(SignInRefusal.isRevoked(status: 401, body: revoked))
        // A plain refusal, another status, or a body that is not the host's are not definite.
        #expect(!SignInRefusal.isRevoked(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)))
        #expect(!SignInRefusal.isRevoked(status: 403, body: revoked))
        #expect(!SignInRefusal.isRevoked(status: 404, body: Data(#"{"error":"computer not found"}"#.utf8)))
        #expect(!SignInRefusal.isRevoked(status: 502, body: revoked))
        #expect(!SignInRefusal.isRevoked(status: 401, body: Data("<html>Unauthorized</html>".utf8)))
        #expect(!SignInRefusal.isRevoked(status: 0, body: Data()))
    }

    @Test func removesOnlyOnAnAnswerFromTheVerifiedAddress() {
        let canonical = URL(string: "https://lucid-gpu.tailea5249.ts.net")!
        #expect(SignInRefusal.mayRemove(answeredBy: canonical, canonical: canonical))
        #expect(SignInRefusal.mayRemove(answeredBy: URL(string: "https://LUCID-GPU.tailea5249.ts.net:443")!, canonical: canonical))
        // A probed LAN or VPN address, another port, or plain http could be another machine.
        #expect(!SignInRefusal.mayRemove(answeredBy: URL(string: "http://192.168.1.20:7310")!, canonical: canonical))
        #expect(!SignInRefusal.mayRemove(answeredBy: URL(string: "https://100.88.1.2")!, canonical: canonical))
        #expect(!SignInRefusal.mayRemove(answeredBy: URL(string: "https://lucid-gpu.tailea5249.ts.net:8443")!, canonical: canonical))
        let plain = URL(string: "http://192.168.1.20:7310")!
        #expect(!SignInRefusal.mayRemove(answeredBy: plain, canonical: plain))
    }

    @Test func recognisesTailnetAddresses() {
        for host in ["lucid-gpu.tailea5249.ts.net", "LUCID.TAILEA5249.TS.NET.", "100.64.0.1", "100.101.102.103", "100.127.255.255",
                     "fd7a:115c:a1e0::1", "[fd7a:115c:a1e0:ab12:4843:cd96:6258:b240]", "FD7A:115C:A1E0:0:0:0:0:9"] {
            #expect(TailnetAddress.contains(host: host), "\(host)")
        }
        for host in ["192.168.1.20", "100.63.255.255", "100.128.0.1", "10.0.0.1", "example.com", "ts.net.example.com", "nots.net",
                     "fd7a:115c:a1e1::1", "fe80::1", "100.64.0", "100.64.0.1.5", "box.local"] {
            #expect(!TailnetAddress.contains(host: host), "\(host)")
        }
        #expect(TailnetAddress.contains(URL(string: "http://100.88.1.2:7310")!))
        #expect(TailnetAddress.contains(URL(string: "http://[fd7a:115c:a1e0::5]:7310")!))
    }

    @Test func advisesTailscaleOnlyAfterRepeatedSilenceAtATailnetAddress() {
        var advice = TailnetAdvice()
        #expect(!advice.needsTailscale(addresses: [tailnet]))
        advice.unreached()
        #expect(!advice.needsTailscale(addresses: [tailnet]))
        advice.unreached()
        #expect(advice.needsTailscale(addresses: [tailnet]))
        #expect(advice.needsTailscale(addresses: [lan, tailnet]))
        // Not a tailnet sign-in: Tailscale would not help.
        #expect(!advice.needsTailscale(addresses: [lan]))
        // Any answer from the host clears it.
        advice.reached()
        #expect(!advice.needsTailscale(addresses: [tailnet]))
        #expect(TailnetAdvice.message(name: "Den") == "Turn on Tailscale on this iPhone to reach Den away from home.")
    }
}
