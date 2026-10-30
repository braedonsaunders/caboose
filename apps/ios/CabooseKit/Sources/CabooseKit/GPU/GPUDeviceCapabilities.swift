#if canImport(CabooseGPUStream)
import CabooseGPUStream
import Foundation

/// Diagnostics from the MoltenVK linked into this app, without creating a renderer.
public enum GPUDeviceCapabilities {
    public enum QueryError: Error, Sendable {
        case allocationFailed
        case queryFailed(String)
    }

    /// Queries all physical devices, core Vulkan features, relevant limits, device extensions
    /// and every BC format's sampled-image support. Call from a background task: Metal
    /// initialization is synchronous. This does not modify a profile or promise game support.
    public static func queryJSON() throws -> Data {
        guard let report = cgpu_device_capabilities_json() else { throw QueryError.allocationFailed }
        defer { cgpu_device_capabilities_free(report) }
        let data = Data(String(cString: report).utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = object?["error"] as? String { throw QueryError.queryFailed(error) }
        return data
    }
}
#endif
