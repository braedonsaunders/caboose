import Foundation
import FileProvider

/// The one paired computer is exposed as a replicated Files location.
enum FileDomains {
    private static func domain(_ credentials: Credentials, name: String = "Caboose") -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(credentials.fileDomainIdentifier), displayName: name)
    }
    static func register(_ credentials: Credentials, name: String) {
        NSFileProviderManager.add(domain(credentials, name: name)) { error in
            if let error { NSLog("Caboose Files registration failed: %@", error.localizedDescription) }
        }
    }
    static func remove(_ credentials: Credentials) {
        NSFileProviderManager.remove(domain(credentials)) { error in
            if let error { NSLog("Caboose Files removal failed: %@", error.localizedDescription) }
        }
    }
    static func signal(_ credentials: Credentials) {
        guard let manager = NSFileProviderManager(for: domain(credentials)) else { return }
        for container in [NSFileProviderItemIdentifier.workingSet, .rootContainer] {
            manager.signalEnumerator(for: container) { error in
                if let error { NSLog("Caboose Files signal failed: %@", error.localizedDescription) }
            }
        }
    }
}
