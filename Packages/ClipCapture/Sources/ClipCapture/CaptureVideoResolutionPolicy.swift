import Foundation

/// Selects the ScreenCaptureKit resolution that preserves a source's native
/// backing pixels. The invariant is `contentScale = 1`: WindowServer must
/// neither enlarge nor reduce the source before Clip receives the raw frame.
///
/// Apple's names describe resolution policy, not resulting sharpness:
///
/// - `.nominal` forces one captured pixel per logical source point.
/// - `.best` asks for the highest available backing resolution.
///
/// That distinction matters whenever a 1× external display and a 2× Retina
/// display are both active. For independent-window capture, `.best` can select
/// the Retina compositor even when the window is physically on the 1× display.
/// ScreenCaptureKit then low-pass downsamples that 2× composition into Clip's
/// requested 1× output.
///
/// | Topology and source | Resolution | SCK mapping | Result |
/// | --- | --- | --- | --- |
/// | External-only 1× | nominal | 1× → 1× | sharp |
/// | External-only 1× | best | 1× → 1× | sharp |
/// | Retina active, external 1× source | nominal | 1× → 1× | sharp |
/// | Retina active, external 1× source | best | 2× → 1× | blurry |
/// | Retina 2× source | nominal | 1× → 2× | blurry |
/// | Retina 2× source | best | 2× → 2× | sharp |
///
/// The frame attachments expose the same matrix:
///
/// - Correct external capture: `scaleFactor = 1`, `contentScale = 1`.
/// - Broken external capture: `scaleFactor = 2`, `contentScale = 0.5`.
/// - Correct Retina capture: `scaleFactor = 2`, `contentScale = 1`.
/// - Broken Retina capture: `scaleFactor = 1`, `contentScale = 2`.
///
/// Therefore a 1× source must use `.nominal`, while a genuine Retina source
/// must use `.best`.
public enum CaptureVideoResolutionPolicy {
    public static func nativeScale(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        sourcePointWidth: Int,
        sourcePointHeight: Int
    ) -> CaptureVideoResolution {
        let horizontalScale = Double(max(1, sourcePixelWidth))
            / Double(max(1, sourcePointWidth))
        let verticalScale = Double(max(1, sourcePixelHeight))
            / Double(max(1, sourcePointHeight))
        return max(horizontalScale, verticalScale) < 1.5
            ? .nominal
            : .best
    }
}
