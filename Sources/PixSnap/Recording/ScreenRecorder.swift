import AVFoundation
import PixSnapCore
import ScreenCaptureKit

/// Records a region of a display to an MP4 (H.264) file: ScreenCaptureKit streams the region's
/// frames (leaving out the recording's own frame and controls), and AVAssetWriter encodes them as they come.
/// The system's sound and the microphone, when asked for, go into AAC tracks of their own. Pausing
/// drops what comes in meanwhile and closes the gap, so the video plays straight through.
final class ScreenRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    /// The file being written, in Caches until saved somewhere.
    let url: URL
    let pixelSize: CGSize

    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    /// Frames arrive and are written here; the timing fields are only touched on it.
    private let queue = DispatchQueue(label: "com.pixsnap.PixSnap.recording")
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    /// While paused, when the pause began (host clock, as the samples' times are).
    private var pausedAt: CMTime?
    /// Time spent paused so far, taken off every later sample.
    private var pausedFor = CMTime.zero

    /// Where recordings are written until they're saved; cleaned up after a day.
    static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.pixsnap.PixSnap/Recordings", isDirectory: true)

    init(filter: SCContentFilter, sourceRect: CGRect, pixelSize: CGSize, fps: Int, showsCursor: Bool,
         recordsSystemAudio: Bool = false, recordsMicrophone: Bool = false) throws {
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
        configuration.capturesAudio = recordsSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        let usesMicrophone: Bool
        if #available(macOS 15, *), recordsMicrophone {
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
            usesMicrophone = true
        } else {
            usesMicrophone = false
        }
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
        systemAudio = recordsSystemAudio ? Self.audioInput(channels: 2) : nil
        microphone = usesMicrophone ? Self.audioInput(channels: 1) : nil
        super.init()
        writer.add(input)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if let systemAudio {
            writer.add(systemAudio)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if #available(macOS 15, *), let microphone {
            writer.add(microphone)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels * 64000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// Stops taking in frames and sound until `resume()`.
    func pause() {
        queue.sync { if pausedAt == nil { pausedAt = Self.now } }
    }

    func resume() {
        queue.sync {
            guard let pausedAt else { return }
            pausedFor = pausedFor + (Self.now - pausedAt)
            self.pausedAt = nil
        }
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

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
            systemAudio?.markAsFinished()
            microphone?.markAsFinished()
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
        queue.sync {
            input.markAsFinished()
            systemAudio?.markAsFinished()
            microphone?.markAsFinished()
        }
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, pausedAt == nil else { return }
        if type == .screen {
            guard Self.isComplete(sampleBuffer), let buffer = shifted(sampleBuffer) else { return }
            let time = buffer.presentationTimeStamp
            if firstTime == nil {
                firstTime = time
                writer.startSession(atSourceTime: time)
            }
            guard input.isReadyForMoreMediaData, input.append(buffer) else { return }
            lastTime = max(lastTime ?? time, time)
            return
        }
        // Sound starts with the first frame, so the tracks line up.
        let audio: AVAssetWriterInput?
        if type == .audio {
            audio = systemAudio
        } else if #available(macOS 15, *), type == .microphone {
            audio = microphone
        } else {
            audio = nil
        }
        guard let audio, let firstTime, let buffer = shifted(sampleBuffer) else { return }
        let time = buffer.presentationTimeStamp
        guard time >= firstTime, audio.isReadyForMoreMediaData, audio.append(buffer) else { return }
        lastTime = max(lastTime ?? time, time + buffer.duration)
    }

    /// The sample moved earlier by the time spent paused.
    private func shifted(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard pausedFor != .zero else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: timing.count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - pausedFor
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - pausedFor }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: timing.count,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy
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
