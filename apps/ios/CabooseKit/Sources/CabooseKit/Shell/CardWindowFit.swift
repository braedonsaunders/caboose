import CoreGraphics
import Foundation

/// Reassert a card's viewport after an app resizes itself, without a configure loop
/// when the app enforces a larger minimum size. A later resize starts a new burst.
public struct CardWindowFit {
    private var target: CGRect?
    private var lastCorrection: TimeInterval = -.infinity
    private var corrections = 0

    public init() {}

    public mutating func shouldCorrect(frame: CGRect, target: CGRect, now: TimeInterval) -> Bool {
        guard target.width > 0, target.height > 0, frame != target else { return false }
        if self.target != target || now - lastCorrection > 1 {
            self.target = target
            corrections = 0
        }
        guard corrections < 2 else { return false }
        corrections += 1
        lastCorrection = now
        return true
    }
}
