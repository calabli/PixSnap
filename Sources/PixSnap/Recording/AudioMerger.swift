import AVFoundation

/// Recordings keep the Mac's sound and the microphone in two tracks; many players (and chat apps)
/// only play the first. This mixes every audio track of a finished video into one, copying the
/// picture as it is.
enum AudioMerger {
    /// Rewrites `video` in place with one audio track, when it has more than one.
    static func mergeAudio(of video: URL) async throws {
        let asset = AVURLAsset(url: video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1, let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }

        let output = video.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        let reader = try AVAssetReader(asset: asset)
        let pictureOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        let soundOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(pictureOut)
        reader.add(soundOut)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let formats = try await videoTrack.load(.formatDescriptions)
        let pictureIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        pictureIn.transform = try await videoTrack.load(.preferredTransform)
        let soundIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
        ])
        writer.add(pictureIn)
        writer.add(soundIn)

        guard reader.startReading(), writer.startWriting() else { throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for (input, source) in [(pictureIn, pictureOut as AVAssetReaderOutput), (soundIn, soundOut as AVAssetReaderOutput)] {
                let pump = Pump(input: input, output: source)
                group.addTask { await pump.run() }
            }
        }
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(video, withItemAt: output)
    }

    /// Copies one track's samples across as fast as the writer takes them.
    private final class Pump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        private let queue = DispatchQueue(label: "com.pixsnap.PixSnap.merge")

        init(input: AVAssetWriterInput, output: AVAssetReaderOutput) {
            self.input = input
            self.output = output
        }

        func run() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                        input.append(sample)
                    }
                }
            }
        }
    }
}
