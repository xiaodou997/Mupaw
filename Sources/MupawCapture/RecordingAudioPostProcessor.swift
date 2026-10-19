@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import MupawCore

enum RecordingAudioPostProcessorError: Error, LocalizedError, Sendable {
    case invalidIntermediateTracks
    case couldNotCreateReader(String)
    case couldNotCreateWriter(String)
    case couldNotAddOutput(String)
    case couldNotStart(String)
    case appendFailed(String)
    case finishFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidIntermediateTracks:
            "The intermediate recording does not contain the requested audio lanes."
        case .couldNotCreateReader(let message):
            "Could not read the intermediate recording: \(message)"
        case .couldNotCreateWriter(let message):
            "Could not create the final mixed MP4: \(message)"
        case .couldNotAddOutput(let message):
            "Could not configure the final mixed MP4: \(message)"
        case .couldNotStart(let message):
            "Could not start final audio mixing: \(message)"
        case .appendFailed(let message):
            "Could not write the final mixed MP4: \(message)"
        case .finishFailed(let message):
            "Could not finish the final mixed MP4: \(message)"
        }
    }
}

enum RecordingAudioPostProcessor {
    private final class PumpState: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: Error?

        func record(_ error: Error) {
            lock.lock()
            failure = failure ?? error
            lock.unlock()
        }

        func recordedFailure() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
    }

    static func makeFinalMP4(
        intermediateURL: URL,
        outputURL: URL,
        audioSource: RecordingAudioSource,
        controlEvents: [RecordingAudioControlEvent]
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let asset = AVURLAsset(url: intermediateURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let expectedAudioTrackCount = audioSource.isMixed ? 2 : 1
        guard audioSource.isEnabled,
            videoTracks.count == 1,
            audioTracks.count == expectedAudioTrackCount,
            let videoTrack = videoTracks.first
        else {
            throw RecordingAudioPostProcessorError.invalidIntermediateTracks
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw RecordingAudioPostProcessorError.couldNotCreateReader(
                error.localizedDescription
            )
        }

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw RecordingAudioPostProcessorError.couldNotAddOutput("video reader output")
        }
        reader.add(videoOutput)

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MupawConstants.recordingMixedAudioSampleRate,
            AVNumberOfChannelsKey: MupawConstants.recordingMixedAudioChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let audioOutput = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: pcmSettings
        )
        audioOutput.alwaysCopiesSampleData = false
        audioOutput.audioMix = makeAudioMix(
            audioTracks: audioTracks,
            audioSource: audioSource,
            controlEvents: controlEvents
        )
        guard reader.canAdd(audioOutput) else {
            throw RecordingAudioPostProcessorError.couldNotAddOutput("audio mix output")
        }
        reader.add(audioOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecordingAudioPostProcessorError.couldNotCreateWriter(
                error.localizedDescription
            )
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoDescriptions = try await videoTrack.load(.formatDescriptions)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoDescriptions.first
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else {
            throw RecordingAudioPostProcessorError.couldNotAddOutput("video writer input")
        }
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: MupawConstants.recordingMixedAudioSampleRate,
            AVNumberOfChannelsKey: MupawConstants.recordingMixedAudioChannelCount,
            AVEncoderBitRateKey: MupawConstants.recordingMixedAudioBitRate,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw RecordingAudioPostProcessorError.couldNotAddOutput("AAC writer input")
        }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw RecordingAudioPostProcessorError.couldNotStart(
                writer.error?.localizedDescription ?? "AVAssetWriter rejected startWriting."
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw RecordingAudioPostProcessorError.couldNotStart(
                reader.error?.localizedDescription ?? "AVAssetReader rejected startReading."
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await pump(
                reader: reader,
                writer: writer,
                videoOutput: videoOutput,
                videoInput: videoInput,
                audioOutput: audioOutput,
                audioInput: audioInput
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path
            )
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    private static func makeAudioMix(
        audioTracks: [AVAssetTrack],
        audioSource: RecordingAudioSource,
        controlEvents: [RecordingAudioControlEvent]
    ) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        let events = normalizedEvents(controlEvents)
        var parameters: [AVAudioMixInputParameters] = []

        for (index, track) in audioTracks.enumerated() {
            let lane: RecordingAudioLane
            if audioSource.isMixed {
                lane = index == 0 ? .systemAudio : .microphone
            } else if audioSource == .systemAudio {
                lane = .systemAudio
            } else {
                lane = .microphone
            }
            let inputParameters = AVMutableAudioMixInputParameters(track: track)
            for event in events {
                let volume = effectiveVolume(lane: lane, controls: event.controls)
                inputParameters.setVolume(
                    volume,
                    at: CMTime(
                        seconds: max(0, event.elapsedSeconds),
                        preferredTimescale: 60_000
                    )
                )
            }
            parameters.append(inputParameters)
        }
        mix.inputParameters = parameters
        return mix
    }

    private static func normalizedEvents(
        _ events: [RecordingAudioControlEvent]
    ) -> [RecordingAudioControlEvent] {
        let sorted = events.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        guard let first = sorted.first else {
            return [
                RecordingAudioControlEvent(
                    elapsedSeconds: 0,
                    controls: RecordingAudioControls()
                )
            ]
        }
        if first.elapsedSeconds <= 0.000_001 { return sorted }
        return [RecordingAudioControlEvent(elapsedSeconds: 0, controls: first.controls)] + sorted
    }

    private static func effectiveVolume(
        lane: RecordingAudioLane,
        controls: RecordingAudioControls
    ) -> Float {
        switch lane {
        case .systemAudio:
            controls.systemAudioMuted ? 0 : Float(controls.systemAudioGain)
        case .microphone:
            controls.microphoneMuted ? 0 : Float(controls.microphoneGain)
        }
    }

    private static func pump(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderOutput,
        audioInput: AVAssetWriterInput
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let state = PumpState()

            group.enter()
            let videoQueue = DispatchQueue(label: "com.xiaodou.mupaw.mix.video")
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        if !videoInput.append(sample) {
                            state.record(
                                RecordingAudioPostProcessorError.appendFailed(
                                    writer.error?.localizedDescription
                                        ?? "The final video sample was rejected."
                                )
                            )
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.enter()
            let audioQueue = DispatchQueue(label: "com.xiaodou.mupaw.mix.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        if !audioInput.append(sample) {
                            state.record(
                                RecordingAudioPostProcessorError.appendFailed(
                                    writer.error?.localizedDescription
                                        ?? "The final mixed-audio sample was rejected."
                                )
                            )
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    } else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                if let failure = state.recordedFailure() {
                    continuation.resume(throwing: failure)
                    return
                }
                if reader.status == .failed {
                    continuation.resume(
                        throwing: RecordingAudioPostProcessorError.appendFailed(
                            reader.error?.localizedDescription ?? "AVAssetReader failed."
                        )
                    )
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: RecordingAudioPostProcessorError.finishFailed(
                                writer.error?.localizedDescription ?? "AVAssetWriter failed."
                            )
                        )
                    }
                }
            }
        }
    }
}
