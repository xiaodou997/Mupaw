@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import MupawCore
@preconcurrency import ScreenCaptureKit

struct RecordingFrameMetrics: Sendable, Equatable {
    let frameCount: Int
    let durationSeconds: Double
    let audioSampleBufferCount: Int
    let audioDurationSeconds: Double
    let audioSampleRate: Int?
    let audioChannelCount: Int?
}

enum RecordingFrameWriterError: Error, LocalizedError, Sendable {
    case couldNotCreateWriter(String)
    case couldNotAddVideoInput
    case couldNotAddAudioInput
    case couldNotStartWriting(String)
    case appendFailed(String)
    case audioAppendFailed(String)
    case invalidAudioFormat
    case noVideoFrames
    case noAudioSamples
    case pendingSamplesExceeded(String)
    case finishFailed(String)
    case alreadyFinishing

    var errorDescription: String? {
        switch self {
        case .couldNotCreateWriter(let message):
            "Could not create the MP4 writer: \(message)"
        case .couldNotAddVideoInput:
            "The MP4 writer could not accept its video input."
        case .couldNotAddAudioInput:
            "The MP4 writer could not accept its AAC system-audio input."
        case .couldNotStartWriting(let message):
            "The MP4 writer could not start: \(message)"
        case .appendFailed(let message):
            "The MP4 writer could not append a video frame: \(message)"
        case .audioAppendFailed(let message):
            "The MP4 writer could not append system audio: \(message)"
        case .invalidAudioFormat:
            "ScreenCaptureKit returned system audio in an unexpected format."
        case .noVideoFrames:
            "The recording ended before Mupaw received a video frame."
        case .noAudioSamples:
            "System audio was requested, but Mupaw received no audio samples."
        case .pendingSamplesExceeded(let track):
            "The \(track) track did not become ready before its pending-sample limit was reached."
        case .finishFailed(let message):
            "The MP4 writer could not finish: \(message)"
        case .alreadyFinishing:
            "The MP4 writer is already finishing."
        }
    }
}

final class RecordingFrameWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue: DispatchQueue

    private enum PendingSample {
        case video(CMSampleBuffer)
        case audio(CMSampleBuffer)

        var presentationTime: CMTime {
            switch self {
            case .video(let sample), .audio(let sample):
                CMSampleBufferGetPresentationTimeStamp(sample)
            }
        }
    }

    private let outputURL: URL
    private let frameRate: Int
    private let includeSystemAudio: Bool
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let stateLock = NSLock()
    private let onFailure: @Sendable (Error) -> Void

    private var sessionStartTime: CMTime?
    private var firstVideoPresentationTime: CMTime?
    private var lastVideoPresentationTime: CMTime?
    private var lastVideoSampleBuffer: CMSampleBuffer?
    private var firstAudioPresentationTime: CMTime?
    private var lastAudioEndTime: CMTime?
    private var pendingVideoSamples: [CMSampleBuffer] = []
    private var pendingAudioSamples: [CMSampleBuffer] = []
    private var wallClockStartedAt: Date?
    private var appendedFrameCount = 0
    private var appendedAudioSampleBufferCount = 0
    private var actualAudioSampleRate: Int?
    private var actualAudioChannelCount: Int?
    private var terminalError: Error?
    private var isFinishing = false
    private var didReportFailure = false

    init(
        outputURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Int,
        quality: RecordingVideoQuality,
        includeSystemAudio: Bool,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.frameRate = frameRate
        self.includeSystemAudio = includeSystemAudio
        self.sampleQueue = DispatchQueue(
            label: "com.xiaodou.mupaw.recording.frames.\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.onFailure = onFailure

        do {
            self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw RecordingFrameWriterError.couldNotCreateWriter(error.localizedDescription)
        }

        let bitRate = quality.estimatedBitRate(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            frameRate: frameRate
        )
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: compression,
        ]
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        self.videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordingFrameWriterError.couldNotAddVideoInput
        }
        writer.add(videoInput)

        if includeSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: MupawConstants.recordingSystemAudioSampleRate,
                AVNumberOfChannelsKey: MupawConstants.recordingSystemAudioChannelCount,
                AVEncoderBitRateKey: MupawConstants.recordingSystemAudioBitRate,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingFrameWriterError.couldNotAddAudioInput
            }
            writer.add(input)
            self.audioInput = input
        } else {
            self.audioInput = nil
        }
        writer.shouldOptimizeForNetworkUse = true
    }

    func prepare() throws {
        guard writer.startWriting() else {
            throw RecordingFrameWriterError.couldNotStartWriting(
                writer.error?.localizedDescription ?? "Unknown writer error."
            )
        }
        stateLock.lock()
        wallClockStartedAt = Date()
        stateLock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch outputType {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
                shouldAppendVideo(sampleBuffer)
            else {
                return
            }
            receiveVideo(sampleBuffer)

        case .audio:
            guard includeSystemAudio else { return }
            receiveAudio(sampleBuffer)

        case .microphone:
            return

        @unknown default:
            return
        }
    }

    func metricsSnapshot() -> RecordingFrameMetrics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return RecordingFrameMetrics(
            frameCount: appendedFrameCount,
            durationSeconds: videoDurationSecondsLocked(),
            audioSampleBufferCount: appendedAudioSampleBufferCount,
            audioDurationSeconds: audioDurationSecondsLocked(),
            audioSampleRate: actualAudioSampleRate,
            audioChannelCount: actualAudioChannelCount
        )
    }

    func finish() async throws -> RecordingFrameMetrics {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                startSessionAndFlushPendingIfReady()

                stateLock.lock()
                if isFinishing {
                    stateLock.unlock()
                    continuation.resume(throwing: RecordingFrameWriterError.alreadyFinishing)
                    return
                }
                isFinishing = true
                let failure = terminalError
                let frameCount = appendedFrameCount
                let audioCount = appendedAudioSampleBufferCount
                let pendingVideoCount = pendingVideoSamples.count
                let pendingAudioCount = pendingAudioSamples.count
                let startTime = sessionStartTime
                let lastVideoTime = lastVideoPresentationTime
                let lastVideoSample = lastVideoSampleBuffer
                let lastAudioEnd = lastAudioEndTime
                let wallStart = wallClockStartedAt
                stateLock.unlock()

                if let failure {
                    cancelWriterAndDelete()
                    continuation.resume(throwing: failure)
                    return
                }
                if includeSystemAudio,
                    audioCount <= 0,
                    pendingAudioCount <= 0,
                    frameCount > 0 || pendingVideoCount > 0
                {
                    cancelWriterAndDelete()
                    continuation.resume(throwing: RecordingFrameWriterError.noAudioSamples)
                    return
                }
                guard frameCount > 0,
                    let startTime,
                    let lastVideoTime,
                    let lastVideoSample
                else {
                    cancelWriterAndDelete()
                    continuation.resume(throwing: RecordingFrameWriterError.noVideoFrames)
                    return
                }
                if includeSystemAudio, audioCount <= 0 || lastAudioEnd == nil {
                    cancelWriterAndDelete()
                    continuation.resume(throwing: RecordingFrameWriterError.noAudioSamples)
                    return
                }

                let wallDuration = wallStart.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                let terminalVideoTime: CMTime
                do {
                    terminalVideoTime = try appendTerminalVideoFrameIfNeeded(
                        sessionStartTime: startTime,
                        lastVideoTime: lastVideoTime,
                        lastVideoSample: lastVideoSample,
                        wallDurationSeconds: wallDuration
                    )
                } catch {
                    cancelWriterAndDelete()
                    continuation.resume(throwing: error)
                    return
                }

                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                let videoEndTime = CMTimeAdd(terminalVideoTime, frameDuration)
                let endTime: CMTime
                if let lastAudioEnd, CMTimeCompare(lastAudioEnd, videoEndTime) > 0 {
                    endTime = lastAudioEnd
                } else {
                    endTime = videoEndTime
                }
                writer.endSession(atSourceTime: endTime)
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: metricsSnapshot())
                    } else {
                        let error = RecordingFrameWriterError.finishFailed(
                            writer.error?.localizedDescription ?? "Unknown writer error."
                        )
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func cancelAndDelete() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [self] in
                stateLock.lock()
                isFinishing = true
                stateLock.unlock()
                cancelWriterAndDelete()
                continuation.resume()
            }
        }
    }

    func cancelAndDeleteImmediately() {
        sampleQueue.async { [self] in
            stateLock.lock()
            isFinishing = true
            stateLock.unlock()
            cancelWriterAndDelete()
        }
    }

    private func receiveVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sampleIsAcceptable(sampleBuffer) else { return }
        stateLock.lock()
        let hasStarted = sessionStartTime != nil
        if !hasStarted {
            if pendingVideoSamples.count >= MupawConstants.maximumPendingRecordingSamplesPerTrack {
                stateLock.unlock()
                reportFailure(RecordingFrameWriterError.pendingSamplesExceeded("video"))
                return
            }
            pendingVideoSamples.append(sampleBuffer)
        }
        stateLock.unlock()

        if hasStarted {
            appendVideo(sampleBuffer, requireReadiness: false)
        } else {
            startSessionAndFlushPendingIfReady()
        }
    }

    private func receiveAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sampleIsAcceptable(sampleBuffer), validateAudioFormat(sampleBuffer) else { return }
        stateLock.lock()
        let hasStarted = sessionStartTime != nil
        if !hasStarted {
            if pendingAudioSamples.count >= MupawConstants.maximumPendingRecordingSamplesPerTrack {
                stateLock.unlock()
                reportFailure(RecordingFrameWriterError.pendingSamplesExceeded("audio"))
                return
            }
            pendingAudioSamples.append(sampleBuffer)
        }
        stateLock.unlock()

        if hasStarted {
            appendAudio(sampleBuffer, requireReadiness: false)
        } else {
            startSessionAndFlushPendingIfReady()
        }
    }

    private func startSessionAndFlushPendingIfReady() {
        stateLock.lock()
        guard sessionStartTime == nil,
            !pendingVideoSamples.isEmpty,
            !includeSystemAudio || !pendingAudioSamples.isEmpty,
            terminalError == nil,
            !isFinishing
        else {
            stateLock.unlock()
            return
        }

        let pending: [PendingSample] =
            pendingVideoSamples.map(PendingSample.video)
            + pendingAudioSamples.map(PendingSample.audio)
        guard
            let startTime = pending.map(\.presentationTime).min(by: {
                CMTimeCompare($0, $1) < 0
            })
        else {
            stateLock.unlock()
            return
        }
        sessionStartTime = startTime
        pendingVideoSamples.removeAll(keepingCapacity: false)
        pendingAudioSamples.removeAll(keepingCapacity: false)
        stateLock.unlock()

        writer.startSession(atSourceTime: startTime)
        for sample in pending.sorted(by: {
            CMTimeCompare($0.presentationTime, $1.presentationTime) < 0
        }) {
            switch sample {
            case .video(let buffer):
                appendVideo(buffer, requireReadiness: true)
            case .audio(let buffer):
                appendAudio(buffer, requireReadiness: true)
            }
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer, requireReadiness: Bool) {
        guard waitUntilReady(videoInput, required: requireReadiness) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard videoInput.append(sampleBuffer) else {
            reportFailure(
                RecordingFrameWriterError.appendFailed(
                    writer.error?.localizedDescription ?? "Unknown writer error."
                )
            )
            return
        }

        stateLock.lock()
        appendedFrameCount += 1
        if firstVideoPresentationTime == nil {
            firstVideoPresentationTime = presentationTime
        }
        lastVideoPresentationTime = presentationTime
        lastVideoSampleBuffer = sampleBuffer
        stateLock.unlock()
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer, requireReadiness: Bool) {
        guard let audioInput else {
            reportFailure(RecordingFrameWriterError.couldNotAddAudioInput)
            return
        }
        guard waitUntilReady(audioInput, required: requireReadiness) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let endTime = audioEndTime(for: sampleBuffer)
        guard audioInput.append(sampleBuffer) else {
            reportFailure(
                RecordingFrameWriterError.audioAppendFailed(
                    writer.error?.localizedDescription ?? "Unknown writer error."
                )
            )
            return
        }

        stateLock.lock()
        appendedAudioSampleBufferCount += 1
        if firstAudioPresentationTime == nil {
            firstAudioPresentationTime = presentationTime
        }
        lastAudioEndTime = endTime
        stateLock.unlock()
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, required: Bool) -> Bool {
        guard required else { return input.isReadyForMoreMediaData }
        let deadline = Date().addingTimeInterval(0.5)
        while !input.isReadyForMoreMediaData, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        if !input.isReadyForMoreMediaData {
            reportFailure(
                RecordingFrameWriterError.appendFailed(
                    "The writer input was not ready for an initial sample."
                )
            )
            return false
        }
        return true
    }

    private func appendTerminalVideoFrameIfNeeded(
        sessionStartTime: CMTime,
        lastVideoTime: CMTime,
        lastVideoSample: CMSampleBuffer,
        wallDurationSeconds: Double
    ) throws -> CMTime {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let desiredEnd = CMTimeAdd(
            sessionStartTime,
            CMTime(seconds: max(CMTimeGetSeconds(frameDuration), wallDurationSeconds), preferredTimescale: 60_000)
        )
        let desiredTime = CMTimeSubtract(desiredEnd, frameDuration)
        guard CMTimeCompare(desiredTime, lastVideoTime) > 0 else { return lastVideoTime }

        let deadline = Date().addingTimeInterval(0.5)
        while !videoInput.isReadyForMoreMediaData, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard videoInput.isReadyForMoreMediaData else {
            throw RecordingFrameWriterError.appendFailed(
                "The writer was not ready for the final held frame."
            )
        }

        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: desiredTime,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: lastVideoSample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard result == noErr, let retimed else {
            throw RecordingFrameWriterError.appendFailed(
                "Mupaw could not retime the final held frame (OSStatus \(result))."
            )
        }
        guard videoInput.append(retimed) else {
            throw RecordingFrameWriterError.appendFailed(
                writer.error?.localizedDescription ?? "The final held frame was rejected."
            )
        }

        stateLock.lock()
        appendedFrameCount += 1
        lastVideoPresentationTime = desiredTime
        lastVideoSampleBuffer = retimed
        stateLock.unlock()
        return desiredTime
    }

    private func validateAudioFormat(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else {
            reportFailure(RecordingFrameWriterError.invalidAudioFormat)
            return false
        }
        let sampleRate = Int(basic.mSampleRate.rounded())
        let channelCount = Int(basic.mChannelsPerFrame)
        guard sampleRate == MupawConstants.recordingSystemAudioSampleRate,
            channelCount == MupawConstants.recordingSystemAudioChannelCount
        else {
            reportFailure(RecordingFrameWriterError.invalidAudioFormat)
            return false
        }

        stateLock.lock()
        actualAudioSampleRate = sampleRate
        actualAudioChannelCount = channelCount
        stateLock.unlock()
        return true
    }

    private func audioEndTime(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 {
            return CMTimeAdd(presentationTime, duration)
        }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let durationSeconds = Double(sampleCount) / Double(MupawConstants.recordingSystemAudioSampleRate)
        return CMTimeAdd(
            presentationTime,
            CMTime(seconds: durationSeconds, preferredTimescale: 60_000)
        )
    }

    private func sampleIsAcceptable(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else { return false }
        stateLock.lock()
        let finishing = isFinishing
        let failure = terminalError
        stateLock.unlock()
        return !finishing && failure == nil
    }

    private func shouldAppendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let first = attachments.first,
            let rawValue = (first[.status] as? NSNumber)?.intValue,
            let status = SCFrameStatus(rawValue: rawValue)
        else {
            return true
        }
        switch status {
        case .complete, .idle, .started:
            return true
        case .blank, .suspended, .stopped:
            return false
        @unknown default:
            return false
        }
    }

    private func reportFailure(_ error: Error) {
        stateLock.lock()
        terminalError = terminalError ?? error
        let shouldReport = !didReportFailure
        didReportFailure = true
        stateLock.unlock()
        if shouldReport {
            onFailure(error)
        }
    }

    private func cancelWriterAndDelete() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func videoDurationSecondsLocked() -> Double {
        guard appendedFrameCount > 0,
            let firstVideoPresentationTime,
            let lastVideoPresentationTime
        else {
            return 0
        }
        let elapsed = CMTimeGetSeconds(
            CMTimeSubtract(lastVideoPresentationTime, firstVideoPresentationTime)
        )
        let frameDuration = 1.0 / Double(frameRate)
        return max(frameDuration, (elapsed.isFinite ? elapsed : 0) + frameDuration)
    }

    private func audioDurationSecondsLocked() -> Double {
        guard appendedAudioSampleBufferCount > 0,
            let firstAudioPresentationTime,
            let lastAudioEndTime
        else {
            return 0
        }
        let elapsed = CMTimeGetSeconds(
            CMTimeSubtract(lastAudioEndTime, firstAudioPresentationTime)
        )
        return elapsed.isFinite ? max(0, elapsed) : 0
    }
}
