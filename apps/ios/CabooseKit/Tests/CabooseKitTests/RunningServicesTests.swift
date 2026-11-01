import Foundation
import Testing
@testable import CabooseKit

/// Services and listening ports in `GET /v1/running-apps`, the service routes, and the New
/// Service form's command splitting.
struct RunningServicesTests {
    static let listing = #"""
    {
      "version": 1, "sampledAt": 10, "intervalMs": 1000,
      "machine": { "cpus": 4, "memoryBytes": 8589934592 },
      "apps": [
        { "id": "app-agent-1.scope", "kind": "app", "desktopId": null, "name": "Agent task", "origin": "agent",
          "startedAt": 5, "windows": [], "cpuPercent": 20, "memoryBytes": 1000, "processCount": 1, "processes": [],
          "ports": [ { "protocol": "tcp", "address": "127.0.0.1", "port": 5173 }, { "protocol": "sctp", "address": "::", "port": 9 },
                     { "protocol": "tcp", "port": "bad" } ] },
        { "id": "app-old-1.scope", "kind": "app", "name": "Old host app", "origin": "launch", "windows": [1] }
      ],
      "services": [
        { "id": "web.service", "name": "web", "description": "My site", "source": "owner", "state": "active",
          "error": null, "autostart": true, "restart": "on-failure", "requires": ["db"], "since": 1793500000000,
          "restarts": 2, "lastExit": { "code": 1, "signal": null, "at": 1793499000000 },
          "cpuPercent": 1.5, "memoryBytes": 52428800,
          "io": { "readBytesPerSecond": 0, "writeBytesPerSecond": 10 }, "gpu": null, "processCount": 2,
          "processes": [ { "pid": 77, "ppid": 1, "name": "node", "command": "node server.js", "state": "sleeping",
                           "cpuPercent": 1.5, "memoryBytes": 50000000 } ],
          "ports": [ { "protocol": "tcp", "address": "0.0.0.0", "port": 8080 }, { "protocol": "tcp", "address": "::", "port": 8080 } ] },
        { "id": "db.service", "name": "db", "description": "", "source": "system", "state": "failed",
          "error": "exited with status 1", "autostart": false, "restart": "always", "requires": [], "since": 1,
          "restarts": 5, "lastExit": { "code": null, "signal": 9, "at": 2 }, "cpuPercent": 0, "memoryBytes": 0,
          "io": { "readBytesPerSecond": 0, "writeBytesPerSecond": 0 }, "gpu": null, "processCount": 0, "processes": [], "ports": [] },
        { "id": "idle.service", "name": "idle", "description": "", "source": "plugin", "state": "sleeping-ish",
          "error": null, "autostart": false, "restart": "sometimes", "since": 0, "restarts": 0, "lastExit": null },
        { "description": "no name" }
      ]
    }
    """#

    static func decoded() throws -> RunningAppsListing {
        try JSONDecoder().decode(RunningAppsListing.self, from: Data(listing.utf8))
    }

    @Test func decodesServices() throws {
        let listing = try Self.decoded()
        #expect(listing.listsServices)
        #expect(listing.services.map(\.id) == ["web.service", "db.service", "idle.service"])
        let web = listing.services[0]
        #expect(web.name == "web" && web.description == "My site")
        #expect(web.source == .owner && web.state == .active && web.autostart && web.restart == .onFailure)
        #expect(web.requires == ["db"] && web.restarts == 2)
        #expect(web.lastExit == .init(code: 1, signal: nil, at: 1793499000000))
        #expect(web.memoryBytes == 52428800 && web.processes.map(\.pid) == [77])
        #expect(web.ports.count == 2)
        let db = listing.services[1]
        #expect(db.state == .failed && db.error == "exited with status 1" && db.showsError)
        #expect(db.lastExit?.signal == 9 && db.lastExit?.code == nil)
        let idle = listing.services[2]
        #expect(idle.source == .other && idle.state == .other && idle.restart == .other)
        #expect(idle.processes.isEmpty && idle.ports.isEmpty && idle.lastExit == nil)
    }

    @Test func aStatusReplyHasNoResourceUse() throws {
        let json = #"{"id":"web.service","name":"web","description":"","source":"owner","state":"activating","error":"restarting after exit 1","autostart":false,"restart":"no","requires":[],"since":3,"restarts":1,"lastExit":null}"#
        let status = try JSONDecoder().decode(RunningService.self, from: Data(json.utf8))
        #expect(status.state == .activating && status.showsError)
        #expect(status.cpuPercent == 0 && status.memoryBytes == 0 && status.processCount == 0)
        #expect(status.restart == .no)
    }

    @Test func olderHostsListNoServicesOrPorts() throws {
        let json = #"{"version":1,"sampledAt":1,"intervalMs":1000,"machine":{"cpus":1,"memoryBytes":1},"apps":[{"id":"a.scope","kind":"app","name":"A"}]}"#
        let listing = try JSONDecoder().decode(RunningAppsListing.self, from: Data(json.utf8))
        #expect(!listing.listsServices && listing.services.isEmpty)
        #expect(listing.apps[0].ports.isEmpty)
    }

    @Test func appsCarryPortsAndAgentTasks() throws {
        let apps = try Self.decoded().apps
        let agent = apps[0]
        #expect(agent.origin == .agent)
        #expect(agent.presence == .agent && !agent.isBackground && !agent.canQuit && agent.canEnd)
        #expect(agent.ports == [.init(.tcp, address: "127.0.0.1", port: 5173), .init(.other, address: "::", port: 9)])
        #expect(apps[1].ports.isEmpty)
    }

    @Test func portLabels() {
        #expect(TaskManager.portLabels([
            .init(.tcp, address: "::", port: 8080), .init(.tcp, address: "0.0.0.0", port: 8080),
            .init(.udp, address: "::1", port: 53), .init(.tcp, address: "127.0.0.1", port: 631),
            .init(.other, address: "", port: 9),
        ]) == ["Port 9", "UDP [::1]:53", "TCP 127.0.0.1:631", "TCP 8080"])
    }

    @Test func servicesSortFailedThenRunningThenByName() {
        let services: [RunningService] = [
            .init(name: "b", state: .inactive), .init(name: "a", state: .inactive),
            .init(name: "small", state: .active, cpuPercent: 1, memoryBytes: 900),
            .init(name: "busy", state: .active, cpuPercent: 50, memoryBytes: 10),
            .init(name: "broken", state: .failed),
        ]
        let listing = RunningAppsListing(machine: .init(cpus: 1, memoryBytes: 1), apps: [], services: services)
        #expect(TaskManager.services(in: listing, sortedBy: .cpu).map(\.name) == ["broken", "busy", "small", "a", "b"])
        #expect(TaskManager.services(in: listing, sortedBy: .memory).map(\.name) == ["broken", "small", "busy", "a", "b"])
        #expect(TaskManager.services(in: listing, sortedBy: .name).map(\.name) == ["broken", "busy", "small", "a", "b"])
    }

    @Test func whatEachStateOffers() {
        let active = RunningService(name: "x", state: .active)
        #expect(!active.canStart && active.canStop && active.canRestart && active.canDelete)
        let failed = RunningService(name: "x", source: .system, state: .failed)
        #expect(failed.canStart && !failed.canStop && failed.canRestart && !failed.canDelete)
        let inactive = RunningService(name: "x", state: .inactive)
        #expect(inactive.canStart && !inactive.canStop && !inactive.canRestart)
    }

    @Test func serviceRoutes() {
        #expect(ServicesRoute.path(name: "web") == "/v1/services/web")
        #expect(ServicesRoute.path(.restart, name: "getty@tty1") == "/v1/services/getty%40tty1/restart")
        #expect(ServicesRoute.path(.disable, name: "my.site") == "/v1/services/my.site/disable")
        #expect(ServicesRoute.logs(name: "web", lines: 500) == "/v1/services/web/logs?lines=500")
        #expect(ServicesRoute.logs(name: "web", lines: 9000) == "/v1/services/web/logs?lines=2000")
        #expect(RunningService.name(fromID: "web.service") == "web")
    }

    // MARK: The New Service form

    @Test func splitsCommandsLikeAShell() throws {
        #expect(try ShellWords.split("") == [])
        #expect(try ShellWords.split("  node   server.js --port 8080 ") == ["node", "server.js", "--port", "8080"])
        #expect(try ShellWords.split(#"python3 -m http.server --directory '/home/caboose/My Site'"#)
                == ["python3", "-m", "http.server", "--directory", "/home/caboose/My Site"])
        #expect(try ShellWords.split(#"sh -c "echo \"hi\" \$HOME \n""#) == ["sh", "-c", #"echo "hi" $HOME \n"#])
        #expect(try ShellWords.split(#"a\ b c\\d 'it'\''s' "" ''"#) == ["a b", #"c\d"#, "it's", "", ""])
        #expect(try ShellWords.split("$HOME/bin/run ~ *") == ["$HOME/bin/run", "~", "*"])
        #expect(try ShellWords.split("one\ttwo\r\nthree") == ["one", "two", "three"])
        #expect(try ShellWords.split("a\\\nb") == ["ab"])
    }

    @Test func reportsUnfinishedQuoting() {
        #expect(throws: ShellWords.Problem.unterminatedSingleQuote) { try ShellWords.split("echo 'hi") }
        #expect(throws: ShellWords.Problem.unterminatedDoubleQuote) { try ShellWords.split(#"echo "hi"#) }
        #expect(throws: ShellWords.Problem.unterminatedDoubleQuote) { try ShellWords.split(#"echo "hi\"#) }
        #expect(throws: ShellWords.Problem.trailingBackslash) { try ShellWords.split(#"echo \"#) }
    }

    @Test func serviceNames() {
        #expect(ServiceDefinition.isValidName("web"))
        #expect(ServiceDefinition.isValidName("getty@tty1"))
        #expect(ServiceDefinition.isValidName("My_site-2.local"))
        #expect(ServiceDefinition.isValidName(String(repeating: "a", count: 64)))
        #expect(!ServiceDefinition.isValidName(String(repeating: "a", count: 65)))
        #expect(!ServiceDefinition.isValidName(""))
        #expect(!ServiceDefinition.isValidName("-web"))
        #expect(!ServiceDefinition.isValidName(".hidden"))
        #expect(!ServiceDefinition.isValidName("web site"))
        #expect(!ServiceDefinition.isValidName("wéb"))
        #expect(!ServiceDefinition.isValidName("a/b"))
    }

    @Test func buildsADefinition() throws {
        let definition = try ServiceDefinition.make(
            name: "web", commandLine: "node server.js", description: "  My site ", workingDirectory: " ~/site ",
            environment: [("PORT", "8080"), ("", ""), ("NODE_ENV", "production")], restart: .always, autostart: false)
        #expect(definition == ServiceDefinition(command: ["node", "server.js"], description: "My site", workingDirectory: "~/site",
                                                environment: ["PORT": "8080", "NODE_ENV": "production"],
                                                restart: "always", autostart: false))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            try ServiceDefinition.make(name: "web", commandLine: "run"))) as? [String: Any]
        #expect(encoded?.keys.sorted() == ["autostart", "command", "restart"])
        #expect(encoded?["autostart"] as? Bool == true)
        #expect(encoded?["restart"] as? String == "on-failure")
    }

    @Test func refusesBadDefinitions() {
        #expect(throws: ServiceDefinition.Problem.name) { try ServiceDefinition.make(name: "-x", commandLine: "run") }
        #expect(throws: ServiceDefinition.Problem.emptyCommand) { try ServiceDefinition.make(name: "x", commandLine: "   ") }
        #expect(throws: ServiceDefinition.Problem.command(.unterminatedSingleQuote)) {
            try ServiceDefinition.make(name: "x", commandLine: "echo 'hi")
        }
        #expect(throws: ServiceDefinition.Problem.environmentName("1X")) {
            try ServiceDefinition.make(name: "x", commandLine: "run", environment: [("1X", "y")])
        }
        #expect(throws: ServiceDefinition.Problem.environmentName("")) {
            try ServiceDefinition.make(name: "x", commandLine: "run", environment: [("", "value")])
        }
        #expect(throws: ServiceDefinition.Problem.duplicateEnvironment("A")) {
            try ServiceDefinition.make(name: "x", commandLine: "run", environment: [("A", "1"), ("A", "2")])
        }
    }
}
