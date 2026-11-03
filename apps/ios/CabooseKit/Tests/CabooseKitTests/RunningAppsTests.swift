import Foundation
import Testing
@testable import CabooseKit

/// `GET /v1/running-apps` as the phone reads it, and what the Task Manager makes of it.
struct RunningAppsTests {
    static let listing = #"""
    {
      "version": 1,
      "sampledAt": 1793500000123,
      "intervalMs": 1000,
      "machine": { "cpus": 8, "memoryBytes": 17179869184 },
      "apps": [
        {
          "id": "session.scope", "kind": "session", "desktopId": null, "name": "Caboose",
          "origin": "session", "startedAt": 0, "windows": [],
          "cpuPercent": 3.5, "memoryBytes": 314572800,
          "io": { "readBytesPerSecond": 0, "writeBytesPerSecond": 4096 },
          "gpu": null, "processCount": 14,
          "processes": [
            { "pid": 41, "ppid": 1, "name": "caboose-display", "command": "/usr/lib/caboose/display --socket /run/caboose/display.sock",
              "state": "running", "cpuPercent": 3.1, "memoryBytes": 104857600 }
          ]
        },
        {
          "id": "app-libreoffice\\x2dstartcenter-3.scope", "kind": "app", "desktopId": "libreoffice-startcenter.desktop",
          "name": "LibreOffice", "origin": "launch", "startedAt": 1793499000000, "windows": [12, 15],
          "cpuPercent": 42.25, "memoryBytes": 1288490188,
          "io": { "readBytesPerSecond": 1048576, "writeBytesPerSecond": 0 },
          "gpu": { "streams": 1, "surfaces": 2, "toPhoneBytesPerSecond": 2097152, "fromPhoneBytesPerSecond": 512 },
          "processCount": 9,
          "processes": [
            { "pid": 900, "ppid": 1, "name": "oosplash", "command": "/usr/lib/libreoffice/program/oosplash",
              "state": "sleeping", "cpuPercent": 30, "memoryBytes": 600000000, "threads": 77 },
            { "pid": 901, "ppid": 900, "name": "soffice.bin", "command": "", "state": "hibernating",
              "cpuPercent": 12.25, "memoryBytes": 300000000 },
            { "pid": "not a pid", "name": "broken" }
          ],
          "cgroup": "/owner.slice/app-libreoffice\\x2dstartcenter-3.scope"
        },
        {
          "id": "app-steam-1.scope", "kind": "app", "desktopId": "steam.desktop", "name": "Steam",
          "origin": "launch", "startedAt": 1793498000000, "windows": [],
          "cpuPercent": 1.0, "memoryBytes": 2147483648,
          "io": { "readBytesPerSecond": 0, "writeBytesPerSecond": 0 },
          "gpu": null, "processCount": 31, "processes": []
        },
        { "id": "app-term-2.scope", "kind": "app", "desktopId": null, "name": "Terminal", "origin": "terminal",
          "startedAt": 1793499500000, "windows": [], "cpuPercent": 0, "memoryBytes": 4194304,
          "io": { "readBytesPerSecond": 0, "writeBytesPerSecond": 0 }, "gpu": null, "processCount": 2, "processes": [] },
        { "id": "app-future-1.scope", "kind": "service", "desktopId": null, "name": "Future", "origin": "portal",
          "startedAt": 1, "windows": [], "cpuPercent": 0, "memoryBytes": 0,
          "io": { "readBytesPerSecond": 0, "writeBytesPerSecond": 0 }, "gpu": null, "processCount": 0, "processes": [] },
        { "kind": "app", "name": "No id" }
      ],
      "nextPoll": 2000
    }
    """#

    static func decoded() throws -> RunningAppsListing {
        try JSONDecoder().decode(RunningAppsListing.self, from: Data(listing.utf8))
    }

    // MARK: Decoding

    @Test func decodesTheListingAndItsBackslashIDs() throws {
        let listing = try Self.decoded()
        #expect(listing.version == 1)
        #expect(listing.sampledAt == 1793500000123)
        #expect(listing.measured)
        #expect(listing.machine == .init(cpus: 8, memoryBytes: 17179869184))
        // The app without an id is dropped; the others survive it.
        #expect(listing.apps.map(\.id) == ["session.scope", #"app-libreoffice\x2dstartcenter-3.scope"#, "app-steam-1.scope",
                                           "app-term-2.scope", "app-future-1.scope"])
        let libreoffice = listing.apps[1]
        #expect(libreoffice.kind == .app)
        #expect(libreoffice.origin == .launch)
        #expect(libreoffice.desktopId == "libreoffice-startcenter.desktop")
        #expect(libreoffice.windows == [12, 15])
        #expect(libreoffice.cpuPercent == 42.25)
        #expect(libreoffice.memoryBytes == 1288490188)
        #expect(libreoffice.io == .init(readBytesPerSecond: 1048576, writeBytesPerSecond: 0))
        #expect(libreoffice.gpu == .init(streams: 1, surfaces: 2, toPhoneBytesPerSecond: 2097152, fromPhoneBytesPerSecond: 512))
        #expect(libreoffice.processCount == 9)
    }

    @Test func nullsAreAbsentNotFailures() throws {
        let listing = try Self.decoded()
        let session = try #require(listing.apps.first)
        #expect(session.kind == .session)
        #expect(session.desktopId == nil)
        #expect(session.gpu == nil)
        #expect(session.isSession)
    }

    @Test func unknownValuesAndFieldsAreTolerated() throws {
        let listing = try Self.decoded()
        let future = listing.apps[4]
        #expect(future.kind == .other)
        #expect(future.origin == .other)
        let processes = listing.apps[1].processes
        // An unreadable process is dropped; an unknown state is `other`.
        #expect(processes.map(\.pid) == [900, 901])
        #expect(processes[0].state == .sleeping)
        #expect(processes[1].state == .other)
        #expect(processes[1].command.isEmpty)
    }

    @Test func aFirstSampleHasNoRates() throws {
        let json = #"{"version":1,"sampledAt":5,"intervalMs":0,"machine":{"cpus":2,"memoryBytes":1024},"apps":[]}"#
        let listing = try JSONDecoder().decode(RunningAppsListing.self, from: Data(json.utf8))
        #expect(!listing.measured)
        #expect(listing.apps.isEmpty)
    }

    @Test func wholeFloatsReadAsIntegers() throws {
        let json = #"{"id":"app-x-1.scope","kind":"app","name":"X","memoryBytes":2048.0,"processCount":3.0}"#
        let app = try JSONDecoder().decode(RunningApp.self, from: Data(json.utf8))
        #expect(app.memoryBytes == 2048)
        #expect(app.processCount == 3)
        #expect(app.windows.isEmpty)
        #expect(app.io == .init())
    }

    @Test func actionRepliesDecode() throws {
        let quit = try JSONDecoder().decode(RunningAppQuitReply.self, from: Data(#"{"closed":2}"#.utf8))
        #expect(quit.closed == 2)
        let end = try JSONDecoder().decode(RunningAppEndReply.self, from: Data(#"{"ended":true,"killed":false,"extra":1}"#.utf8))
        #expect(end == .init(ended: true, killed: false))
    }

    // MARK: Routes

    @Test func idsArePercentEncodedAsOneSegment() {
        #expect(RunningAppsRoute.path(.quit, id: #"app-libreoffice\x2dstartcenter-3.scope"#)
                == "/v1/running-apps/app-libreoffice%5Cx2dstartcenter-3.scope/quit")
        #expect(RunningAppsRoute.path(.forceQuit, id: "app-steam_app_570-1.scope")
                == "/v1/running-apps/app-steam_app_570-1.scope/force-quit")
        #expect(RunningAppsRoute.path(.kill, id: "a/b?c#d%e f") == "/v1/running-apps/a%2Fb%3Fc%23d%25e%20f/kill")
        #expect(RunningAppsRoute.encode("é") == "%C3%A9")
        #expect(RunningAppsRoute.list == "/v1/running-apps")
    }

    @Test func anEncodedIDRoundTrips() {
        let id = #"app-org.gnome.Calculator\x2dbeta-12.scope"#
        #expect(RunningAppsRoute.encode(id).removingPercentEncoding == id)
        #expect(URL(string: "http://host:7310" + RunningAppsRoute.path(.quit, id: id)) != nil)
    }

    // MARK: Presentation

    @Test func theSessionIsApartAndAppsSort() throws {
        let listing = try Self.decoded()
        #expect(TaskManager.session(in: listing)?.id == "session.scope")
        #expect(TaskManager.apps(in: listing, sortedBy: .cpu).map(\.name) == ["LibreOffice", "Steam", "Future", "Terminal"])
        #expect(TaskManager.apps(in: listing, sortedBy: .memory).map(\.name) == ["Steam", "LibreOffice", "Terminal", "Future"])
        #expect(TaskManager.apps(in: listing, sortedBy: .name).map(\.name) == ["Future", "LibreOffice", "Steam", "Terminal"])
    }

    @Test func processesSort() throws {
        let processes = try Self.decoded().apps[1].processes
        #expect(TaskManager.sorted(processes, by: .cpu).map(\.pid) == [900, 901])
        #expect(TaskManager.sorted(processes, by: .name).map(\.pid) == [900, 901])
        let named: [RunningApp.Process] = [.init(pid: 3, name: "zsh", memoryBytes: 5), .init(pid: 2, name: "Xorg", memoryBytes: 9),
                                           .init(pid: 1, name: "zsh", memoryBytes: 5)]
        #expect(TaskManager.sorted(named, by: .name).map(\.pid) == [2, 1, 3])
        #expect(TaskManager.sorted(named, by: .memory).map(\.pid) == [2, 1, 3])
    }

    @Test func windowlessAppsAreBackgroundExceptTerminals() throws {
        let apps = try Self.decoded().apps
        #expect(apps[1].presence == .windows(2))
        #expect(apps[2].presence == .background)
        #expect(apps[2].isBackground)
        #expect(apps[3].presence == .terminal)
        #expect(!apps[3].isBackground)
        #expect(!apps[0].isBackground)
    }

    @Test func onlyAppsWithWindowsQuitAndTheSessionNeverEnds() throws {
        let apps = try Self.decoded().apps
        #expect(!apps[0].canQuit && !apps[0].canEnd)
        #expect(apps[1].canQuit && apps[1].canEnd)
        #expect(!apps[2].canQuit && apps[2].canEnd)
    }

    @Test func totalsAreAgainstTheMachine() throws {
        let totals = TaskManager.totals(try Self.decoded())
        #expect(totals.cpuPercent == 46.75)
        #expect(totals.memoryBytes == 314572800 + 1288490188 + 2147483648 + 4194304)
        #expect(abs(totals.cpuShare - 46.75 / 800) < 1e-9)
        #expect(abs(totals.memoryShare - Double(totals.memoryBytes) / 17179869184) < 1e-9)
        let empty = TaskManager.Totals(cpuPercent: 50, memoryBytes: 10, cpus: 0, machineMemoryBytes: 0)
        #expect(empty.cpuShare == 0 && empty.memoryShare == 0)
        let over = TaskManager.Totals(cpuPercent: 900, memoryBytes: 20, cpus: 8, machineMemoryBytes: 10)
        #expect(over.cpuShare == 1 && over.memoryShare == 1)
    }

    @Test func formatsBytesRatesAndPercentages() {
        #expect(TaskManager.bytes(0) == "0 B")
        #expect(TaskManager.bytes(512) == "512 B")
        #expect(TaskManager.bytes(1536) == "1.5 KB")
        #expect(TaskManager.bytes(340 * 1024 * 1024) == "340 MB")
        #expect(TaskManager.bytes(1288490188) == "1.2 GB")
        #expect(TaskManager.bytes(1024 * 1024 - 20) == "1.0 MB")
        #expect(TaskManager.bytes(-5) == "0 B")
        #expect(TaskManager.rate(0) == "0 B/s")
        #expect(TaskManager.rate(2097152) == "2.0 MB/s")
        #expect(TaskManager.percent(0) == "0%")
        #expect(TaskManager.percent(0.01) == "0%")
        #expect(TaskManager.percent(3.14) == "3.1%")
        #expect(TaskManager.percent(9.97) == "10%")
        #expect(TaskManager.percent(142.4) == "142%")
        #expect(TaskManager.percent(-.infinity) == "0%")
    }

    // MARK: A dock entry's running apps

    @Test func aDockEntryMatchesByWindowThenDesktopID() throws {
        let apps = try Self.decoded().apps
        // A window it shows decides, whatever its desktop id.
        #expect(TaskManager.matching(windowIDs: [15], desktopID: "org.libreoffice.LibreOffice.desktop", in: apps).map(\.id)
                == [#"app-libreoffice\x2dstartcenter-3.scope"#])
        // Steam closed to its tray has no window: its desktop entry finds it.
        #expect(TaskManager.matching(windowIDs: [], desktopID: "steam.desktop", in: apps).map(\.id) == ["app-steam-1.scope"])
        #expect(TaskManager.matching(windowIDs: [], desktopID: "Steam", in: apps).map(\.id) == ["app-steam-1.scope"])
        // Both, each once, windows first.
        let second = RunningApp(id: "app-libreoffice\\x2dstartcenter-4.scope", desktopId: "libreoffice-startcenter.desktop", name: "LibreOffice")
        #expect(TaskManager.matching(windowIDs: [12], desktopID: "libreoffice-startcenter.desktop", in: apps + [second]).map(\.id)
                == [#"app-libreoffice\x2dstartcenter-3.scope"#, #"app-libreoffice\x2dstartcenter-4.scope"#])
        #expect(TaskManager.matching(windowIDs: [99], desktopID: "gimp.desktop", in: apps).isEmpty)
        #expect(TaskManager.matching(windowIDs: [], desktopID: nil, in: apps).isEmpty)
    }

    @Test func theSessionIsNeverADockEntry() {
        let session = RunningApp(id: "session.scope", kind: .session, desktopId: "xfce4-terminal.desktop", name: "Caboose", windows: [3])
        #expect(TaskManager.matching(windowIDs: [3], desktopID: "xfce4-terminal.desktop", in: [session]).isEmpty)
    }

    @Test func dockMenuOffersOneQuit() throws {
        let apps = try Self.decoded().apps
        #expect(DockMenu.Ending([apps[1]]) == .init(canQuit: true, canForceQuit: true))
        #expect(DockMenu.Ending([apps[2]]) == .init(canQuit: false, canForceQuit: true))
        #expect(DockMenu.Ending([apps[0]]) == nil)
        #expect(DockMenu.Ending([]) == nil)
        let actions = DockMenu.actions(appName: "Steam", pinned: true, windows: [], ending: DockMenu.Ending([apps[2]]))
        // A windowless app (Steam in its tray) still gets Quit; quitting it asks to force-quit.
        #expect(actions == [.open, .unpin, .quit])
        #expect(actions.map(\.title) == ["Open", "Unpin", "Quit"])
        let libreoffice = DockMenu.actions(appName: "LibreOffice", pinned: false, windows: [.init(id: 12, title: "Home")],
                                       ending: .init(canQuit: true, canForceQuit: true))
        #expect(libreoffice == [.open, .pin, .quit])
    }

    // MARK: Quit, then Force Quit

    @Test func anAppStillRunningAfterQuitIsOfferedForceQuitOnce() {
        var follow = QuitFollowUp()
        let start = Date(timeIntervalSince1970: 1000)
        follow.quitRequested("a", at: start)
        follow.quitRequested("b", at: start.addingTimeInterval(1))
        #expect(follow.due(listed: ["a", "b"], now: start.addingTimeInterval(4)).isEmpty)
        #expect(follow.due(listed: ["a", "b"], now: start.addingTimeInterval(5)) == ["a"])
        #expect(follow.due(listed: ["a", "b"], now: start.addingTimeInterval(5.5)).isEmpty)
        // b quit before its time was up.
        #expect(follow.due(listed: ["a"], now: start.addingTimeInterval(7)).isEmpty)
        #expect(follow.pending.isEmpty)
    }

    @Test func forgottenAppsAreNotOffered() {
        var follow = QuitFollowUp(delay: 2)
        let start = Date(timeIntervalSince1970: 0)
        follow.quitRequested("a", at: start)
        follow.forget("a")
        #expect(follow.due(listed: ["a"], now: start.addingTimeInterval(10)).isEmpty)
    }

    @Test func gpuPlacementOffersARelaunchOnlyForAQuittableAppOnTheCPU() throws {
        func decode(_ placement: String, windows: String = "[3]", desktop: String = "\"org.gnome.Maps.desktop\"") throws -> RunningApp {
            try JSONDecoder().decode(RunningApp.self, from: Data(#"""
            {"id": "app-org.gnome.Maps-4.scope", "kind": "app", "desktopId": \#(desktop), "name": "Maps", "origin": "launch",
             "windows": \#(windows), "gpuPlacement": \#(placement)}
            """#.utf8))
        }
        #expect(try decode("\"cpu-until-relaunch\"").gpuPlacement == .cpuUntilRelaunch)
        #expect(try decode("\"cpu-until-relaunch\"").canRelaunchOnPhoneGPU)
        #expect(try decode("\"phone\"").canRelaunchOnPhoneGPU == false)
        #expect(try decode("\"warp\"").gpuPlacement == nil)
        #expect(try decode("null").gpuPlacement == nil)
        #expect(try decode("\"cpu-until-relaunch\"", windows: "[]").canRelaunchOnPhoneGPU == false)
        #expect(try decode("\"cpu-until-relaunch\"", desktop: "null").canRelaunchOnPhoneGPU == false)
    }
}
