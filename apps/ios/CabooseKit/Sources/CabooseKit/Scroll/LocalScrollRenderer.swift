import Foundation
import Metal
import QuartzCore

/// The GPU side of phone-owned scrolling: copies captured pictures into history textures,
/// computes their line signatures, and draws a `ScrollComposition`.
///
/// Everything runs on `SurfaceRenderer.shared.queue`, the queue every window picture is
/// written on, so a capture copies exactly the picture as it stood when it was taken.
public final class LocalScrollRenderer: @unchecked Sendable {
    public static let shared: LocalScrollRenderer? = LocalScrollRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let signature: MTLComputePipelineState
    private let vertex: MTLFunction, sample: MTLFunction, resolve: MTLFunction
    private let lock = NSLock()
    private var pool: [MTLTexture] = []
    private var pipelines: [MTLPixelFormat: (textured: MTLRenderPipelineState, resolve: MTLRenderPipelineState)] = [:]
    /// Layers one resolve pass draws, and fixed overlays per layer: the history kept, the
    /// pinned picture of a prefetch, and the estimator's four overlays.
    static let maximumLayers = 8, maximumHoles = 4

    private init?() {
        let renderer = SurfaceRenderer.shared
        device = renderer.device
        queue = renderer.queue
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            guard let kernel = library.makeFunction(name: "scroll_signature"),
                  let vertex = library.makeFunction(name: "scroll_quad_vertex"),
                  let sample = library.makeFunction(name: "scroll_quad_texture"),
                  let resolve = library.makeFunction(name: "scroll_resolve") else { return nil }
            signature = try device.makeComputePipelineState(function: kernel)
            self.vertex = vertex; self.sample = sample; self.resolve = resolve
            guard pipelines(for: .bgra8Unorm) != nil else { return nil }
        } catch {
            return nil
        }
    }

    /// The drawing pipelines for a target pixel format, made once.
    private func pipelines(for format: MTLPixelFormat) -> (textured: MTLRenderPipelineState, resolve: MTLRenderPipelineState)? {
        lock.lock(); defer { lock.unlock() }
        if let made = pipelines[format] { return made }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = sample
        descriptor.colorAttachments[0].pixelFormat = format
        guard let textured = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        descriptor.fragmentFunction = resolve
        guard let resolved = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[format] = (textured, resolved)
        return (textured, resolved)
    }

    /// The layer format that shows pictures of `format` unchanged: the same encoding, in
    /// one of the formats a CAMetalLayer accepts.
    public static func layerFormat(for format: MTLPixelFormat) -> MTLPixelFormat {
        switch format {
        case .bgra8Unorm_srgb, .rgba8Unorm_srgb: return .bgra8Unorm_srgb
        case .rgb10a2Unorm, .bgr10a2Unorm: return .bgr10a2Unorm
        case .rgba16Float: return .rgba16Float
        default: return .bgra8Unorm
        }
    }

    // MARK: Capture

    /// Copies `source` into a history texture and measures its line signature along `axis`.
    /// `completion` runs on a Metal completion thread once both have landed, with nil when the
    /// copy could not be made.
    public func capture(_ source: MTLTexture, axis: ScrollAxis,
                        completion: @escaping @Sendable (MTLTexture?, ScrollSignature?) -> Void) {
        let width = source.width, height = source.height
        let lines = axis == .vertical ? height : width, span = axis == .vertical ? width : height
        let bands = ScrollSignature.bandCount(span: span)
        guard let copy = texture(width: width, height: height, format: source.pixelFormat),
              let output = device.makeBuffer(length: lines * bands * 4 * MemoryLayout<Float>.stride, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            completion(nil, nil)
            return
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        guard let compute = commands.makeComputeCommandEncoder() else { completion(nil, nil); return }
        var parameters = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(bands), axis == .vertical ? 0 : 1)
        compute.setComputePipelineState(signature)
        compute.setTexture(copy, index: 0)
        compute.setBuffer(output, offset: 0, index: 0)
        compute.setBytes(&parameters, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
        let group = MTLSize(width: min(bands, 8), height: max(1, signature.maxTotalThreadsPerThreadgroup / 8 / 4), depth: 1)
        compute.dispatchThreads(MTLSize(width: bands, height: lines, depth: 1), threadsPerThreadgroup: group)
        compute.endEncoding()
        commands.addCompletedHandler { buffer in
            guard buffer.status == .completed else { completion(nil, nil); return }
            let pointer = output.contents().bindMemory(to: Float.self, capacity: lines * bands * 4)
            let result = ScrollSignature(axis: axis, lines: lines, bands: bands, span: span,
                                         packed: UnsafeBufferPointer(start: pointer, count: lines * bands * 4))
            completion(copy, result)
        }
        commands.commit()
    }

    /// Copies `source` into a history texture without measuring it, for the picture a
    /// gesture starts from. `completion` runs once the copy has landed.
    public func copy(_ source: MTLTexture, completion: @escaping @Sendable (MTLTexture?) -> Void) {
        guard let copy = texture(width: source.width, height: source.height, format: source.pixelFormat),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            completion(nil)
            return
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        commands.addCompletedHandler { buffer in completion(buffer.status == .completed ? copy : nil) }
        commands.commit()
    }

    private func texture(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        lock.lock()
        if let index = pool.firstIndex(where: { $0.width == width && $0.height == height && $0.pixelFormat == format }) {
            let reused = pool.remove(at: index)
            lock.unlock()
            return reused
        }
        lock.unlock()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Returns history textures for reuse once the GPU work already queued with them is done.
    public func recycle(_ textures: [MTLTexture]) {
        guard !textures.isEmpty, let commands = queue.makeCommandBuffer() else { return }
        commands.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            // Two pictures' worth stay pooled; the rest are freed.
            self.pool = Array((self.pool + textures).suffix(2))
            self.lock.unlock()
        }
        commands.commit()
    }

    /// Frees every pooled texture, for memory pressure.
    public func drain() {
        lock.lock(); pool.removeAll(); lock.unlock()
    }

    // MARK: Drawing

    private struct Quad {
        var rect: SIMD4<Float>     // x, y, width, height in target pixels
        var offset: SIMD2<Float>   // target pixel - offset = source pixel
        var target: SIMD2<Float>
        var color: SIMD4<Float>
    }

    /// One resolve pass over the region: per pixel, the newest layer that covers it outside
    /// its holes, else the fill colour.
    private struct Resolve {
        var quad: Quad
        var count: UInt32 = 0
        var vertical: UInt32 = 1
        var padding = SIMD2<UInt32>(0, 0)
        // x shift, y first line, z end line, w hole count
        var layers = [SIMD4<Int32>](repeating: .zero, count: LocalScrollRenderer.maximumLayers)
        // along lower, along upper, across lower, across upper, in the layer's picture
        var holes = [SIMD4<Int32>](repeating: .zero, count: LocalScrollRenderer.maximumLayers * LocalScrollRenderer.maximumHoles)

        func bytes() -> [UInt8] {
            var out = [UInt8]()
            withUnsafeBytes(of: quad) { out += $0 }
            withUnsafeBytes(of: (count, vertical, padding)) { out += $0 }
            layers.withUnsafeBytes { out += $0 }
            holes.withUnsafeBytes { out += $0 }
            return out
        }
    }

    /// Draws `composition` into `target`, a picture-sized texture. `textures` holds the frames
    /// it names; `fill` is the colour of content not yet captured. Returns false, drawing
    /// nothing, when a frame it names has no texture.
    public func encode(_ composition: ScrollComposition, textures: [UInt64: MTLTexture], fill: SIMD3<Float>,
                       into target: MTLTexture, commands: MTLCommandBuffer) -> Bool {
        guard let base = textures[composition.base],
              composition.layers.allSatisfy({ textures[$0.frame] != nil }),
              let pipeline = pipelines(for: target.pixelFormat) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let size = SIMD2<Float>(Float(target.width), Float(target.height))
        let vertical = composition.axis == .vertical
        func rect(along: Range<Int>, across: Range<Int>) -> SIMD4<Float> {
            vertical ? SIMD4(Float(across.lowerBound), Float(along.lowerBound), Float(across.count), Float(along.count))
                     : SIMD4(Float(along.lowerBound), Float(across.lowerBound), Float(along.count), Float(across.count))
        }
        let none = SIMD4<Float>(0, 0, 0, 0)
        func draw(_ quad: Quad, texture: MTLTexture) {
            var q = quad
            encoder.setRenderPipelineState(pipeline.textured)
            encoder.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        // Everything outside the region comes from the newest picture, unmoved.
        draw(Quad(rect: SIMD4(0, 0, size.x, size.y), offset: .zero, target: size, color: none), texture: base)
        let region = composition.region
        // The newest layers win, so the oldest beyond the pass's capacity are left out.
        let layers = Array(composition.layers.suffix(Self.maximumLayers))
        var resolve = Resolve(quad: Quad(rect: rect(along: region.along, across: region.across), offset: .zero,
                                         target: size, color: SIMD4(fill.x, fill.y, fill.z, 1)))
        resolve.count = UInt32(layers.count)
        resolve.vertical = vertical ? 1 : 0
        for (i, layer) in layers.enumerated() {
            let holes = layer.holes.prefix(Self.maximumHoles)
            resolve.layers[i] = SIMD4(Int32(layer.shift), Int32(layer.lines.lowerBound), Int32(layer.lines.upperBound), Int32(holes.count))
            for (h, hole) in holes.enumerated() {
                resolve.holes[i * Self.maximumHoles + h] = SIMD4(Int32(hole.along.lowerBound), Int32(hole.along.upperBound),
                                                                 Int32(hole.across.lowerBound), Int32(hole.across.upperBound))
            }
        }
        let bytes = resolve.bytes()
        var quad = resolve.quad
        encoder.setRenderPipelineState(pipeline.resolve)
        encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
        bytes.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        for slot in 0..<Self.maximumLayers {
            encoder.setFragmentTexture(slot < layers.count ? textures[layers[slot].frame] : base, index: slot)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        // Fixed overlays stay where the newest picture shows them.
        for fixed in composition.stationary {
            draw(Quad(rect: rect(along: fixed.along, across: fixed.across), offset: .zero, target: size, color: none), texture: base)
        }
        encoder.endEncoding()
        return true
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // One thread per (band, line): the mean colour and the mean absolute luma step along
    // the line within the band, as ScrollSignature(axis:bands:width:height:rowBytes:bgra:).
    kernel void scroll_signature(texture2d<float, access::read> picture [[texture(0)]],
                                 device float4 *out [[buffer(0)]],
                                 constant uint4 &p [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        uint width = p.x, height = p.y, bands = p.z, axis = p.w;
        uint lines = axis == 0 ? height : width, span = axis == 0 ? width : height;
        if (gid.x >= bands || gid.y >= lines) return;
        uint start = gid.x * span / bands, end = (gid.x + 1) * span / bands;
        float3 sum = 0;
        float steps = 0, previous = 0;
        for (uint i = start; i < end; i++) {
            uint2 coord = axis == 0 ? uint2(i, gid.y) : uint2(gid.y, i);
            float3 c = round(picture.read(coord).rgb * 255.0);
            sum += c;
            float l = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
            if (i > start) steps += abs(l - previous);
            previous = l;
        }
        float n = float(end - start);
        out[gid.y * bands + gid.x] = float4(sum / n, steps / max(1.0, n - 1.0));
    }

    struct Quad { float4 rect; float2 offset; float2 target; float4 color; };
    struct Fragment { float4 position [[position]]; };

    vertex Fragment scroll_quad_vertex(uint vid [[vertex_id]], constant Quad &q [[buffer(0)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        float2 p = q.rect.xy + corner * q.rect.zw;
        Fragment f;
        f.position = float4(p.x / q.target.x * 2.0 - 1.0, 1.0 - p.y / q.target.y * 2.0, 0.0, 1.0);
        return f;
    }

    fragment half4 scroll_quad_texture(Fragment in [[stage_in]], constant Quad &q [[buffer(0)]],
                                       texture2d<half, access::read> picture [[texture(0)]]) {
        int2 source = int2(floor(in.position.xy - q.offset));
        int2 limit = int2(picture.get_width(), picture.get_height()) - 1;
        return picture.read(uint2(clamp(source, int2(0), limit)));
    }

    struct Resolve {
        Quad quad;
        uint count, vertical;
        uint2 padding;
        int4 layers[8];
        int4 holes[32];
    };

    // Per pixel of the region, the newest layer covering it outside its holes; else fill.
    fragment half4 scroll_resolve(Fragment in [[stage_in]], constant Resolve &r [[buffer(0)]],
                                  array<texture2d<half, access::read>, 8> layers [[texture(0)]]) {
        int2 p = int2(floor(in.position.xy));
        bool vertical = r.vertical != 0;
        int along = vertical ? p.y : p.x, across = vertical ? p.x : p.y;
        for (int i = int(r.count) - 1; i >= 0; i--) {
            int4 layer = r.layers[i];
            if (along < layer.y || along >= layer.z) continue;
            int source = along - layer.x;
            bool hole = false;
            for (int h = 0; h < layer.w; h++) {
                int4 b = r.holes[i * 4 + h];
                if (source >= b.x && source < b.y && across >= b.z && across < b.w) { hole = true; break; }
            }
            if (hole) continue;
            texture2d<half, access::read> picture = layers[i];
            int2 coord = vertical ? int2(p.x, source) : int2(source, p.y);
            int2 limit = int2(picture.get_width(), picture.get_height()) - 1;
            return picture.read(uint2(clamp(coord, int2(0), limit)));
        }
        return half4(r.quad.color);
    }
    """
}
