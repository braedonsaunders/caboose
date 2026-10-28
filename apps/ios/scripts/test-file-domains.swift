// Compiled alongside FileDomains.swift by test-file-domains.py with a fake system boundary.
import Foundation

struct Credentials { let fileDomainIdentifier: String }
struct NSFileProviderDomainIdentifier { let rawValue: String; init(_ value: String) { rawValue = value } }
struct NSFileProviderDomain {
    let identifier: NSFileProviderDomainIdentifier
    let displayName: String
    init(identifier: NSFileProviderDomainIdentifier, displayName: String) {
        self.identifier = identifier; self.displayName = displayName
    }
}
struct NSFileProviderItemIdentifier {
    let value: String
    static let workingSet = Self(value: "working")
    static let rootContainer = Self(value: "root")
}
@MainActor
final class NSFileProviderManager {
    static var events: [String] = []
    static var adds: [(Error?) -> Void] = []
    static var removals: [(Error?) -> Void] = []
    let id: String
    init?(for domain: NSFileProviderDomain) { id = domain.identifier.rawValue }
    static func add(_ domain: NSFileProviderDomain, completionHandler: @escaping (Error?) -> Void) {
        events.append("add:" + domain.identifier.rawValue + ":" + domain.displayName)
        adds.append(completionHandler)
    }
    static func remove(_ domain: NSFileProviderDomain, completionHandler: @escaping (Error?) -> Void) {
        events.append("remove:" + domain.identifier.rawValue)
        removals.append(completionHandler)
    }
    func signalEnumerator(for container: NSFileProviderItemIdentifier, completionHandler: (Error?) -> Void) {
        Self.events.append("signal:" + id + ":" + container.value)
        completionHandler(nil)
    }
}

@main
struct Tests {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError("Timed out waiting for lifecycle callback")
    }
    @MainActor static func main() async {
        let a = Credentials(fileDomainIdentifier: "A"), b = Credentials(fileDomainIdentifier: "B")
        var results: [String] = []
        FileDomains.register(a, name: "First") { results.append($0 == nil ? "ok" : "failed") }
        FileDomains.remove(a)
        FileDomains.register(b, name: "Second") { results.append($0 == nil ? "ok" : "failed") }
        await until { NSFileProviderManager.adds.count == 1 }
        assert(NSFileProviderManager.events == ["add:A:First"])
        NSFileProviderManager.adds.removeFirst()(nil)
        await until { NSFileProviderManager.removals.count == 1 }
        assert(NSFileProviderManager.events == ["add:A:First", "signal:A:working", "signal:A:root", "remove:A"])
        NSFileProviderManager.removals.removeFirst()(nil)
        await until { NSFileProviderManager.adds.count == 1 }
        // Failure is reported and does not signal an unregistered domain.
        NSFileProviderManager.adds.removeFirst()(NSError(domain: "registration", code: 42))
        await until { results.count == 2 }
        assert(results == ["ok", "failed"])
        assert(NSFileProviderManager.events.last == "add:B:Second")
        FileDomains.register(b, name: "Renamed") { results.append($0 == nil ? "retry-ok" : "failed") }
        await until { NSFileProviderManager.adds.count == 1 }
        NSFileProviderManager.adds.removeFirst()(nil)
        await until { results.count == 3 }
        assert(results.last == "retry-ok")
        assert(Array(NSFileProviderManager.events.suffix(3)) == ["add:B:Renamed", "signal:B:working", "signal:B:root"])
        // Sign-out requested during an outstanding retry removes the domain after add completes.
        FileDomains.register(b, name: "Renamed") { _ in }
        await until { NSFileProviderManager.adds.count == 1 }
        FileDomains.remove(b)
        NSFileProviderManager.adds.removeFirst()(nil)
        await until { NSFileProviderManager.removals.count == 1 }
        NSFileProviderManager.removals.removeFirst()(nil)
        assert(NSFileProviderManager.events.last == "remove:B")
        print("PASS: registration/signal ordering, account switch, error propagation, retry and sign-out during add")
    }
}
