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
    private let tag: MTLComputePipelineState
    /// Blocks in a frame tag row (docs/display.md, "Scroll reports").
    public static let tagBlocks = 32
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
            guard let tagKernel = library.makeFunction(name: "scroll_tag") else { return nil }
            tag = try device.makeComputePipelineState(function: tagKernel)
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
    /// `tagRect`, in picture pixels, is where a toolkit reporter drew its frame tag: the mean
    /// luma (0–255) at the centre of each of its `tagBlocks` blocks is read in the same pass
    /// and handed to `completion`.
    public func capture(_ source: MTLTexture, axis: ScrollAxis, tagRect: CGRect? = nil,
                        completion: @escaping @Sendable (MTLTexture?, ScrollSignature?, [Float]?) -> Void) {
        let width = source.width, height = source.height
        let lines = axis == .vertical ? height : width, span = axis == .vertical ? width : height
        let bands = ScrollSignature.bandCount(span: span)
        guard let copy = texture(width: width, height: height, format: source.pixelFormat),
              let output = device.makeBuffer(length: lines * bands * 4 * MemoryLayout<Float>.stride, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            completion(nil, nil, nil)
            return
        }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        guard let compute = commands.makeComputeCommandEncoder() else { completion(nil, nil, nil); return }
        var parameters = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(bands), axis == .vertical ? 0 : 1)
        compute.setComputePipelineState(signature)
        compute.setTexture(copy, index: 0)
        compute.setBuffer(output, offset: 0, index: 0)
        compute.setBytes(&parameters, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
        let group = MTLSize(width: min(bands, 8), height: max(1, signature.maxTotalThreadsPerThreadgroup / 8 / 4), depth: 1)
        compute.dispatchThreads(MTLSize(width: bands, height: lines, depth: 1), threadsPerThreadgroup: group)
        let blocks = Self.tagBlocks
        var tagOutput: MTLBuffer?
        if let tagRect, tagRect.width >= CGFloat(blocks), tagRect.height >= 1,
           CGRect(x: 0, y: 0, width: width, height: height).contains(tagRect.integral),
           let buffer = device.makeBuffer(length: blocks * MemoryLayout<Float>.stride, options: .storageModeShared) {
            var rect = SIMD4<Float>(Float(tagRect.minX), Float(tagRect.minY), Float(tagRect.width), Float(tagRect.height))
            compute.setComputePipelineState(tag)
            compute.setTexture(copy, index: 0)
            compute.setBuffer(buffer, offset: 0, index: 0)
            compute.setBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            compute.dispatchThreads(MTLSize(width: blocks, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: blocks, height: 1, depth: 1))
            tagOutput = buffer
        }
        compute.endEncoding()
        commands.addCompletedHandler { buffer in
            guard buffer.status == .completed else { completion(nil, nil, nil); return }
            let pointer = output.contents().bindMemory(to: Float.self, capacity: lines * bands * 4)
            let result = ScrollSignature(axis: axis, lines: lines, bands: bands, span: span,
                                         packed: UnsafeBufferPointer(start: pointer, count: lines * bands * 4))
            let tagLuma = tagOutput.map { Array(UnsafeBufferPointer(start: $0.contents().bindMemory(to: Float.self, capacity: blocks), count: blocks)) }
            completion(copy, result, tagLuma)
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
        var rect: SIMD4<Float>     // x, y, width, height in viewport pixels
        var offset: SIMD2<Float>   // viewport pixel - offset = source pixel
        var target: SIMD2<Float>
        var color: SIMD4<Float>
        var view = SIMD4<Float>(1, 1, 0, 0)  // target pixel = viewport pixel * xy + zw
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
        // Each layer's shift beyond its whole lines, as drawn: snapped to target pixels.
        var fractions = [Float](repeating: 0, count: LocalScrollRenderer.maximumLayers)

        func bytes() -> [UInt8] {
            var out = [UInt8]()
            withUnsafeBytes(of: quad) { out += $0 }
            withUnsafeBytes(of: (count, vertical, padding)) { out += $0 }
            layers.withUnsafeBytes { out += $0 }
            holes.withUnsafeBytes { out += $0 }
            fractions.withUnsafeBytes { out += $0 }
            return out
        }
    }

    /// Draws `composition` into `target`. `viewport` is the picture's shown part in picture
    /// pixels (the target's size when nil); a target of more pixels, such as the screen's,
    /// gets the viewport scaled up and filtered, with each layer's fractional position snapped
    /// to target pixels, so motion is smooth and text stays crisp. `textures` holds the frames
    /// it names; `fill` is the colour of content not yet captured. Returns false, drawing
    /// nothing, when a frame it names has no texture.
    public func encode(_ composition: ScrollComposition, textures: [UInt64: MTLTexture], fill: SIMD3<Float>,
                       into target: MTLTexture, viewport: CGSize? = nil, commands: MTLCommandBuffer) -> Bool {
        guard let base = textures[composition.base],
              composition.layers.allSatisfy({ textures[$0.frame] != nil }),
              let pipeline = pipelines(for: target.pixelFormat) else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        // A pinched-out or panned viewport leaves target pixels no picture covers.
        let transformed = composition.zoom != 1 || composition.translation != .zero
        pass.colorAttachments[0].loadAction = transformed ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(fill.x), green: Double(fill.y), blue: Double(fill.z), alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let size = SIMD2<Float>(Float(target.width), Float(target.height))
        let shown = viewport.map { SIMD2<Float>(Float(max(1, $0.width)), Float(max(1, $0.height))) } ?? size
        // Viewport to target: a pinch's transform, then the target's density.
        let zoom = Float(composition.zoom)
        let density = size / shown
        let view = SIMD4<Float>(density.x * zoom, density.y * zoom,
                                density.x * Float(composition.translation.x), density.y * Float(composition.translation.y))
        let vertical = composition.axis == .vertical
        let alongScale = vertical ? view.y : view.x
        func rect(along: Range<Int>, across: Range<Int>) -> SIMD4<Float> {
            vertical ? SIMD4(Float(across.lowerBound), Float(along.lowerBound), Float(across.count), Float(along.count))
                     : SIMD4(Float(along.lowerBound), Float(across.lowerBound), Float(along.count), Float(across.count))
        }
        let none = SIMD4<Float>(0, 0, 0, 0)
        func draw(_ quad: Quad, texture: MTLTexture) {
            var q = quad
            q.view = view
            encoder.setRenderPipelineState(pipeline.textured)
            encoder.setVertexBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentBytes(&q, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        // Everything outside the region comes from the newest picture, unmoved.
        draw(Quad(rect: SIMD4(0, 0, shown.x, shown.y), offset: .zero, target: size, color: none), texture: base)
        let region = composition.region
        // The newest layers win, so the oldest beyond the pass's capacity are left out.
        let layers = Array(composition.layers.suffix(Self.maximumLayers))
        var resolve = Resolve(quad: Quad(rect: rect(along: region.along, across: region.across), offset: .zero,
                                         target: size, color: SIMD4(fill.x, fill.y, fill.z, 1)))
        resolve.quad.view = view
        resolve.count = UInt32(layers.count)
        resolve.vertical = vertical ? 1 : 0
        for (i, layer) in layers.enumerated() {
            let holes = layer.holes.prefix(Self.maximumHoles)
            resolve.layers[i] = SIMD4(Int32(layer.shift), Int32(layer.lines.lowerBound), Int32(layer.lines.upperBound), Int32(holes.count))
            // Whole target pixels, so a still layer is never resampled between them.
            let moved = Float(layer.shift) + layer.fraction
            resolve.fractions[i] = (moved * alongScale).rounded() / alongScale - Float(layer.shift)
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
        for fixed in composition.stationary where fixed.along.upperBound <= region.along.upperBound {
            draw(Quad(rect: rect(along: fixed.along, across: fixed.across), offset: .zero, target: size, color: none), texture: base)
        }
        // With an overscan, what follows the region in the picture (a footer, a status bar)
        // is anchored to the viewport's end.
        let viewLines = Int(vertical ? shown.y : shown.x)
        if composition.overscan > 0, region.along.upperBound < viewLines {
            let shift = Float(-composition.overscan)
            let span = vertical ? 0..<Int(shown.x) : 0..<Int(shown.y)
            draw(Quad(rect: rect(along: region.along.upperBound..<viewLines, across: span),
                      offset: vertical ? SIMD2(0, shift) : SIMD2(shift, 0), target: size, color: none), texture: base)
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

    // One thread per tag block: the mean luma of the 3x3 pixels at the block's centre.
    kernel void scroll_tag(texture2d<float, access::read> picture [[texture(0)]],
                           device float *out [[buffer(0)]],
                           constant float4 &rect [[buffer(1)]],
                           uint block [[thread_position_in_grid]]) {
        float2 centre = float2(rect.x + (float(block) + 0.5) * rect.z / 32.0, rect.y + rect.w * 0.5);
        int2 limit = int2(picture.get_width(), picture.get_height()) - 1;
        float sum = 0;
        for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
            int2 p = clamp(int2(centre) + int2(dx, dy), int2(0), limit);
            float3 c = picture.read(uint2(p)).rgb * 255.0;
            sum += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
        }
        out[block] = sum / 9.0;
    }

    struct Quad { float4 rect; float2 offset; float2 target; float4 color; float4 view; };
    struct Fragment { float4 position [[position]]; };

    vertex Fragment scroll_quad_vertex(uint vid [[vertex_id]], constant Quad &q [[buffer(0)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        float2 p = (q.rect.xy + corner * q.rect.zw) * q.view.xy + q.view.zw;
        Fragment f;
        f.position = float4(p.x / q.target.x * 2.0 - 1.0, 1.0 - p.y / q.target.y * 2.0, 0.0, 1.0);
        return f;
    }

    // The viewport point a target pixel's centre shows.
    static float2 viewportPoint(float4 position, float4 view) { return (position.xy - view.zw) / view.xy; }

    // Bilinear sample at a continuous point (pixel centres at i + 0.5): exact at centres.
    static half4 sampleAt(texture2d<half, access::read> picture, float2 point) {
        float2 c = point - 0.5;
        float2 i = floor(c);
        half2 f = half2(c - i);
        int2 limit = int2(picture.get_width(), picture.get_height()) - 1;
        int2 a = clamp(int2(i), int2(0), limit), b = clamp(int2(i) + 1, int2(0), limit);
        half4 top = mix(picture.read(uint2(a.x, a.y)), picture.read(uint2(b.x, a.y)), f.x);
        half4 bottom = mix(picture.read(uint2(a.x, b.y)), picture.read(uint2(b.x, b.y)), f.x);
        return mix(top, bottom, f.y);
    }

    fragment half4 scroll_quad_texture(Fragment in [[stage_in]], constant Quad &q [[buffer(0)]],
                                       texture2d<half, access::read> picture [[texture(0)]]) {
        return sampleAt(picture, viewportPoint(in.position, q.view) - q.offset);
    }

    struct Resolve {
        Quad quad;
        uint count, vertical;
        uint2 padding;
        int4 layers[8];
        int4 holes[32];
        float fractions[8];
    };

    // Per pixel of the region, the newest layer covering it outside its holes; else fill.
    fragment half4 scroll_resolve(Fragment in [[stage_in]], constant Resolve &r [[buffer(0)]],
                                  array<texture2d<half, access::read>, 8> layers [[texture(0)]]) {
        float2 v = viewportPoint(in.position, r.quad.view);
        bool vertical = r.vertical != 0;
        float alongAt = vertical ? v.y : v.x, acrossAt = vertical ? v.x : v.y;
        int along = int(floor(alongAt)), across = int(floor(acrossAt));
        for (int i = int(r.count) - 1; i >= 0; i--) {
            int4 layer = r.layers[i];
            if (along < layer.y || along >= layer.z) continue;
            float sourceAt = alongAt - float(layer.x) - r.fractions[i];
            int source = int(floor(sourceAt));
            bool hole = false;
            for (int h = 0; h < layer.w; h++) {
                int4 b = r.holes[i * 4 + h];
                if (source >= b.x && source < b.y && across >= b.z && across < b.w) { hole = true; break; }
            }
            if (hole) continue;
            return sampleAt(layers[i], vertical ? float2(acrossAt, sourceAt) : float2(sourceAt, acrossAt));
        }
        return half4(r.quad.color);
    }
    """
}
