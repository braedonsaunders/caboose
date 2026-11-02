import Foundation
import Testing
@testable import CabooseKit

/// A host's computers as a host sign-in sees them: which one opens, whether another can be
/// made, the sizes offered and the name suggested.
@Suite struct HostComputerListTests {
    static let json = #"""
    {"computers":[
      {"id":"owner","createdAt":null,"state":"parked","settings":{"name":"Studio","memoryMb":4096,"vcpus":2,"idleMs":600000},"boot":null},
      {"id":"c-0123456789","createdAt":"2026-10-01T00:00:00Z","state":"running","settings":{"name":"Workshop","memoryMb":8192,"vcpus":4,"idleMs":600000},
       "boot":{"id":"b","state":"succeeded","startedAt":"2026-11-01T10:00:00Z","finishedAt":"2026-11-01T10:01:00Z","error":null,"steps":[]}}],
     "canCreate":true,"limits":{"computers":3,"running":null},"defaultComputer":"c-0123456789",
     "sizes":[{"id":"micro","name":"Micro","memoryMb":1024,"vcpus":1,"available":true},
              {"id":"standard","name":"Standard","memoryMb":4096,"vcpus":2,"available":true},
              {"id":"gpu","name":"GPU","memoryMb":16384,"vcpus":8,"available":false}]}
    """#

    func list() throws -> HostComputerList { try JSONDecoder().decode(HostComputerList.self, from: Data(Self.json.utf8)) }

    @Test func listDecodes() throws {
        let list = try list()
        #expect(list.computers.map(\.id) == ["owner", "c-0123456789"])
        #expect(list.computers[1].boot?.state == .succeeded)
        #expect(list.limits == .init(computers: 3, running: nil))
        #expect(list.availableSizes.map(\.id) == ["micro", "standard"])
        #expect(list.suggestedSize?.id == "standard")
        #expect(list.allowsCreating && list.creationBlocker == nil)
    }

    @Test func anEmptyHostDecodes() throws {
        let empty = try JSONDecoder().decode(HostComputerList.self, from: Data(#"{"computers":[],"canCreate":true,"limits":{"computers":32,"running":4},"defaultComputer":null,"sizes":[{"id":"micro","name":"Micro","memoryMb":1536,"vcpus":1,"available":true}]}"#.utf8))
        #expect(empty.computers.isEmpty && empty.preferred(selected: nil) == nil)
        #expect(empty.suggestedSize?.id == "micro")
        #expect(empty.sizes[0].summary == "1.5 GB memory · 1 CPU")
        // An older host lists no sizes or default.
        let older = try JSONDecoder().decode(HostComputerList.self, from: Data(#"{"computers":[],"canCreate":false}"#.utf8))
        #expect(older.sizes.isEmpty && older.defaultComputer == nil && !older.allowsCreating)
        #expect(older.creationBlocker != nil)
    }

    @Test func theComputerToOpen() throws {
        let list = try list()
        #expect(list.preferred(selected: "owner")?.id == "owner", "the computer chosen before")
        #expect(list.preferred(selected: "c-gone")?.id == "c-0123456789", "else the host's default")
        #expect(list.preferred(selected: nil)?.id == "c-0123456789")
        var noDefault = list
        noDefault.defaultComputer = nil
        #expect(noDefault.preferred(selected: nil)?.id == "owner", "else the first")
    }

    @Test func whyAComputerCannotBeMade() throws {
        var full = try list()
        full.limits = .init(computers: 2, running: nil)
        #expect(full.isFull && !full.allowsCreating && full.creationBlocker?.contains("slot") == true)
        var noRoom = try list()
        noRoom.sizes = noRoom.sizes.map { var size = $0; size.available = false; return size }
        #expect(!noRoom.allowsCreating && noRoom.suggestedSize == nil)
    }

    @Test func statesReadInWords() throws {
        let list = try list()
        #expect(list.computers.map(\.stateTitle) == ["Parked", "Running"])
        var starting = list.computers[0]
        starting.boot = ComputerBoot(id: "b", state: .running, startedAt: "", steps: [])
        #expect(starting.stateTitle == "Starting")
        starting.boot?.state = .failed
        #expect(starting.stateTitle == "Didn't start")
    }

    @Test func suggestedNames() {
        #expect(HostComputerList.suggestedName(deviceName: "Sam’s iPhone", existing: []) == "Sam’s Computer")
        #expect(HostComputerList.suggestedName(deviceName: "Sam's iPad", existing: ["sam's computer"]) == "Sam's Computer 2")
        #expect(HostComputerList.suggestedName(deviceName: "iPhone", existing: []) == "My Computer")
        #expect(HostComputerList.suggestedName(deviceName: "iPhone", existing: ["My Computer", "My Computer 2"]) == "My Computer 3")
    }
}
