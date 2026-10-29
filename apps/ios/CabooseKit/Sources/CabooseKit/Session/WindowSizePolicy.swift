import CoreGraphics

/// Ordinary window requests in guest pixels. Minimum/maximum hints are per axis;
/// zero, negative and non-finite values mean no constraint. An inconsistent maximum
/// never overrides a minimum. Fullscreen geometry belongs to the compositor.
public enum WindowSizePolicy {
    public static func request(_ proposed: CGRect, minimum: CGSize?, maximum: CGSize?,
                               fullscreen: Bool) -> CGRect? {
        guard !fullscreen, proposed.minX.isFinite, proposed.minY.isFinite,
              proposed.width.isFinite, proposed.height.isFinite,
              proposed.width > 0, proposed.height > 0 else { return nil }

        func dimension(_ desired: CGFloat, _ lower: CGFloat?, _ upper: CGFloat?) -> CGFloat {
            let minValue = lower.flatMap { $0.isFinite && $0 > 0 ? max(1, $0.rounded(.up)) : nil } ?? 1
            let maxValue = upper.flatMap { $0.isFinite && $0 > 0 ? max(minValue, $0.rounded(.down)) : nil }
            let value = max(minValue, desired.rounded(.up))
            return maxValue.map { min(value, $0) } ?? value
        }
        return CGRect(x: proposed.minX.rounded(), y: proposed.minY.rounded(),
                      width: dimension(proposed.width, minimum?.width, maximum?.width),
                      height: dimension(proposed.height, minimum?.height, maximum?.height))
    }
}
