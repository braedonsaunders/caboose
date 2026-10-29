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
        print("Computer collection: migration identity, selection, re-pair, host scoping, serialization and console URL passed")
    }
}
