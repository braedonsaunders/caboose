#if canImport(UIKit)
import UIKit

/// Shared display-paced scroll delivery. The receiver gets each frame's movement and, at
/// the end, the finger's lift velocity (zero for a lift at rest); it validates its captured
/// session and window every time and returns false when that input target is no longer live.
@MainActor
public final class ScrollDriver: NSObject {
    public typealias Send = (_ delta: CGPoint, _ lift: CGPoint?) -> Bool
    private var physics = ScrollPhysics()
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var send: Send?

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(cancel),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    public func begin(at time: TimeInterval, send: @escaping Send) {
        cancel()
        physics.begin(at: time)
        self.send = send
    }

    public func append(_ delta: CGPoint, at time: TimeInterval) {
        physics.append(delta, at: time)
        if physics.needsFrame { startLink() }
    }

    /// The finger lifted: what it moved since the last frame goes now, with its velocity,
    /// so the computer starts coasting without waiting for a frame.
    public func end(at time: TimeInterval, velocity: CGPoint? = nil, coast: Bool = true, remainingContacts: Int = 0) {
        physics.end(at: time, velocity: velocity, coast: coast, remainingContacts: remainingContacts)
        let elapsed = lastFrame.map { max(0, CACurrentMediaTime() - $0) } ?? 0
        let step = physics.frame(elapsed: elapsed)
        if step.delta != .zero || step.lift != nil { _ = send?(step.delta, step.lift) }
        cancel()
    }

    @objc public func cancel() {
        link?.invalidate()
        link = nil
        lastFrame = nil
        physics.cancel()
        send = nil
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: ScrollLinkTarget(self), selector: #selector(ScrollLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        lastFrame = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let step = physics.frame(elapsed: max(0, now - (lastFrame ?? now)))
        lastFrame = now
        if step.delta != .zero || step.lift != nil, send?(step.delta, step.lift) != true { cancel(); return }
        if !physics.needsFrame {
            // Tracking can resume with another sample; keep its receiver and velocity.
            link.invalidate()
            self.link = nil
            lastFrame = nil
        }
    }
}

private final class ScrollLinkTarget: NSObject {
    weak var driver: ScrollDriver?
    init(_ driver: ScrollDriver) { self.driver = driver }
    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let driver else { link.invalidate(); return }
        driver.tick(link)
    }
}
#endif
