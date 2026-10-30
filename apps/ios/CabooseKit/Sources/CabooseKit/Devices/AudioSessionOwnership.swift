import Foundation

/// Ordered temporary owners over a persistent configuration. Removing an older owner
/// cannot restore it over a newer one; changing the base retires existing leases.
struct AudioSessionOwnership<Configuration> {
    private(set) var base: Configuration
    private var leases: [(UUID, Configuration)] = []
    init(_ base: Configuration) { self.base = base }
    var current: Configuration { leases.last?.1 ?? base }
    var hasLeases: Bool { !leases.isEmpty }
    mutating func acquire(_ configuration: Configuration) -> UUID {
        let id = UUID(); leases.append((id, configuration)); return id
    }
    func contains(_ id: UUID) -> Bool { leases.last?.0 == id }
    mutating func release(_ id: UUID) -> Bool {
        guard let index = leases.firstIndex(where: { $0.0 == id }) else { return false }
        let changed = index == leases.count - 1
        leases.remove(at: index)
        return changed
    }
    mutating func replace(_ configuration: Configuration) {
        base = configuration; leases.removeAll()
    }
}

#if os(iOS)
import AVFoundation

/// Process-wide category ownership. Audio producers keep their existing activation policy;
/// temporary recording owners release through this coordinator instead of stale snapshots.
@MainActor public enum CabooseAudioSession {
    public struct Configuration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let policy: AVAudioSession.RouteSharingPolicy
        let options: AVAudioSession.CategoryOptions
        public init(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                    policy: AVAudioSession.RouteSharingPolicy = .default,
                    options: AVAudioSession.CategoryOptions = []) {
            self.category = category; self.mode = mode; self.policy = policy; self.options = options
        }
        static var actual: Self {
            let s = AVAudioSession.sharedInstance()
            return Self(s.category, mode: s.mode, policy: s.routeSharingPolicy, options: s.categoryOptions)
        }
        func apply() throws {
            try AVAudioSession.sharedInstance().setCategory(category, mode: mode, policy: policy, options: options)
        }
    }
    private static var owners = AudioSessionOwnership(Configuration.actual)
    public static func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                                   policy: AVAudioSession.RouteSharingPolicy = .default,
                                   options: AVAudioSession.CategoryOptions = []) throws {
        let config = Configuration(category, mode: mode, policy: policy, options: options)
        try config.apply()
        owners.replace(config)
    }
    public static func acquire(_ configuration: Configuration) throws -> UUID {
        if !owners.hasLeases { owners.replace(.actual) }
        try configuration.apply()
        return owners.acquire(configuration)
    }
    public static func owns(_ lease: UUID) -> Bool { owners.contains(lease) }
    public static func reapply(_ lease: UUID) throws {
        guard owns(lease) else { return }
        try owners.current.apply()
    }
    public static func release(_ lease: UUID) throws {
        guard owners.release(lease) else { return }
        try owners.current.apply()
        // Keep playback and any remaining recorder active; a departing recorder must
        // not deactivate the process-wide session underneath them.
        try AVAudioSession.sharedInstance().setActive(true)
    }
}
#endif
