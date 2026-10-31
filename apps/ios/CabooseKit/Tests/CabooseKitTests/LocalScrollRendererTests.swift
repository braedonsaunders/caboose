import Foundation
import Metal
import Testing
@testable import CabooseKit

/// The GPU signature kernel against its CPU definition, and composition drawing, on this
/// machine's GPU.
struct LocalScrollRendererTests {
    static func picture(width: Int, height: Int, seed: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 | 1
        for i in 0..<(width * height) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes[i * 4] = UInt8(truncatingIfNeeded: state)
            bytes[i * 4 + 1] = UInt8(truncatingIfNeeded: state >> 8)
            bytes[i * 4 + 2] = UInt8(truncatingIfNeeded: state >> 16)
            bytes[i * 4 + 3] = 255
        }
        return bytes
    }

    static func texture(_ bytes: [UInt8], width: Int, height: Int, device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return texture
    }

    static func read(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    @Test(arguments: [ScrollAxis.vertical, .horizontal])
    func signatureKernelMatchesItsDefinition(axis: ScrollAxis) async throws {
        let renderer = try #require(LocalScrollRenderer.shared)
        let width = 517, height = 301
        let bytes = Self.picture(width: width, height: height, seed: 3)
        let source = Self.texture(bytes, width: width, height: height, device: renderer.device)
        let gpu: ScrollSignature = try await withCheckedThrowingContinuation { continuation in
            renderer.capture(source, axis: axis) { copy, signature in
                if let signature, copy != nil { continuation.resume(returning: signature) }
                else { continuation.resume(throwing: CancellationError()) }
            }
        }
        let cpu = bytes.withUnsafeBytes {
            ScrollSignature(axis: axis, bands: ScrollSignature.bandCount(span: axis == .vertical ? width : height),
                            width: width, height: height, rowBytes: width * 4, bgra: $0)
        }
        #expect(gpu.lines == cpu.lines && gpu.bands == cpu.bands && gpu.span == cpu.span)
        let worst = zip(gpu.luma, cpu.luma).map { abs($0 - $1) }.max() ?? 0
        let worstDetail = zip(gpu.detail, cpu.detail).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 0.01)
        #expect(worstDetail < 0.01)
    }

    /// A page scrolled by 37 rows under a fixed 20-row header, measured from GPU signatures
    /// and drawn back at the old position: the region shows the old picture exactly.
    @Test func measuredCompositionRedrawsTheEarlierPosition() async throws {
        let renderer = try #require(LocalScrollRenderer.shared)
        let width = 200, height = 400, header = 20, shift = 37
        let page = Self.picture(width: width, height: height + shift, seed: 9)
        func frame(offset: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let sourceRow = y < header ? y : y + offset
                for x in 0..<(width * 4) { bytes[y * width * 4 + x] = page[sourceRow * width * 4 + x] }
            }
            return bytes
        }
        let older = frame(offset: 0), newer = frame(offset: shift)
        func signature(_ bytes: [UInt8]) async throws -> (MTLTexture, ScrollSignature) {
            let source = Self.texture(bytes, width: width, height: height, device: renderer.device)
            return try await withCheckedThrowingContinuation { continuation in
                renderer.capture(source, axis: .vertical) { copy, signature in
                    if let copy, let signature { continuation.resume(returning: (copy, signature)) }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            }
        }
        let (olderTexture, olderSignature) = try await signature(older)
        let (newerTexture, newerSignature) = try await signature(newer)
        let measurement = ScrollMotionEstimator().measure(from: olderSignature, to: newerSignature, expected: -64...128)
        guard case .moved(let motion) = measurement else { Issue.record("expected motion, got \(measurement)"); return }
        #expect(motion.shift == shift)
        #expect(motion.lines.lowerBound == header)
        let region = ScrollRegion(along: motion.lines, across: newerSignature.pixels(of: motion.bands))
        // Show the newer picture at the older position: line y of it shows at y + shift.
        let composition = ScrollComposition(axis: .vertical, base: 2, region: region,
            layers: [.init(frame: 1, shift: 0, lines: region.along),
                     .init(frame: 2, shift: shift, lines: (region.along.lowerBound + shift)..<region.along.upperBound)],
            blank: 0, fillFrom: nil)
        let target = Self.texture([UInt8](repeating: 0, count: width * height * 4), width: width, height: height, device: renderer.device)
        let commands = try #require(renderer.queue.makeCommandBuffer())
        #expect(renderer.encode(composition, textures: [1: olderTexture, 2: newerTexture], fill: SIMD3(1, 1, 1), into: target, commands: commands))
        await withCheckedContinuation { continuation in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }
        #expect(Self.read(target) == older)
    }
}
