import Foundation

@main
struct ComputerSwitcherTests {
    static func main() throws {
        let host = URL(string: "https://computer.example.com")!
        let first = Credentials(hostURL: host, token: "phone-one", computerID: "one", computerName: "Studio")
        let second = Credentials(hostURL: host, token: "phone-two", computerID: "two", computerName: "Workshop")
        var collection = Credentials.Collection()
        let saved = collection.select(first)
        precondition(saved.id == first.id, "migration must preserve existing Files/cache identity")
        _ = collection.select(second)
        precondition(collection.computers.count == 2 && collection.active?.computerName == "Workshop")
        _ = collection.select(saved)
        precondition(collection.computers.count == 2 && collection.active?.id == first.id)
        let renewed = Credentials(hostURL: host, token: "renewed", computerID: "one", computerName: "Studio renamed")
        let replaced = collection.select(renewed)
        precondition(replaced.id == first.id && replaced.token == "renewed", "re-pair retains stable identity")
        precondition(collection.computers.count == 2)
        let otherHost = Credentials(hostURL: URL(string: "https://other.example.com")!, token: "other", computerID: "one")
        _ = collection.select(otherHost)
        precondition(collection.computers.count == 3, "server ids are host scoped")
        let data = try JSONEncoder().encode(collection)
        let decoded = try JSONDecoder().decode(Credentials.Collection.self, from: data)
        precondition(decoded.computers == collection.computers && decoded.activeID == collection.activeID)
        var addresses = replaced
        addresses.addAlternate(URL(string: "https://remote.example.com")!)
        precondition(addresses.id == replaced.id)
        precondition(Credentials(hostURL: URL(string: "https://user:secret@example.com/?token=secret")!, token: "secret").consoleURL == nil)
        precondition(first.consoleURL?.absoluteString == host.absoluteString)

        // A host sign-in: one per host, its open computer kept in it, never merged with a
        // pairing of one computer, and a Files identity per computer it opens.
        var hosts = Credentials.Collection()
        let paired = hosts.select(Credentials(hostURL: host, token: "phone-one", scope: .computer, computerID: "c-1", computerName: "Studio"))
        let signedIn = hosts.select(Credentials(hostURL: host, token: "host-token", scope: .host))
        precondition(hosts.computers.count == 2 && signedIn.isHostSignIn && signedIn.routeComputer == nil)
        precondition(signedIn.fileDomainIdentifier == signedIn.id, "no computer open: the sign-in's own identity")
        let opened = hosts.select(signedIn.opening(computer: "c-1", name: "Studio"))
        precondition(hosts.computers.count == 2, "opening a computer on the host is not a new pairing, nor the one-computer pairing")
        precondition(opened.id == signedIn.id && opened.routeComputer == "c-1")
        precondition(opened.fileDomainIdentifier != paired.fileDomainIdentifier && opened.fileDomainIdentifier.hasPrefix(signedIn.id + "."))
        let other = opened.opening(computer: "c-2", name: "Workshop")
        precondition(other.fileDomainIdentifier != opened.fileDomainIdentifier && other.id == opened.id)
        precondition(paired.routeComputer == nil, "a computer's own pairing uses the unscoped routes")
        let renewedHost = hosts.select(Credentials(hostURL: URL(string: "https://Computer.example.com/")!, token: "host-token-2", scope: .host))
        precondition(hosts.computers.count == 2 && renewedHost.id == signedIn.id && renewedHost.computerID == "c-1",
                     "signing in to the host again keeps its identity and the computer it had open")
        let closed = opened.opening(computer: nil, name: "ignored")
        precondition(closed.computerID == nil && closed.computerName == nil)
        let legacy = try JSONDecoder().decode(Credentials.self, from: JSONEncoder().encode(Credentials(hostURL: host, token: "owner-token")))
        precondition(legacy.scope == nil && legacy.routeComputer == nil, "an owner token uses the unscoped routes")
        let reloaded = try JSONDecoder().decode(Credentials.Collection.self, from: JSONEncoder().encode(hosts))
        precondition(reloaded.computers == hosts.computers && reloaded.active?.isHostSignIn == true)

        // Titles: the name the host gave itself, kept across re-selection, before the address.
        var named = Credentials.Collection()
        let unnamed = named.select(Credentials(hostURL: URL(string: "https://lucid-gpu.tailea5249.ts.net")!, token: "host", scope: .host))
        precondition(unnamed.hostName == "lucid-gpu.tailea5249.ts.net" && unnamed.addressName == "lucid-gpu.tailea5249.ts.net")
        var learned = unnamed
        learned.hostLabel = "Den"
        _ = named.select(learned)
        let reopened = named.select(unnamed.opening(computer: "c-1", name: "Studio"))
        precondition(reopened.hostLabel == "Den" && reopened.hostName == "Den" && reopened.displayName == "Studio",
                     "a learned host name survives opening another computer")
        let fromBefore = try JSONDecoder().decode(Credentials.self, from: Data(#"{"hostURL":"https://computer.example.com","token":"t","alternateURLs":[]}"#.utf8))
        precondition(fromBefore.hostLabel == nil && fromBefore.hostName == "computer.example.com", "sign-ins saved before host names decode")
        let roundTripped = try JSONDecoder().decode(Credentials.self, from: JSONEncoder().encode(reopened))
        precondition(roundTripped.hostLabel == "Den")

        // Removing: the active one hands over to the first left; another leaves the active alone.
        var three = Credentials.Collection()
        let a = three.select(Credentials(hostURL: host, token: "a", computerID: "a"))
        let b = three.select(Credentials(hostURL: host, token: "b", computerID: "b"))
        let c = three.select(Credentials(hostURL: host, token: "c", computerID: "c"))
        three.remove(id: a.id)
        precondition(three.computers.map(\.id) == [b.id, c.id] && three.activeID == c.id)
        three.remove(id: c.id)
        precondition(three.computers.map(\.id) == [b.id] && three.activeID == b.id)
        three.remove(id: b.id)
        precondition(three.computers.isEmpty && three.activeID == nil)
        print("Computer collection: migration identity, selection, re-pair, host scoping, host sign-ins, serialization, console URL, titles and removal passed")
    }
}
