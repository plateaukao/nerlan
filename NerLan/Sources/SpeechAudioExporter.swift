import AVFoundation

/// Transcodes episode audio to a small mono 16 kHz AAC .m4a before upload.
/// OpenAI's transcription endpoint caps uploads at 25 MB; spoken audio at this
/// bitrate stays well under that even for long episodes, and mono 16 kHz is the
/// format speech recognition expects. Falls back to the source file on failure.
enum SpeechAudioExporter {
    /// Max audio duration per transcription request. The gpt-4o-transcribe models
    /// reject audio longer than 1400 s; we split below that with margin. whisper-1
    /// has no duration cap, but chunking it as well keeps one code path and is
    /// harmless (the per-chunk transcripts are concatenated).
    static let maxChunkSeconds: Double = 1200

    /// Transcode the audio and split it into chunks each no longer than
    /// `maxChunkSeconds`, returned in order (caller deletes the temp files). A
    /// short episode yields a single chunk. Falls back to `[sourceURL]` if
    /// transcoding isn't possible.
    static func exportChunks(_ sourceURL: URL) async -> [URL] {
        (try? await transcodeChunks(sourceURL)) ?? [sourceURL]
    }

    private enum Failure: Error { case noAudioTrack, cannotRead, cannotWrite }

    private static func transcodeChunks(_ sourceURL: URL) async throws -> [URL] {
        let asset = AVURLAsset(url: sourceURL)
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
            throw Failure.noAudioTrack
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.cannotRead }

        if duration <= maxChunkSeconds {
            return [try await transcode(sourceURL, timeRange: nil)]
        }
        let chunkCount = Int((duration / maxChunkSeconds).rounded(.up))
        var urls: [URL] = []
        do {
            for i in 0..<chunkCount {
                let start = Double(i) * maxChunkSeconds
                let length = min(maxChunkSeconds, duration - start)
                let range = CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: length, preferredTimescale: 600))
                urls.append(try await transcode(sourceURL, timeRange: range))
            }
        } catch {
            // A failing later chunk must not strand the earlier ones: the caller
            // only ever sees the [sourceURL] fallback, so these temp files would
            // otherwise pile up (~5 MB per chunk) until the OS purges them.
            for url in urls { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return urls
    }

    private static func transcode(_ sourceURL: URL, timeRange: CMTimeRange?) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
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
        // Once the writer exists its output file may too; delete it on any
        // failure below so an aborted transcode leaves nothing in temp.
        func fail(_ error: Error) -> Error {
            try? FileManager.default.removeItem(at: outputURL)
            return error
        }
        guard writer.canAdd(writerInput) else { throw fail(Failure.cannotWrite) }
        writer.add(writerInput)

        guard reader.startReading() else { throw fail(reader.error ?? Failure.cannotRead) }
        guard writer.startWriting() else { throw fail(writer.error ?? Failure.cannotWrite) }
        // Trimmed reads yield buffers timestamped at the chunk's source time, so
        // start the session there (we only ever append in-range samples, so the
        // chunk file holds just that segment — no leading silence).
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

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
            throw fail(writer.error ?? reader.error ?? Failure.cannotWrite)
        }
        return outputURL
    }
}
