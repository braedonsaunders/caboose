import Foundation
import Metal
import QuartzCore

/// Runs `LocalScroll` for one window view: captures the window's pictures as they change,
/// measures them off the main thread, forwards scroll to the app, and draws compositions.
@MainActor
public final class LocalScrollController {
    public private(set) var model = LocalScroll()
    private let renderer: LocalScrollRenderer
    private let estimator = ScrollMotionEstimator()
    private let measuring = DispatchQueue(label: "org.caboose.scroll.measure", qos: .userInteractive)
    /// The measurement chain, touched only on `measuring`.
    private final class Chain: @unchecked Sendable {
        var previous: (id: UInt64, signature: ScrollSignature)?
        var generation = 0
    }
    private let chain = Chain()
    private var generation = 0
    private var textures: [UInt64: MTLTexture] = [:]
    private var fills: [UInt64: (top: SIMD3<Float>, bottom: SIMD3<Float>)] = [:]
    private var nextID: UInt64 = 1
    private var captured: (surface: ObjectIdentifier, generation: UInt64)?
    private var armedUntil: CFTimeInterval = 0
    private var measuringID: UInt64?
    private var lastRefresh: CFTimeInterval?
    /// Forwards scroll in picture pixels (content direction) with the adapter target, if
    /// any; false when the input target is no longer live, which cancels the scroll.
    private var send: ((CGPoint, Double?) -> Bool)?
    public let profile = LocalScrollProfile()

    public init?() {
        guard let renderer = LocalScrollRenderer.shared else { return nil }
        self.renderer = renderer
    }

    public var isActive: Bool { model.isActive }
    public var isMoving: Bool { model.isMoving }
    /// Whether the last refresh drew a composition instead of the app's picture.
    public private(set) var isComposing = false
    /// How far the newest picture's content is moved on screen, in picture pixels, for
    /// layers drawn over the picture (videos) to follow.
    public private(set) var contentShift: CGPoint = .zero

    // MARK: Gesture

    public func begin(at time: TimeInterval, delta: CGPoint, anchor: CGPoint, scale: CGSize,
                      send: @escaping (CGPoint, Double?) -> Bool) {
        let axis = ScrollAxis.dominant(delta)
        if axis != model.axis { restartChain() }
        self.send = send
        model.begin(at: time, axis: axis, anchor: anchor, scale: scale)
        armedUntil = .infinity
        profile.begin(at: time)
    }

    public func track(_ delta: CGPoint, at time: TimeInterval) {
        model.track(delta, at: time)
        profile.touch(at: time)
    }

    public func release(at time: TimeInterval, velocity: CGPoint?, coast: Bool) {
        model.release(at: time, velocity: velocity, coast: coast)
    }

    /// A finger touched down: stop where the content shows.
    public func halt(at time: TimeInterval) {
        model.halt(at: time)
    }

    /// Other input reached the window.
    public func interrupt() { model.interrupt() }

    /// The window, its mapping or the connection changed.
    public func cancel() {
        model.cancel()
        send = nil
        armedUntil = 0
        isComposing = false
        contentShift = .zero
        restartChain()
        releaseTextures(keeping: [])
        if let standby { renderer.recycle([standby.texture]); self.standby = nil }
    }

    private func restartChain() {
        generation += 1
        measuringID = nil
        let generation = generation, chain = chain
        measuring.async { chain.previous = nil; chain.generation = generation }
        captured = nil
    }

    // MARK: Refresh

    /// One display refresh: captures a changed picture, advances the scroll, forwards it and,
    /// when the phone owns the picture, draws it. Returns true when it presented.
    /// `surface` is the window's picture when this view draws it; nil for pictures presented
    /// on the GPU, which arrive through `offer(_:done:)`.
    public func refresh(at time: CFTimeInterval, surface: WindowSurface?, layer: CAMetalLayer) -> Bool {
        let now = CACurrentMediaTime()
        lastRefresh = time
        // Pictures are captured from a gesture until a while after the scroll comes to rest.
        if model.isActive { armedUntil = .infinity } else if armedUntil == .infinity { armedUntil = now + 3 }
        if now < armedUntil {
            if let standby, measuringID == nil {
                self.standby = nil
                capture(standby.texture, at: standby.time) { [renderer] in renderer.recycle([standby.texture]) }
            } else if let surface, let picture = surface.presentation() {
                let key = (ObjectIdentifier(surface), picture.generation)
                // One picture is measured at a time; while one is, newer ones coalesce into
                // whichever is current when it lands.
                if measuringID == nil, captured.map({ $0.surface != key.0 || $0.generation != key.1 }) ?? true {
                    captured = key
                    // Pictures and refreshes share the refresh timeline.
                    capture(picture.texture, at: time)
                }
            }
        } else if !textures.isEmpty {
            // Long at rest: the history goes; what was learned about the window stays.
            model.forgetHistory()
            restartChain()
            releaseTextures(keeping: [])
        }
        let wasActive = model.isActive
        let tick = model.tick(at: time)
        if wasActive, !model.isActive { profile.finish(model: model, at: time) }
        if tick.send != .zero || tick.target != nil, let send, !send(tick.send, tick.target) {
            cancel()
            return false
        }
        guard let composition = tick.composition else {
            isComposing = false
            contentShift = .zero
            profile.refresh(at: time, composed: false, blank: 0, region: 1)
            return false
        }
        let fill = fillColor(composition)
        guard let base = textures[composition.base] else { isComposing = false; return false }
        let format = LocalScrollRenderer.layerFormat(for: base.pixelFormat)
        if layer.pixelFormat != format { layer.pixelFormat = format }
        let size = CGSize(width: base.width, height: base.height)
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable(), let commands = renderer.queue.makeCommandBuffer(),
              renderer.encode(composition, textures: textures, fill: fill, into: drawable.texture, commands: commands) else {
            isComposing = false
            return false
        }
        profile.presenting(drawable, at: time)
        commands.present(drawable)
        commands.commit()
        isComposing = true
        let shift = composition.layers.last?.shift ?? 0
        contentShift = composition.axis.point(along: CGFloat(shift))
        profile.refresh(at: time, composed: true, blank: composition.blank, region: composition.region.along.count)
        return true
    }

    /// A picture presented on the GPU (a live GPU window), captured natively. `done` runs
    /// once the phone no longer reads `texture`. While no scroll is armed only the newest is
    /// kept, as the picture the next gesture starts from.
    public func offer(_ texture: MTLTexture, done: @escaping @Sendable () -> Void) {
        let time = lastRefresh ?? CACurrentMediaTime()
        pictureSize = CGSize(width: texture.width, height: texture.height)
        if CACurrentMediaTime() < armedUntil, measuringID == nil {
            capture(texture, at: time, done: done)
            return
        }
        renderer.copy(texture) { [weak self] copy in
            done()
            guard let copy else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { LocalScrollRenderer.shared?.recycle([copy]); return }
                    if let old = self.standby { self.renderer.recycle([old.texture]) }
                    self.standby = (copy, time)
                }
            }
        }
    }

    /// The size of the newest picture offered on the GPU.
    public private(set) var pictureSize: CGSize?
    private var standby: (texture: MTLTexture, time: CFTimeInterval)?

    private func capture(_ texture: MTLTexture, at time: CFTimeInterval, done: (@Sendable () -> Void)? = nil) {
        let id = nextID
        nextID += 1
        measuringID = id
        let hint = model.captured(id, at: time)
        let axis = model.axis, generation = generation, chain = chain, estimator = estimator
        let anchor: Int? = nil
        let measuring = measuring
        renderer.capture(texture, axis: axis) { [weak self] copy, signature in
            done?()
            measuring.async {
                var observation: ScrollObservation = .unrelated
                var edges: (top: SIMD3<Float>, bottom: SIMD3<Float>)?
                if let signature, chain.generation == generation {
                    if let previous = chain.previous, previous.signature.lines == signature.lines, previous.signature.bands == signature.bands {
                        switch estimator.measure(from: previous.signature, to: signature, expected: hint.range,
                                                 center: hint.center, anchor: anchor) {
                        case .moved(let motion):
                            observation = .moved(shift: motion.shift,
                                                 region: ScrollRegion(along: motion.lines, across: signature.pixels(of: motion.bands)),
                                                 reference: previous.id)
                        case .still:
                            observation = .still(reference: previous.id)
                        case .unexplained:
                            observation = .unrelated
                        }
                    }
                    chain.previous = (id, signature)
                    edges = Self.edgeColors(signature, observation: observation)
                }
                let result = observation
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self?.measuringID == id { self?.measuringID = nil }
                        guard let self, self.generation == generation else {
                            if let copy { LocalScrollRenderer.shared?.recycle([copy]) }
                            return
                        }
                        if let copy { self.textures[id] = copy }
                        if let edges { self.fills[id] = edges }
                        self.model.observe(id, copy == nil ? .unrelated : result)
                        self.profile.measured(result)
                        self.releaseTextures(keeping: Set(self.model.retainedFrames))
                    }
                }
            }
        }
    }

    private nonisolated static func edgeColors(_ signature: ScrollSignature, observation: ScrollObservation) -> (SIMD3<Float>, SIMD3<Float>) {
        var lines = 0..<signature.lines, bands = 0..<signature.bands
        if case .moved(_, let region, _) = observation {
            lines = region.along
            bands = signature.band(at: region.across.lowerBound)..<(signature.band(at: max(region.across.lowerBound, region.across.upperBound - 1)) + 1)
        }
        let top = signature.meanColor(lines: lines.lowerBound..<min(lines.upperBound, lines.lowerBound + 16), bands: bands)
        let bottom = signature.meanColor(lines: max(lines.lowerBound, lines.upperBound - 16)..<lines.upperBound, bands: bands)
        return (top, bottom)
    }

    private func fillColor(_ composition: ScrollComposition) -> SIMD3<Float> {
        guard let from = composition.fillFrom, let colors = fills[from.frame] else { return SIMD3(1, 1, 1) }
        let middle = (composition.region.along.lowerBound + composition.region.along.upperBound) / 2
        return from.lines.lowerBound >= middle ? colors.bottom : colors.top
    }

    private func releaseTextures(keeping kept: Set<UInt64>) {
        let dropped = textures.filter { !kept.contains($0.key) }
        guard !dropped.isEmpty else { return }
        for id in dropped.keys { textures[id] = nil; fills[id] = nil }
        renderer.recycle(Array(dropped.values))
    }
}
