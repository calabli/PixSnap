import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How a recording becomes a GIF: which moments to take frames from, how big, and how long each
/// shows. GIFs get large fast, so they're smaller and choppier than the video: at most `fps` frames
/// a second and `maxWidth` pixels wide.
public struct GIFPlan: Equatable, Sendable {
    /// The moments, in seconds from the start, to take each frame from.
    public let times: [Double]
    /// How long each frame shows, in seconds (GIF delays are in hundredths).
    public let frameDelay: Double
    public let size: CGSize

    public init(duration: Double, sourceSize: CGSize, fps: Double = 15, maxWidth: CGFloat = 800) {
        let rate = max(1, fps)
        let count = max(1, Int((duration * rate).rounded(.down)))
        // Rounded to what a GIF can store, so the GIF lasts as long as the video.
        let delay = max(0.02, (100 / rate).rounded() / 100)
        frameDelay = delay
        times = (0 ..< count).map { Double($0) * delay }.filter { $0 < max(duration, 0.001) }
        let scale = min(1, maxWidth / max(sourceSize.width, 1))
        // Even sizes scale cleanly.
        size = CGSize(width: max(2, (sourceSize.width * scale / 2).rounded() * 2),
                      height: max(2, (sourceSize.height * scale / 2).rounded() * 2))
    }
}

/// The size to record a region at: its full resolution, unless that's more than video encoders
/// handle well, then scaled down to fit `maxSide`. Always even, as H.264 needs.
public func recordingPixelSize(points: CGSize, scale: CGFloat, maxSide: CGFloat = 3840) -> CGSize {
    let fit = min(scale, maxSide / max(points.width, points.height, 1))
    return CGSize(width: max(2, (points.width * fit / 2).rounded() * 2), height: max(2, (points.height * fit / 2).rounded() * 2))
}
