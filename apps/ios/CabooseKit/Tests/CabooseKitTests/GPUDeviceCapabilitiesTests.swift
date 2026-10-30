#if canImport(CabooseGPUStream)
import Foundation
import Testing
@testable import CabooseKit

/// Opt-in device check; writes actual linked-MoltenVK evidence for comparison with profiles.
@Suite(.serialized)
struct GPUDeviceCapabilitiesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CABOOSE_GPU_CAPABILITIES"] != nil))
    func linkedDriverReportsConsistentBCSupport() throws {
        let data = try GPUDeviceCapabilities.queryJSON()
        let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(report["schemaVersion"] as? Int == 1)
        let devices = try #require(report["devices"] as? [[String: Any]])
        #expect(!devices.isEmpty)
        for device in devices {
            let features = try #require(device["features"] as? [String: Any])
            let formats = try #require(device["bcFormats"] as? [[String: Any]])
            #expect(formats.count == 16)
            let hasBC = try #require(features["textureCompressionBC"] as? Bool)
            for format in formats {
                let sampled = try #require(format["sampledOptimal"] as? Bool)
                if hasBC { #expect(sampled) }
                if sampled { #expect(format["sampledImage2DResult"] as? Int == 0) }
            }
            // Unsupported geometry or culling is a valid result, not a test failure.
            _ = try #require(features["geometryShader"] as? Bool)
            _ = try #require(features["shaderCullDistance"] as? Bool)
        }
        let output = try #require(ProcessInfo.processInfo.environment["CABOOSE_GPU_CAPABILITIES"])
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
#endif
