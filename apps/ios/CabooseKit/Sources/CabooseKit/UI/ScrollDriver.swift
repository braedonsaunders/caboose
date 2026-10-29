#if canImport(UIKit)
import UIKit

/// Shared display-paced scroll delivery. The receiver validates its captured session
/// and window on every frame and returns false when that input target is no longer live.
@MainActor
public final class ScrollDriver: NSObject {
    private var physics = ScrollPhysics()
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    private var send: ((CGPoint) -> Bool)?

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(cancel),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    public func begin(at time: TimeInterval, send: @escaping (CGPoint) -> Bool) {
        cancel()
        physics.begin(at: time)
        self.send = send
    }

    public func append(_ delta: CGPoint, at time: TimeInterval) {
        physics.append(delta, at: time)
        if physics.needsFrame { startLink() }
    }

    public func end(at time: TimeInterval, velocity: CGPoint? = nil, coast: Bool = true) {
        physics.end(at: time, velocity: velocity, coast: coast)
        if physics.needsFrame { startLink() }
        else { cancel() }
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
        let delta = physics.frame(elapsed: max(0, now - (lastFrame ?? now)))
        lastFrame = now
        if delta != .zero, send?(delta) != true { cancel(); return }
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
