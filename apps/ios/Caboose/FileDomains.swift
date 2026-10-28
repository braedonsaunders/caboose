import Foundation
import FileProvider

/// The one paired computer is exposed as a replicated Files location.
/// Keep mutations in invocation order: a late add must never resurrect a signed-out domain.
@MainActor
enum FileDomains {
    private static var pending: Task<Void, Never>?

    private static func domain(_ credentials: Credentials, name: String = "Caboose") -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(credentials.fileDomainIdentifier), displayName: name)
    }

    private static func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await operation()
        }
    }

    static func register(_ credentials: Credentials, name: String, completion: @escaping @MainActor (Error?) -> Void) {
        enqueue {
            let error: Error? = await withCheckedContinuation { continuation in
                NSFileProviderManager.add(domain(credentials, name: name)) { continuation.resume(returning: $0) }
            }
            if error == nil { signalNow(credentials) }
            completion(error)
        }
    }

    static func remove(_ credentials: Credentials) {
        enqueue {
            let error: Error? = await withCheckedContinuation { continuation in
                NSFileProviderManager.remove(domain(credentials)) { continuation.resume(returning: $0) }
            }
            if let error { NSLog("Caboose Files removal failed: %@", error.localizedDescription) }
        }
    }

    static func signal(_ credentials: Credentials) {
        enqueue { signalNow(credentials) }
    }

    private static func signalNow(_ credentials: Credentials) {
        guard let manager = NSFileProviderManager(for: domain(credentials)) else { return }
        for container in [NSFileProviderItemIdentifier.workingSet, .rootContainer] {
            manager.signalEnumerator(for: container) { error in
                if let error { NSLog("Caboose Files signal failed: %@", error.localizedDescription) }
            }
        }
    }
}
