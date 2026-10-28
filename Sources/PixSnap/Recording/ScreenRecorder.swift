import AVFoundation
import PixSnapCore
import ScreenCaptureKit

/// Records a region of a display to an MP4 (H.264) file: ScreenCaptureKit streams the region's
/// frames (leaving out the recording's own frame and controls), and AVAssetWriter encodes them as they come.
final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    /// The file being written, in Caches until saved somewhere.
    let url: URL
    let pixelSize: CGSize

    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// Frames arrive and are written here; the timing fields are only touched on it.
    private let queue = DispatchQueue(label: "com.pixsnap.PixSnap.recording")
    private var firstTime: CMTime?
    private var lastTime: CMTime?

    /// Where recordings are written until they're saved; cleaned up after a day.
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.pixsnap.PixSnap/Recordings", isDirectory: true)

    init(filter: SCContentFilter, sourceRect: CGRect, pixelSize: CGSize, fps: Int, showsCursor: Bool) throws {
        self.pixelSize = pixelSize
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        url = Self.folder.appendingPathComponent("\(UUID().uuidString).mp4")

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = showsCursor
        configuration.queueDepth = 6
        configuration.capturesAudio = false
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Enough for sharp text; scales with size and frame rate.
        let bitRate = min(40_000_000, max(2_000_000, Int(pixelSize.width * pixelSize.height * Double(fps) * 0.12)))
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        writer.add(input)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try await stream.startCapture()
    }

    /// Stops and finishes the file. Returns how long the recording is, or nil if nothing was
    /// recorded.
    func stop() async -> Double? {
        try? await stream.stopCapture()
        let (first, last): (CMTime?, CMTime?) = queue.sync {
            input.markAsFinished()
            return (firstTime, lastTime)
        }
        guard let first, let last else {
            writer.cancelWriting()
            return nil
        }
        writer.endSession(atSourceTime: last)
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return max(0, (last - first).seconds)
    }

    /// Stops and throws the file away.
    func cancel() async {
        try? await stream.stopCapture()
        queue.sync { input.markAsFinished() }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer) else { return }
        let time = sampleBuffer.presentationTimeStamp
        if firstTime == nil {
            firstTime = time
            writer.startSession(atSourceTime: time)
        }
        guard input.isReadyForMoreMediaData, input.append(sampleBuffer) else { return }
        lastTime = time
    }

    /// Only frames with new pixels; the stream also sends "nothing changed" and blank ones.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// Removes recordings from earlier days that were never saved.
    static func removeOldRecordings() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < dayAgo {
            try? manager.removeItem(at: file)
        }
    }
}
