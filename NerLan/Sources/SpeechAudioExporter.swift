import AVFoundation

/// Transcodes episode audio to a small mono 16 kHz AAC .m4a before upload.
/// OpenAI's transcription endpoint caps uploads at 25 MB; spoken audio at this
/// bitrate stays well under that even for long episodes, and mono 16 kHz is the
/// format speech recognition expects. Falls back to the source file on failure.
enum SpeechAudioExporter {
    /// Returns a temp .m4a URL (caller deletes it) or the original URL if
    /// transcoding isn't possible.
    static func export(_ sourceURL: URL) async -> URL {
        (try? await transcode(sourceURL)) ?? sourceURL
    }

    private enum Failure: Error { case noAudioTrack, cannotRead, cannotWrite }

    private static func transcode(_ sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
            ])
        guard reader.canAdd(readerOutput) else { throw Failure.cannotRead }
        reader.add(readerOutput)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speech-\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw Failure.cannotWrite }
        writer.add(writerInput)

        guard reader.startReading() else { throw reader.error ?? Failure.cannotRead }
        guard writer.startWriting() else { throw writer.error ?? Failure.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.danielkao.nerlan.speechexport")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let buffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !writerInput.append(buffer) {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed, reader.status != .failed else {
            throw writer.error ?? reader.error ?? Failure.cannotWrite
        }
        return outputURL
    }
}
