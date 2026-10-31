import Foundation

/// Desktop IDs and declared StartupWMClass identify windows; titles and Exec do not.
public enum AppWindowIdentity {
    /// A window the computer knows was launched from a desktop entry belongs to that entry
    /// alone; otherwise its class decides.
    public static func matches(desktopID: String, startupWMClass: String? = nil, launchedFrom: String?,
                               instance: String?, name: String?) -> Bool {
        if let launchedFrom { return launchedFrom.lowercased() == desktopID.lowercased() }
        guard let instance, let name else { return false }
        return matches(desktopID: desktopID, startupWMClass: startupWMClass, instance: instance, name: name)
    }

    public static func matches(desktopID: String, startupWMClass: String? = nil,
                               instance: String, name: String) -> Bool {
        let names = [instance, name].map { $0.lowercased() }.filter { !$0.isEmpty }
        if let declared = startupWMClass?.trimmingCharacters(in: .whitespacesAndNewlines),
           !declared.isEmpty, names.contains(declared.lowercased()) { return true }
        let lowered = desktopID.lowercased()
        let id = lowered.hasSuffix(".desktop") ? String(lowered.dropLast(8)) : lowered
        guard !id.isEmpty else { return false }
        // Preserve desktop-ID compatibility for hosts without declared class metadata.
        return names.contains { $0 == id || id.hasSuffix($0) || $0.hasSuffix(id) }
    }
}
