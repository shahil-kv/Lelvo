import Foundation
import AVFoundation
import MemvoCore

/// Encodes a video's fast version (role `sp`): HEVC at `StreamingCopyPolicy.targetBitsPerSecond`, at most 1080p and
/// 30 fps, SDR, AAC audio, `moov` first. Apple's export presets can't set a bitrate (their 1080p HEVC is ~9 Mbit/s,
/// more than Telegram delivers to free accounts), so this reads and writes the frames itself.
enum StreamingCopyEncoder {
    static func encode(_ asset: AVAsset, to url: URL) async throws -> (url: URL, width: Int, height: Int) {
        try? FileManager.default.removeItem(at: url)
        let job = try await Job(asset: asset, url: url)
        try await withTaskCancellationHandler { try await job.run() } onCancel: { job.cancel() }
        return (url, job.width, job.height)
    }

    /// Owns the reader and writer; AVFoundation drives them from its own queues.
    private final class Job: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoOut: AVAssetReaderVideoCompositionOutput
        let videoIn: AVAssetWriterInput
        let audioOut: AVAssetReaderAudioMixOutput?
        let audioIn: AVAssetWriterInput?
        let width: Int
        let height: Int

        init(asset: AVAsset, url: URL) async throws {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else { throw StreamingCopyError.unsupported }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            // Applies the rotation and Photos' edits (slow motion, trims); also converts HDR to standard colour,
            // which every screen shows correctly at this size.
            let composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            let fps = try await track.load(.nominalFrameRate)
            if fps > 30 { composition.frameDuration = CMTime(value: 1, timescale: 30) }
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

            let shown = composition.renderSize
            let scale = min(1, 1920 / max(shown.width, shown.height, 1))
            width = Int((shown.width * scale / 2).rounded()) * 2
            height = Int((shown.height * scale / 2).rounded()) * 2
            guard width > 0, height > 0 else { throw StreamingCopyError.unsupported }

            reader = try AVAssetReader(asset: asset)
            videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            videoOut.videoComposition = composition
            videoOut.alwaysCopiesSampleData = false
            guard reader.canAdd(videoOut) else { throw StreamingCopyError.unsupported }
            reader.add(videoOut)

            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true
            videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(StreamingCopyPolicy.targetBitsPerSecond),
                    AVVideoExpectedSourceFrameRateKey: min(30, Int(fps.rounded())),
                    // A seek can only show a picture from a keyframe: one per second keeps the data needed before
                    // a seek small (the sound would otherwise play over a frozen picture while it downloads).
                    AVVideoMaxKeyFrameIntervalDurationKey: 1
                ]
            ])
            videoIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoIn) else { throw StreamingCopyError.unsupported }
            writer.add(videoIn)

            if !audioTracks.isEmpty {
                let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2
                ])
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ])
                input.expectsMediaDataInRealTime = false
                if reader.canAdd(out), writer.canAdd(input) {
                    reader.add(out)
                    writer.add(input)
                    audioOut = out
                    audioIn = input
                } else {
                    audioOut = nil
                    audioIn = nil
                }
            } else {
                audioOut = nil
                audioIn = nil
            }
        }

        func run() async throws {
            guard reader.startReading() else { throw reader.error ?? StreamingCopyError.unsupported }
            guard writer.startWriting() else { throw writer.error ?? StreamingCopyError.unsupported }
            writer.startSession(atSourceTime: .zero)
            async let video: Void = pump(audio: false)
            if audioOut != nil { await pump(audio: true) }
            await video
            try Task.checkCancellation()
            if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? StreamingCopyError.unsupported }
            await writer.finishWriting()
            if writer.status != .completed { throw writer.error ?? StreamingCopyError.unsupported }
        }

        private let lock = NSLock()
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        private var cancelled = false

        func cancel() {
            let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
                cancelled = true
                defer { waiting.removeAll() }
                return Array(waiting.values)
            }
            reader.cancelReading()
            writer.cancelWriting()
            // A cancelled writer may never ask for data again: release the waiting pumps here.
            pending.forEach { $0.resume() }
        }

        /// Resumes the pump `id` once, whichever comes first: its end, a failed append or `cancel()`.
        private func finish(_ id: Int) {
            lock.withLock { waiting.removeValue(forKey: id) }?.resume()
        }

        /// Copies one track's samples from the reader to the writer until the end, a failure or `cancel()`.
        private func pump(audio: Bool) async {
            let id = audio ? 1 : 0
            let label = audio ? "memvo.encode.audio" : "memvo.encode.video"
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let alreadyCancelled = lock.withLock {
                    if !cancelled { waiting[id] = done }
                    return cancelled
                }
                if alreadyCancelled { done.resume(); return }
                let queueInput: AVAssetWriterInput = audio ? audioIn! : videoIn
                queueInput.requestMediaDataWhenReady(on: DispatchQueue(label: label)) { [self] in
                    // Read through `self` (thread-safe by design here) rather than capturing the AVFoundation objects.
                    let input: AVAssetWriterInput = audio ? audioIn! : videoIn
                    let output: AVAssetReaderOutput = audio ? audioOut! : videoOut
                    while input.isReadyForMoreMediaData {
                        guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            finish(id)
                            return
                        }
                        if !input.append(sample) {
                            reader.cancelReading()
                            input.markAsFinished()
                            finish(id)
                            return
                        }
                    }
                }
            }
        }
    }
}
