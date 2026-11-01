import Foundation
import XCTest
@testable import CabooseKit

final class ComputerNetworkTests: XCTestCase {
    func testDecodesTheHostsNetworkStatus() throws {
        let json = #"{"tailnet":{"state":"running","name":"dev-box.tailea5249.ts.net","addresses":["100.101.102.103","fd7a:115c:a1e0::1"]},"servers":[{"protocol":"tcp","address":"0.0.0.0","port":5432},{"protocol":"udp","address":"0.0.0.0","port":27015}]}"#
        let network = try JSONDecoder().decode(ComputerNetwork.self, from: Data(json.utf8))
        XCTAssertEqual(network.host, "dev-box.tailea5249.ts.net")
        XCTAssertEqual(network.tailnet?.ipv4, "100.101.102.103")
        XCTAssertEqual(network.servers?.map(\.id), ["tcp/5432", "udp/27015"])
    }

    func testHasNoHostUntilTheDeviceIsUp() throws {
        let json = #"{"tailnet":{"state":"needs-login","loginUrl":"https://login.tailscale.com/a/abc"}}"#
        let network = try JSONDecoder().decode(ComputerNetwork.self, from: Data(json.utf8))
        XCTAssertNil(network.host)
        XCTAssertEqual(network.tailnet?.loginUrl, URL(string: "https://login.tailscale.com/a/abc"))
        XCTAssertNil(try JSONDecoder().decode(ComputerNetwork.self, from: Data("{}".utf8)).host)
    }

    func testFallsBackToTheHomeNetworkName() throws {
        let json = #"{"tailnet":{"state":"needs-login"},"lan":{"state":"running","address":"192.168.68.40","name":"dev-box.local"}}"#
        let network = try JSONDecoder().decode(ComputerNetwork.self, from: Data(json.utf8))
        XCTAssertEqual(network.host, "dev-box.local")
        XCTAssertEqual(network.lan?.address, "192.168.68.40")
    }

    func testOpensWebServersInABrowserAndNamesOthers() {
        let vite = ComputerNetwork.Server(protocol: "tcp", address: "0.0.0.0", port: 5173)
        XCTAssertEqual(vite.label, "Vite")
        XCTAssertEqual(vite.url(host: "dev-box.ts.net")?.absoluteString, "http://dev-box.ts.net:5173/")
        let postgres = ComputerNetwork.Server(protocol: "tcp", address: "0.0.0.0", port: 5432)
        XCTAssertEqual(postgres.label, "PostgreSQL")
        XCTAssertNil(postgres.url(host: "dev-box.ts.net"))
        XCTAssertEqual(postgres.address(host: "dev-box.ts.net"), "dev-box.ts.net:5432")
        XCTAssertEqual(ComputerNetwork.Server(protocol: "tcp", address: "::", port: 7777).url(host: "h")?.absoluteString, "http://h:7777/")
        XCTAssertEqual(ComputerNetwork.Server(protocol: "tcp", address: "::", port: 443).url(host: "h")?.absoluteString, "https://h/")
        XCTAssertNil(ComputerNetwork.Server(protocol: "udp", address: "0.0.0.0", port: 27015).url(host: "h"))
    }
}
