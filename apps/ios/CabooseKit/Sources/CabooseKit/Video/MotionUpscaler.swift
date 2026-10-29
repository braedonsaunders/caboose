import CoreVideo
import Accelerate
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

/// Upscales the compositor's SDR half-resolution motion pictures. A failure returns nil;
/// the video layer then scales the decoded picture itself.
final class MotionUpscaler {
    static var supported: Bool {
        #if canImport(MetalFX)
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
        return false
        #endif
    }

    #if canImport(MetalFX)
    private let renderer = SurfaceRenderer.shared
    private var scaler: MTLFXSpatialScaler?
    private var input: MTLTexture?
    private var output: MTLTexture?
    #endif

    func upscale(_ picture: CVPixelBuffer) -> CVPixelBuffer? {
        metalUpscale(picture) ?? softwareUpscale(picture)
    }

    func metalUpscale(_ picture: CVPixelBuffer) -> CVPixelBuffer? {
        #if canImport(MetalFX)
        let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
        guard CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_32BGRA,
              width > 0, height > 0, width <= 2048, height <= 2048,
              Self.supported else { return nil }
        if scaler == nil || scaler?.inputWidth != width || scaler?.inputHeight != height {
            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = width; descriptor.inputHeight = height
            descriptor.outputWidth = width * 2; descriptor.outputHeight = height * 2
            descriptor.colorTextureFormat = .bgra8Unorm; descriptor.outputTextureFormat = .bgra8Unorm
            guard let next = descriptor.makeSpatialScaler(device: renderer.device) else { return nil }
            let source = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            source.storageMode = .private; source.usage = next.colorTextureUsage
            let destination = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width * 2, height: height * 2, mipmapped: false)
            destination.storageMode = .private; destination.usage = next.outputTextureUsage
            guard let input = renderer.device.makeTexture(descriptor: source),
                  let output = renderer.device.makeTexture(descriptor: destination) else { return nil }
            self.input = input; self.output = output; scaler = next
        }
        guard let scaler, let input, let output else { return nil }
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width * 2, height * 2, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &result) == kCVReturnSuccess, let result else { return nil }
        var sourceCV: CVMetalTexture?, resultCV: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, renderer.textureCache, picture, nil,
                .bgra8Unorm, width, height, 0, &sourceCV) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, renderer.textureCache, result, nil,
                .bgra8Unorm, width * 2, height * 2, 0, &resultCV) == kCVReturnSuccess,
              let sourceCV, let resultCV, let source = CVMetalTextureGetTexture(sourceCV),
              let destination = CVMetalTextureGetTexture(resultCV), let commands = renderer.queue.makeCommandBuffer(),
              let before = commands.makeBlitCommandEncoder() else { return nil }
        before.copy(from: source, to: input); before.endEncoding()
        scaler.colorTexture = input; scaler.outputTexture = output
        scaler.inputContentWidth = width; scaler.inputContentHeight = height
        scaler.encode(commandBuffer: commands)
        guard let after = commands.makeBlitCommandEncoder() else { return nil }
        after.copy(from: output, to: destination); after.endEncoding()
        commands.commit(); commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        return result
        #else
        return nil
        #endif
    }

    /// Bilinear fallback for devices without MetalFX and for allocation or GPU failures.
    func softwareUpscale(_ picture: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
        guard CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_32BGRA,
              width > 0, height > 0, width <= 2048, height <= 2048 else { return nil }
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width * 2, height * 2, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &output) == kCVReturnSuccess, let output else { return nil }
        guard CVPixelBufferLockBaseAddress(picture, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let source = CVPixelBufferGetBaseAddress(picture), let destination = CVPixelBufferGetBaseAddress(output) else { return nil }
        var input = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                  rowBytes: CVPixelBufferGetBytesPerRow(picture))
        var result = vImage_Buffer(data: destination, height: vImagePixelCount(height * 2), width: vImagePixelCount(width * 2),
                                   rowBytes: CVPixelBufferGetBytesPerRow(output))
        guard vImageScale_ARGB8888(&input, &result, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return output
    }
}
