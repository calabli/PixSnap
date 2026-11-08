import AVFoundation
import CoreImage
import PixSnapCore
import PixSnapRender

/// 精修's media: the recording with its cuts and speed-ups (`VideoEdit`) as one composition, the
/// finish drawn over it, and writing that out for a preset.
enum StudioMedia {
    /// The recording as edited: cut stretches gone, sped-up ones faster and silent (sound at 4× is
    /// only noise). Every audio track is kept, to be mixed into one on export.
    static func edited(_ asset: AVAsset, edit: VideoEdit, duration: Double) async throws -> AVAsset {
        guard !edit.changes.isEmpty else { return asset }
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let sounds = try await asset.loadTracks(withMediaType: .audio)
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.featureUnsupported)
        }
        picture.preferredTransform = try await source.load(.preferredTransform)
        let soundTracks = sounds.compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        let assetDuration = try await asset.load(.duration)

        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 6000) }
        var cursor = CMTime.zero
        for piece in edit.pieces(duration: duration) where piece.speed > 0 {
            let range = CMTimeRange(start: time(piece.start), end: CMTimeMinimum(time(piece.end), assetDuration))
            guard range.duration > .zero else { continue }
            try picture.insertTimeRange(range, of: source, at: cursor)
            if piece.speed > 1 {
                let fast = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / piece.speed)
                picture.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: fast)
                for track in soundTracks { track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: fast)) }
                cursor = cursor + fast
            } else {
                for (track, sound) in zip(soundTracks, sounds) {
                    try? track.insertTimeRange(range, of: sound, at: cursor)
                }
                cursor = cursor + range.duration
            }
        }
        return composition
    }

    /// The finish over `asset` (already edited), its frames `outputScale` of the finished size.
    static func composition(for asset: AVAsset, style: RecordingFinisher.Style, plan: ZoomPlan, scale: CGFloat, videoSize: CGSize,
                            timeline: RecordingTimeline?, outputSize: CGSize? = nil) async throws -> AVVideoComposition {
        let full = RecordingFinisher.outputSize(video: videoSize, scale: scale, style: style)
        let size = outputSize ?? full
        let shrink = size.width / max(full.width, 1)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            var frame = RecordingFinisher.frame(request.sourceImage, at: request.compositionTime.seconds, plan: plan, scale: scale, style: style,
                                                timeline: timeline)
            if abs(shrink - 1) > 0.001 {
                frame = frame.transformed(by: CGAffineTransform(scaleX: shrink, y: size.height / max(full.height, 1)))
            }
            request.finish(with: frame, context: nil)
        }
        composition.renderSize = size
        return composition
    }

    /// Writes `asset` with `composition` as an H.264 MP4 at `bitRate`, its sound mixed into one
    /// AAC track. `progress` gets 0…1 as it goes.
    static func write(_ asset: AVAsset, composition: AVVideoComposition, bitRate: Double, to url: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let duration = try await asset.load(.duration).seconds
        let pictures = try await asset.loadTracks(withMediaType: .video)
        let sounds = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let pictureOut = AVAssetReaderVideoCompositionOutput(videoTracks: pictures, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        pictureOut.videoComposition = composition
        reader.add(pictureOut)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let size = composition.renderSize
        let pictureIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ])
        pictureIn.expectsMediaDataInRealTime = false
        writer.add(pictureIn)
        var pumps = [AudioMerger.Pump(input: pictureIn) {
            let sample = pictureOut.copyNextSampleBuffer()
            if let sample { progress(min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / max(duration, 0.01))) }
            return sample
        }]

        if !sounds.isEmpty {
            let soundOut = AVAssetReaderAudioMixOutput(audioTracks: sounds, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(soundOut)
            let soundIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: Int(ExportPreset.audioBitRate),
            ])
            writer.add(soundIn)
            pumps.append(AudioMerger.Pump(input: soundIn, output: soundOut))
        }

        guard reader.startReading(), writer.startWriting() else { throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps { group.addTask { await pump.run() } }
        }
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}
