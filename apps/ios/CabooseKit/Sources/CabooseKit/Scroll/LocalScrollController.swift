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

    /// Which picture a capture is: the window's surface as it stood (its newest commit), or
    /// a live GPU present by serial.
    public enum PictureSource: Sendable {
        case surface(WindowSurface)
        case present(serial: UInt64)
    }
    /// A toolkit adapter's report for exactly the captured picture, when it has one; the
    /// report replaces measurement for that picture. It is asked on main once the picture
    /// has been copied, with the luma at the centre of each block of the frame tag the
    /// reporter drew (`tagRect`), when there is one.
    public var report: ((PictureSource, [Float]?) -> ScrollObservation?)?
    /// Where a toolkit reporter draws its frame tag in a picture of this size, in picture
    /// pixels, asked for each capture.
    public var tagRect: ((CGSize) -> CGRect?)?
    /// Once per gesture, for the profile: a picture was reported, or a tag did not decode.
    private var reportNoted = false, tagMissNoted = false
    /// How many of a captured picture's pixels lie past the viewport, right and below (an
    /// overscan window); none by default.
    public var pictureOverscan: (MTLTexture) -> CGSize = { _ in .zero }
    /// Where the viewport's region ends along the axis, in picture pixels, while an overscan
    /// applies: points after it show the picture's lines that many pixels further on.
    public var anchoredFrom: (axis: ScrollAxis, start: Int, viewport: Int)? {
        guard model.overscan > 0, let composition = lastComposition, lastViewport > 0 else { return nil }
        return (composition.axis, composition.region.along.upperBound, lastViewport)
    }
    private var lastViewport = 0
    private var lastViewportSize: CGSize?
    private var lastComposition: ScrollComposition?

    /// The newest touch sample's timestamp, for the send log.
    private var lastTouch: TimeInterval?

    /// Phone-owned scrolling runs unless the app is launched with `CABOOSE_LOCAL_SCROLL=0`,
    /// which makes every pan scroll the app remotely.
    public static let enabled = ProcessInfo.processInfo.environment["CABOOSE_LOCAL_SCROLL"] != "0"

    public init?(enabled: Bool = LocalScrollController.enabled) {
        guard enabled, let renderer = LocalScrollRenderer.shared else { return nil }
        self.renderer = renderer
        if LocalScrollProfile.enabled { model.note = { LocalScrollProfile.note($0) } }
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
        lastTouch = time
        LocalScrollProfile.note(String(format: "engage t=%.4f", CACurrentMediaTime()))
        reportNoted = false; tagMissNoted = false
        armedUntil = .infinity
        profile.begin(at: time)
    }

    public func track(_ delta: CGPoint, at time: TimeInterval) {
        model.track(delta, at: time)
        lastTouch = time
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
        finishZoom()
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
        placing.removeAll()
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
        if let surface { lastSurface = surface }
        // Pictures are captured from a gesture until a while after the scroll comes to rest.
        if model.isActive || zoom != nil { armedUntil = .infinity } else if armedUntil == .infinity { armedUntil = now + 3 }
        if now < armedUntil {
            if let standby, measuringID == nil {
                self.standby = nil
                capture(standby.texture, at: standby.time, source: .present(serial: standby.serial)) { [renderer] in
                    renderer.recycle([standby.texture])
                }
            } else if let surface, let picture = surface.presentation() {
                let key = (ObjectIdentifier(surface), picture.generation)
                // One picture is measured at a time; while one is, newer ones coalesce into
                // whichever is current when it lands.
                if measuringID == nil, captured.map({ $0.surface != key.0 || $0.generation != key.1 }) ?? true {
                    captured = key
                    // Pictures and refreshes share the refresh timeline.
                    capture(picture.texture, at: time, source: .surface(surface))
                }
            }
        } else if !textures.isEmpty {
            // Long at rest: the history goes; what was learned about the window stays.
            model.forgetHistory()
            restartChain()
            releaseTextures(keeping: [])
        }
        if !placing.isEmpty { place() }
        // A capture whose copy never lands must not stop the pictures for good.
        if let since = measuringSince, measuringID != nil, now - since > 0.5 {
            LocalScrollProfile.note("capture \(measuringID ?? 0) did not land in 500 ms; capturing again")
            measuringID = nil
        }
        if LocalScrollProfile.enabled, now - lastStatus > 1, model.isActive {
            lastStatus = now
            LocalScrollProfile.note("status captures=\(capturesIssued) landed=\(capturesLanded) placed=\(capturesPlaced) waiting=\(placing.count) measuring=\(measuringID.map(String.init) ?? "-") phase=\(model.phase) lost=\(model.lost)")
        }
        if zoom != nil { return refreshZoom(at: time, surface: surface, layer: layer) }
        let wasActive = model.isActive
        let tick = model.tick(at: time)
        if wasActive, !model.isActive {
            LocalScrollProfile.note(String(format: "release t=%.4f", CACurrentMediaTime()))
            profile.finish(model: model, at: time)
        }
        if tick.send != .zero, LocalScrollProfile.enabled {
            LocalScrollProfile.note(String(format: "send t=%.4f touch=%.4f refresh=%.4f phase=%@ dy=%.2f dx=%.2f", CACurrentMediaTime(),
                                           lastTouch ?? 0, time, "\(model.phase)", Double(tick.send.y), Double(tick.send.x)))
        }
        if tick.send != .zero || tick.target != nil, let send, !send(tick.send, tick.target) {
            cancel()
            return false
        }
        lastComposition = tick.composition
        guard let composition = tick.composition else {
            isComposing = false
            contentShift = .zero
            profile.refresh(at: time, composed: false, blank: 0, region: 1)
            return false
        }
        guard draw(composition, into: layer, at: time) else { return false }
        let shift = composition.layers.last?.shift ?? 0
        contentShift = composition.axis.point(along: CGFloat(shift))
        profile.refresh(at: time, composed: true, blank: composition.blank, region: composition.region.along.count)
        return true
    }

    private func draw(_ composition: ScrollComposition, into layer: CAMetalLayer, at time: CFTimeInterval) -> Bool {
        let fill = fillColor(composition)
        guard let base = textures[composition.base] else { isComposing = false; return false }
        let format = LocalScrollRenderer.layerFormat(for: base.pixelFormat)
        if layer.pixelFormat != format { layer.pixelFormat = format }
        // The viewport: the picture less its overscan along the axis.
        // The viewport: the picture less what lies past it, by the picture's own shape too,
        // so a longer picture is never squashed into the view while the model catches up.
        let extra = pictureOverscan(base)
        let size = CGSize(width: max(1, base.width - max(Int(extra.width), composition.axis == .horizontal ? composition.overscan : 0)),
                          height: max(1, base.height - max(Int(extra.height), composition.axis == .vertical ? composition.overscan : 0)))
        // Composed at the screen's own pixels when they are more than the picture's: the
        // renderer filters and snaps positions to them, where the layer's scaling would not.
        let screen = CGSize(width: (layer.bounds.width * displayScale).rounded(), height: (layer.bounds.height * displayScale).rounded())
        let drawn = screen.width > size.width || screen.height > size.height ? screen : size
        if layer.drawableSize != drawn { layer.drawableSize = drawn }
        lastViewport = Int(composition.axis == .vertical ? size.height : size.width)
        lastViewportSize = size
        guard let drawable = layer.nextDrawable(), let commands = renderer.queue.makeCommandBuffer(),
              renderer.encode(composition, textures: textures, fill: fill, into: drawable.texture, viewport: size,
                              commands: commands) else {
            isComposing = false
            return false
        }
        profile.presenting(drawable, at: time)
        commands.present(drawable)
        commands.commit()
        isComposing = true
        return true
    }

    /// A picture presented on the GPU (a live GPU window), captured natively. `done` runs
    /// once the phone no longer reads `texture`. While no scroll is armed only the newest is
    /// kept, as the picture the next gesture starts from.
    public func offer(_ texture: MTLTexture, serial: UInt64, done: @escaping @Sendable () -> Void) {
        let time = lastRefresh ?? CACurrentMediaTime()
        pictureSize = CGSize(width: texture.width, height: texture.height)
        if CACurrentMediaTime() < armedUntil, measuringID == nil {
            capture(texture, at: time, source: .present(serial: serial), done: done)
            return
        }
        renderer.copy(texture) { [weak self] copy in
            done()
            guard let copy else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { LocalScrollRenderer.shared?.recycle([copy]); return }
                    if let old = self.standby { self.renderer.recycle([old.texture]) }
                    self.standby = (copy, time, serial)
                }
            }
        }
    }

    /// The size of the newest picture offered on the GPU.
    public private(set) var pictureSize: CGSize?
    private var standby: (texture: MTLTexture, time: CFTimeInterval, serial: UInt64)?

    private func capture(_ texture: MTLTexture, at time: CFTimeInterval, source: PictureSource,
                         done: (@Sendable () -> Void)? = nil) {
        let overscan = Int((model.axis == .vertical ? pictureOverscan(texture).height : pictureOverscan(texture).width).rounded())
        let id = nextID
        nextID += 1
        measuringID = id
        measuringSince = CACurrentMediaTime()
        capturesIssued += 1
        let hint = model.captured(id, at: time, overscan: overscan)
        let tagRect = self.tagRect?(CGSize(width: texture.width, height: texture.height))
        let axis = model.axis, generation = generation, chain = chain, estimator = estimator
        let anchor: Int? = nil
        let measuring = measuring
        renderer.capture(texture, axis: axis, tagRect: tagRect) { [weak self] copy, signature, tagLuma in
            done?()
            measuring.async {
                var observation: ScrollObservation = .unrelated
                var edges: (top: SIMD3<Float>, bottom: SIMD3<Float>)?
                if let signature, chain.generation == generation {
                    if let previous = chain.previous, previous.signature.lines != signature.lines || previous.signature.bands != signature.bands {
                        LocalScrollProfile.note("picture \(id) is \(signature.span)x\(signature.lines), the previous \(previous.signature.span)x\(previous.signature.lines): unrelated")
                    } else if let previous = chain.previous {
                        switch estimator.measure(from: previous.signature, to: signature, expected: hint.range,
                                                 center: hint.center, anchor: anchor) {
                        case .moved(let motion):
                            observation = .moved(shift: motion.shift,
                                                 region: ScrollRegion(along: motion.lines, across: signature.pixels(of: motion.bands)),
                                                 reference: previous.id,
                                                 stationary: motion.stationary.map {
                                                     ScrollRegion(along: $0.lines, across: signature.pixels(of: $0.bands))
                                                 })
                        case .still:
                            observation = .still(reference: previous.id)
                        case .unexplained:
                            LocalScrollProfile.note("picture \(id) unexplained against \(previous.id) over shifts \(hint.range)")
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
                        self?.capturesLanded += 1
                        guard let self, self.generation == generation else {
                            if let copy { LocalScrollRenderer.shared?.recycle([copy]) }
                            return
                        }
                        if let copy { self.textures[id] = copy }
                        if let edges { self.fills[id] = edges }
                        self.placing.append(Placing(id: id, source: source, tagLuma: copy == nil ? nil : tagLuma,
                                                    measured: copy == nil ? .unrelated : result, deadline: CACurrentMediaTime() + 0.1))
                        self.place()
                    }
                }
            }
        }
    }

    /// Captured pictures awaiting placement, in capture order: one whose tag names a report
    /// not yet arrived waits for it up to its deadline, and the pictures after it wait too.
    private struct Placing {
        let id: UInt64
        let source: PictureSource
        let tagLuma: [Float]?
        let measured: ScrollObservation
        let deadline: CFTimeInterval
    }
    private var placing: [Placing] = []
    /// Screen pixels per point of the layer compositions are drawn into; 0 draws them at the
    /// picture's own pixels.
    public var displayScale: CGFloat = 0
    private var measuringSince: CFTimeInterval?
    private var capturesIssued = 0, capturesLanded = 0, capturesPlaced = 0
    private var lastStatus: CFTimeInterval = 0
    /// Whether tag luma decodes as a valid frame tag (its report may still be on its way).
    public var tagIsValid: (([Float]) -> Bool)?

    /// A toolkit reporter's report arrived for this window: pictures waiting for one place now.
    public func reportsUpdated() { place() }

    private func place() {
        let now = CACurrentMediaTime()
        while let next = placing.first {
            // The reporter's word for exactly this picture replaces measurement.
            let reported = report?(next.source, next.tagLuma)
            if reported == nil, let luma = next.tagLuma, tagIsValid?(luma) == true, now < next.deadline { return }
            placing.removeFirst()
            if LocalScrollProfile.enabled {
                if case .reported(let offset, _, _, _, let epoch) = reported, !reportNoted {
                    reportNoted = true
                    LocalScrollProfile.note("picture \(next.id) reported: offset \(Int(offset)) epoch \(epoch)")
                } else if reported == nil, let luma = next.tagLuma, !tagMissNoted {
                    tagMissNoted = true
                    LocalScrollProfile.note("picture \(next.id) has a tag rect but no report\(tagIsValid?(luma) == true ? " within 100 ms" : ""); tag luma \(luma.map { String(Int($0)) }.joined(separator: ","))")
                } else if reported == nil, next.tagLuma == nil, report != nil, !tagMissNoted {
                    tagMissNoted = true
                    LocalScrollProfile.note("picture \(next.id): no tag rect for its window (no scroll.tree with tag_rect yet)")
                }
            }
            capturesPlaced += 1
            model.observe(next.id, reported ?? next.measured)
            profile.measured(reported ?? next.measured)
            if let wait = zoomWait, let tree = zoomReport?(next.source, next.tagLuma), tree.applied >= wait.seq,
               abs(tree.zoom - wait.scale) <= 0.005 * wait.scale {
                LocalScrollProfile.note("zoom: picture \(next.id) is at \(String(format: "%.3f", tree.zoom)); handing back")
                finishZoom()
            }
            releaseTextures(keeping: Set(model.retainedFrames).union(zoomFrames))
        }
    }

    private nonisolated static func edgeColors(_ signature: ScrollSignature, observation: ScrollObservation) -> (SIMD3<Float>, SIMD3<Float>) {
        var lines = 0..<signature.lines, bands = 0..<signature.bands
        var measured: ScrollRegion?
        switch observation {
        case .moved(_, let region, _, _), .reported(_, let region, _, _, _): measured = region
        default: break
        }
        if let region = measured {
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

    // MARK: Zoom

    private var zoom: LocalZoom?
    /// What the pinch scales: the composition on screen when it began, or the app's picture.
    private var zoomBase: ScrollComposition?
    private var zoomFrames: Set<UInt64> = []
    /// The app was asked to zoom with this seq to this absolute scale.
    private var zoomWait: (seq: UInt64, scale: Double)?
    private weak var lastSurface: WindowSurface?
    /// The toolkit report for exactly a captured picture, for its zoom and applied seq.
    public var zoomReport: ((PictureSource, [Float]?) -> ScrollTree?)?
    /// How long the composition waits for the app's picture at the new scale.
    static let zoomPatience: TimeInterval = 1.5

    public var isZooming: Bool { zoom != nil }

    /// Two fingers began to pinch at `centroid` (viewport pixels). `limits` are the relative
    /// scales the page allows. A scroll in progress stops where it shows.
    public func beginZoom(centroid: CGPoint, limits: ClosedRange<Double>) {
        finishZoom()
        model.interrupt()
        let viewport = lastViewportSize ?? pictureSize ?? .zero
        zoom = LocalZoom(centroid: centroid, viewport: viewport, limits: limits)
        armedUntil = .infinity
        if isComposing, let shown = lastComposition {
            freezeZoomBase(shown)
            return
        }
        // The app's own picture: a copy, so the app may draw on while the pinch shows it.
        let source = standby?.texture ?? lastSurface?.presentation()?.texture
        guard let source else { return }
        renderer.copy(source) { [weak self] copy in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let copy else { return }
                    guard let self, self.zoom != nil, self.zoomBase == nil else { LocalScrollRenderer.shared?.recycle([copy]); return }
                    let id = self.nextID
                    self.nextID += 1
                    self.textures[id] = copy
                    let extra = self.pictureOverscan(copy)
                    let width = max(1, copy.width - Int(extra.width)), height = max(1, copy.height - Int(extra.height))
                    let region = ScrollRegion(along: 0 ..< height, across: 0 ..< width)
                    self.freezeZoomBase(ScrollComposition(axis: .vertical, base: id, region: region,
                                                          layers: [.init(frame: id, shift: 0, lines: region.along)],
                                                          blank: 0, fillFrom: nil),
                                        viewport: CGSize(width: width, height: height))
                }
            }
        }
    }

    private func freezeZoomBase(_ composition: ScrollComposition, viewport: CGSize? = nil) {
        zoomBase = composition
        if let viewport { zoom?.viewport = viewport }
        zoomFrames = Set([composition.base] + composition.layers.map(\.frame))
    }

    public func pinch(scale: Double, centroid: CGPoint) { zoom?.pinch(scale: scale, centroid: centroid) }

    /// The fingers lifted. `send` asks the app to zoom by `scale` (relative) about `focus`
    /// (viewport pixels) and returns the seq and absolute scale it asked for, or nil when it
    /// cannot, in which case the content settles back to the app's scale.
    public func endZoom(at time: TimeInterval, send: (_ scale: Double, _ focus: CGPoint) -> (seq: UInt64, scale: Double)?) {
        guard var zoom else { return }
        let settled = zoom.end(at: time)
        if let focus = LocalZoom.focus(zoom: settled.zoom, translation: settled.translation), let sent = send(settled.zoom, focus) {
            zoomWait = sent
            LocalScrollProfile.note(String(format: "zoom: settling at %.3f (absolute %.3f) about %.0f,%.0f, seq %llu",
                                           settled.zoom, sent.scale, focus.x, focus.y, sent.seq))
        } else {
            zoom.cancel(at: time)
            zoomWait = nil
        }
        self.zoom = zoom
    }

    private func refreshZoom(at time: CFTimeInterval, surface: WindowSurface?, layer: CAMetalLayer) -> Bool {
        guard var zoom else { return false }
        zoom.tick(at: time)
        self.zoom = zoom
        if zoom.phase == .waiting {
            if zoomWait == nil { finishZoom(); return false }
            if let since = zoom.waitingSince, time - since > Self.zoomPatience {
                LocalScrollProfile.note("zoom: no picture at the new scale within \(Int(Self.zoomPatience * 1000)) ms; handing back")
                finishZoom()
                return false
            }
        }
        guard var composition = zoomBase else { return false }
        composition.zoom = zoom.zoom
        composition.translation = zoom.translation
        return draw(composition, into: layer, at: time)
    }

    private func finishZoom() {
        guard zoom != nil || zoomBase != nil else { return }
        zoom = nil
        zoomBase = nil
        zoomWait = nil
        zoomFrames = []
        isComposing = false
        releaseTextures(keeping: Set(model.retainedFrames))
    }

    private func releaseTextures(keeping kept: Set<UInt64>) {
        let dropped = textures.filter { !kept.contains($0.key) }
        guard !dropped.isEmpty else { return }
        for id in dropped.keys { textures[id] = nil; fills[id] = nil }
        renderer.recycle(Array(dropped.values))
    }
}
