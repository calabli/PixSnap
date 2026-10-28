import AVFoundation
import ImageIO
import PixSnapCore
import UniformTypeIdentifiers

/// Turns a recording into a looping GIF, smaller and at a lower frame rate than the video (see
/// `GIFPlan`), so it stays a size chat apps and documents take.
enum GIFExporter {
    /// `fps` and `maxWidth` as in `GIFPlan`; with `maxDuration`, only that much from the start.
    static func export(_ video: URL, duration: Double, to output: URL, fps: Double = 15, maxWidth: CGFloat = 800,
                       maxDuration: Double = .infinity) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let natural = try await track.load(.naturalSize)
        let plan = GIFPlan(duration: min(duration, maxDuration), sourceSize: natural, fps: fps, maxWidth: maxWidth)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = plan.size
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.appliesPreferredTrackTransform = true

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, plan.times.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Loop forever.
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: plan.frameDelay]] as CFDictionary
        for time in plan.times {
            let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
