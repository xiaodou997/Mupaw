@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import MupawCore
@preconcurrency import ScreenCaptureKit

enum RecordingFrameWriterError: Error, LocalizedError, Sendable {
    case couldNotCreateWriter(String)
    case couldNotAddVideoInput
    case couldNotAddAudioInput(RecordingAudioLane)
    case couldNotStartWriting(String)
    case appendFailed(String)
    case audioAppendFailed(RecordingAudioLane, String)
    case invalidAudioFormat(RecordingAudioLane)
    case noVideoFrames
    case noAudioSamples(RecordingAudioLane)
    case audioSourceStalled(RecordingAudioLane)
    case pendingSamplesExceeded(String)
    case finishFailed(String)
    case alreadyFinishing

    var errorDescription: String? {
        switch self {
        case .couldNotCreateWriter(let message):
            "Could not create the recording writer: \(message)"
        case .couldNotAddVideoInput:
            "The recording writer could not accept its video input."
        case .couldNotAddAudioInput(let lane):
            "The recording writer could not accept the \(lane.rawValue) audio input."
        case .couldNotStartWriting(let message):
            "The recording writer could not start: \(message)"
        case .appendFailed(let message):
            "The recording writer could not append a video frame: \(message)"
        case .audioAppendFailed(let lane, let message):
            "The recording writer could not append \(lane.rawValue) audio: \(message)"
        case .invalidAudioFormat(let lane):
            "ScreenCaptureKit returned \(lane.rawValue) audio in an unexpected format."
        case .noVideoFrames:
            "The recording ended before Mupaw received a video frame."
        case .noAudioSamples(let lane):
            "The recording requested \(lane.rawValue) audio, but no valid samples arrived."
        case .audioSourceStalled(let lane):
            "The \(lane.rawValue) audio source stopped producing samples during recording."
        case .pendingSamplesExceeded(let track):
            "The \(track) track did not become ready before its pending-sample limit was reached."
        case .finishFailed(let message):
            "The recording writer could not finish: \(message)"
        case .alreadyFinishing:
            "The recording writer is already finishing."
        }
    }
}

final class RecordingFrameWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    final class SampleBufferBox: @unchecked Sendable {
        let value: CMSampleBuffer

        init(_ value: CMSampleBuffer) {
            self.value = value
        }
    }

    private enum PendingSample {
        case video(CMSampleBuffer)
        case systemAudio(CMSampleBuffer)
        case microphone(CMSampleBuffer)

        var presentationTime: CMTime {
            switch self {
            case .video(let sample), .systemAudio(let sample), .microphone(let sample):
                CMSampleBufferGetPresentationTimeStamp(sample)
            }
        }
    }

    private struct AudioLaneAccumulator {
        var receivedSampleBufferCount = 0
        var appendedSampleBufferCount = 0
        var firstPresentationTime: CMTime?
        var lastEndTime: CMTime?
        var sampleRate: Int?
        var channelCount: Int?
        var lastSampleAt: Date?
        var lastSourceTimestampSeconds: Double?
        var currentRMS: Double?
        var currentPeak: Double?
        var levelMeasuredAt: Date?
        var rmsTotal = 0.0
        var maximumPeak = 0.0
        var measurementCount = 0
    }

    let videoOutputQueue: DispatchQueue
    let audioOutputQueue: DispatchQueue

    private let sampleQueue: DispatchQueue
    private let outputURL: URL
    private let frameRate: Int
    private let audioSource: RecordingAudioSource
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private let stateLock = NSLock()
    private let onFailure: @Sendable (Error) -> Void

    private var sessionStartTime: CMTime?
    private var firstVideoPresentationTime: CMTime?
    private var lastVideoPresentationTime: CMTime?
    private var lastVideoSampleBuffer: CMSampleBuffer?
    private var pendingVideoSamples: [CMSampleBuffer] = []
    private var pendingSystemAudioSamples: [CMSampleBuffer] = []
    private var pendingMicrophoneSamples: [CMSampleBuffer] = []
    private var systemAudioAccumulator = AudioLaneAccumulator()
    private var microphoneAccumulator = AudioLaneAccumulator()
    private var wallClockStartedAt: Date?
    private var appendedFrameCount = 0
    private var terminalError: Error?
    private var isFinishing = false
    private var didReportFailure = false
    private var didStartWriting = false
    private var currentControls: RecordingAudioControls
    private var controlEvents: [RecordingAudioControlEvent]

    init(
        outputURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Int,
        quality: RecordingVideoQuality,
        audioSource: RecordingAudioSource,
        audioControls: RecordingAudioControls,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.frameRate = frameRate
        self.audioSource = audioSource
        self.currentControls = audioControls
        self.controlEvents = [
            RecordingAudioControlEvent(elapsedSeconds: 0, controls: audioControls)
        ]

        let queueIdentifier = UUID().uuidString
        self.videoOutputQueue = DispatchQueue(
            label: "com.xiaodou.mupaw.recording.output.video.\(queueIdentifier)",
            qos: .userInitiated
        )
        self.audioOutputQueue = DispatchQueue(
            label: "com.xiaodou.mupaw.recording.output.audio.\(queueIdentifier)",
            qos: .userInitiated
        )
        self.sampleQueue = DispatchQueue(
            label: "com.xiaodou.mupaw.recording.writer.\(queueIdentifier)",
            qos: .userInitiated
        )
        self.onFailure = onFailure

        do {
            self.writer = try AVAssetWriter(
                outputURL: outputURL,
                fileType: audioSource.isEnabled ? .mov : .mp4
            )
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

        if audioSource.usesSystemAudio {
            self.systemAudioInput = try Self.makeAudioInput(
                writer: writer,
                lane: .systemAudio,
                channelCount: MupawConstants.recordingSystemAudioChannelCount,
                bitRate: MupawConstants.recordingSystemAudioBitRate,
                sourceFormatHint: nil
            )
        }
        writer.shouldOptimizeForNetworkUse = true
    }

    func prepare() {
        stateLock.lock()
        wallClockStartedAt = Date()
        stateLock.unlock()
    }

    func updateAudioControls(_ controls: RecordingAudioControls, now: Date = Date()) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard controls != currentControls else { return }
        currentControls = controls
        let elapsed = wallClockStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        if controlEvents.count >= MupawConstants.maximumRecordingAudioControlEvents {
            controlEvents.removeFirst()
        }
        controlEvents.append(
            RecordingAudioControlEvent(elapsedSeconds: elapsed, controls: controls)
        )
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let box = SampleBufferBox(sampleBuffer)
        sampleQueue.async { [self, box] in
            processSampleBuffer(box.value, outputType: outputType)
        }
    }

    func metricsSnapshot(now: Date = Date()) -> RecordingFrameMetrics {
        stateLock.lock()
        defer { stateLock.unlock() }

        let system = laneMetricsLocked(
            accumulator: systemAudioAccumulator,
            requested: audioSource.usesSystemAudio
        )
        let microphone = laneMetricsLocked(
            accumulator: microphoneAccumulator,
            requested: audioSource.usesMicrophone
        )
        let aggregateCount = system.sampleBufferCount + microphone.sampleBufferCount
        let aggregateDuration = max(system.durationSeconds, microphone.durationSeconds)
        let outputChannels: Int? =
            if audioSource.isMixed || audioSource == .systemAudio {
                MupawConstants.recordingMixedAudioChannelCount
            } else if audioSource == .microphone {
                microphone.channelCount
            } else {
                nil
            }
        return RecordingFrameMetrics(
            frameCount: appendedFrameCount,
            durationSeconds: videoDurationSecondsLocked(),
            audioSampleBufferCount: aggregateCount,
            audioDurationSeconds: aggregateDuration,
            audioSampleRate: audioSource.isEnabled
                ? MupawConstants.recordingMixedAudioSampleRate
                : nil,
            audioChannelCount: outputChannels,
            systemAudio: system,
            microphone: microphone,
            controls: currentControls,
            controlEvents: controlEvents
        )
    }

    func audioHealthError(now: Date = Date()) -> RecordingFrameWriterError? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isFinishing, terminalError == nil, let wallClockStartedAt else { return nil }
        let failure = RecordingAudioHealthPolicy.evaluate(
            startedAt: wallClockStartedAt,
            now: now,
            systemAudio: RecordingAudioHealthObservation(
                requested: audioSource.usesSystemAudio,
                sampleBufferCount: systemAudioAccumulator.receivedSampleBufferCount,
                lastSampleAt: systemAudioAccumulator.lastSampleAt
            ),
            microphone: RecordingAudioHealthObservation(
                requested: audioSource.usesMicrophone,
                sampleBufferCount: microphoneAccumulator.receivedSampleBufferCount,
                lastSampleAt: microphoneAccumulator.lastSampleAt
            )
        )
        switch failure {
        case .missing(let lane):
            return .noAudioSamples(lane)
        case .stalled(let lane):
            return .audioSourceStalled(lane)
        case nil:
            return nil
        }
    }

    func finish() async throws -> RecordingFrameMetrics {
        drainOutputQueues()
        return try await withCheckedThrowingContinuation { continuation in
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
                let startTime = sessionStartTime
                let lastVideoTime = lastVideoPresentationTime
                let lastVideoSample = lastVideoSampleBuffer
                let wallStart = wallClockStartedAt
                let systemAppended = systemAudioAccumulator.appendedSampleBufferCount
                let microphoneAppended = microphoneAccumulator.appendedSampleBufferCount
                let lastSystemEnd = systemAudioAccumulator.lastEndTime
                let lastMicrophoneEnd = microphoneAccumulator.lastEndTime
                stateLock.unlock()

                if let failure {
                    cancelWriterAndDelete()
                    continuation.resume(throwing: failure)
                    return
                }
                if audioSource.usesSystemAudio, systemAppended <= 0 {
                    cancelWriterAndDelete()
                    continuation.resume(
                        throwing: RecordingFrameWriterError.noAudioSamples(.systemAudio)
                    )
                    return
                }
                if audioSource.usesMicrophone, microphoneAppended <= 0 {
                    cancelWriterAndDelete()
                    continuation.resume(
                        throwing: RecordingFrameWriterError.noAudioSamples(.microphone)
                    )
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
                systemAudioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                let videoEndTime = CMTimeAdd(terminalVideoTime, frameDuration)
                let endTime =
                    [videoEndTime, lastSystemEnd, lastMicrophoneEnd]
                    .compactMap { $0 }
                    .max(by: { CMTimeCompare($0, $1) < 0 }) ?? videoEndTime
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
        drainOutputQueues()
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
        drainOutputQueues()
        sampleQueue.async { [self] in
            stateLock.lock()
            isFinishing = true
            stateLock.unlock()
            cancelWriterAndDelete()
        }
    }

    private func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
                shouldAppendVideo(sampleBuffer)
            else {
                return
            }
            receiveVideo(sampleBuffer)
        case .audio:
            guard audioSource.usesSystemAudio else { return }
            receiveAudio(sampleBuffer, lane: .systemAudio)
        case .microphone:
            guard audioSource.usesMicrophone else { return }
            receiveAudio(sampleBuffer, lane: .microphone)
        @unknown default:
            return
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

    private func receiveAudio(_ sampleBuffer: CMSampleBuffer, lane: RecordingAudioLane) {
        guard sampleIsAcceptable(sampleBuffer),
            let format = validatedAudioFormat(sampleBuffer, lane: lane)
        else {
            return
        }
        if lane == .microphone, !ensureMicrophoneAudioInput(sampleBuffer, channelCount: format.channels) {
            return
        }

        let now = Date()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let endTime = audioEndTime(for: sampleBuffer)
        let level = RecordingAudioLevelCalculator.measure(sampleBuffer)

        stateLock.lock()
        updateLaneAccumulatorLocked(
            lane: lane,
            presentationTime: presentationTime,
            endTime: endTime,
            sampleRate: format.sampleRate,
            channelCount: format.channels,
            measuredAt: now,
            level: level
        )
        let hasStarted = sessionStartTime != nil
        if !hasStarted {
            let pendingCount =
                lane == .systemAudio
                ? pendingSystemAudioSamples.count
                : pendingMicrophoneSamples.count
            if pendingCount >= MupawConstants.maximumPendingRecordingSamplesPerTrack {
                stateLock.unlock()
                reportFailure(
                    RecordingFrameWriterError.pendingSamplesExceeded(lane.rawValue)
                )
                return
            }
            if lane == .systemAudio {
                pendingSystemAudioSamples.append(sampleBuffer)
            } else {
                pendingMicrophoneSamples.append(sampleBuffer)
            }
        }
        stateLock.unlock()

        if hasStarted {
            appendAudio(sampleBuffer, lane: lane, requireReadiness: false)
        } else {
            startSessionAndFlushPendingIfReady()
        }
    }

    private func startSessionAndFlushPendingIfReady() {
        stateLock.lock()
        guard sessionStartTime == nil,
            !pendingVideoSamples.isEmpty,
            !audioSource.usesSystemAudio || !pendingSystemAudioSamples.isEmpty,
            !audioSource.usesMicrophone || !pendingMicrophoneSamples.isEmpty,
            terminalError == nil,
            !isFinishing
        else {
            stateLock.unlock()
            return
        }

        let pending: [PendingSample] =
            pendingVideoSamples.map(PendingSample.video)
            + pendingSystemAudioSamples.map(PendingSample.systemAudio)
            + pendingMicrophoneSamples.map(PendingSample.microphone)
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
        pendingSystemAudioSamples.removeAll(keepingCapacity: false)
        pendingMicrophoneSamples.removeAll(keepingCapacity: false)
        stateLock.unlock()

        guard writer.startWriting() else {
            reportFailure(
                RecordingFrameWriterError.couldNotStartWriting(
                    writer.error?.localizedDescription ?? "Unknown writer error."
                )
            )
            return
        }
        stateLock.lock()
        didStartWriting = true
        stateLock.unlock()
        writer.startSession(atSourceTime: startTime)
        for sample in pending.sorted(by: {
            CMTimeCompare($0.presentationTime, $1.presentationTime) < 0
        }) {
            switch sample {
            case .video(let buffer):
                appendVideo(buffer, requireReadiness: true)
            case .systemAudio(let buffer):
                appendAudio(buffer, lane: .systemAudio, requireReadiness: true)
            case .microphone(let buffer):
                appendAudio(buffer, lane: .microphone, requireReadiness: true)
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

    private func appendAudio(
        _ sampleBuffer: CMSampleBuffer,
        lane: RecordingAudioLane,
        requireReadiness: Bool
    ) {
        let input = lane == .systemAudio ? systemAudioInput : microphoneInput
        guard let input else {
            reportFailure(RecordingFrameWriterError.couldNotAddAudioInput(lane))
            return
        }
        guard waitUntilReady(input, required: requireReadiness) else { return }
        guard input.append(sampleBuffer) else {
            reportFailure(
                RecordingFrameWriterError.audioAppendFailed(
                    lane,
                    writer.error?.localizedDescription ?? "Unknown writer error."
                )
            )
            return
        }

        stateLock.lock()
        if lane == .systemAudio {
            systemAudioAccumulator.appendedSampleBufferCount += 1
        } else {
            microphoneAccumulator.appendedSampleBufferCount += 1
        }
        stateLock.unlock()
    }

    private func validatedAudioFormat(
        _ sampleBuffer: CMSampleBuffer,
        lane: RecordingAudioLane
    ) -> (sampleRate: Int, channels: Int)? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else {
            reportFailure(RecordingFrameWriterError.invalidAudioFormat(lane))
            return nil
        }
        let sampleRate = Int(basic.mSampleRate.rounded())
        let channels = Int(basic.mChannelsPerFrame)
        guard sampleRate > 0, channels > 0 else {
            reportFailure(RecordingFrameWriterError.invalidAudioFormat(lane))
            return nil
        }
        if lane == .systemAudio,
            sampleRate != MupawConstants.recordingSystemAudioSampleRate
                || channels != MupawConstants.recordingSystemAudioChannelCount
        {
            reportFailure(RecordingFrameWriterError.invalidAudioFormat(lane))
            return nil
        }
        return (sampleRate, channels)
    }

    private func ensureMicrophoneAudioInput(
        _ sampleBuffer: CMSampleBuffer,
        channelCount: Int
    ) -> Bool {
        stateLock.lock()
        let existingInput = microphoneInput
        let writingStarted = didStartWriting
        stateLock.unlock()
        if existingInput != nil { return true }
        guard audioSource.usesMicrophone,
            !writingStarted,
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            reportFailure(RecordingFrameWriterError.invalidAudioFormat(.microphone))
            return false
        }

        let outputChannels = min(
            MupawConstants.maximumRecordingMicrophoneChannelCount,
            max(1, channelCount)
        )
        do {
            let input = try Self.makeAudioInput(
                writer: writer,
                lane: .microphone,
                channelCount: outputChannels,
                bitRate: outputChannels == 1
                    ? MupawConstants.recordingMicrophoneAudioBitRate
                    : MupawConstants.recordingSystemAudioBitRate,
                sourceFormatHint: formatDescription
            )
            stateLock.lock()
            microphoneInput = input
            stateLock.unlock()
            return true
        } catch {
            reportFailure(error)
            return false
        }
    }

    private static func makeAudioInput(
        writer: AVAssetWriter,
        lane: RecordingAudioLane,
        channelCount: Int,
        bitRate: Int,
        sourceFormatHint: CMFormatDescription?
    ) throws -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: MupawConstants.recordingMixedAudioSampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: sourceFormatHint
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecordingFrameWriterError.couldNotAddAudioInput(lane)
        }
        writer.add(input)
        return input
    }

    private func updateLaneAccumulatorLocked(
        lane: RecordingAudioLane,
        presentationTime: CMTime,
        endTime: CMTime,
        sampleRate: Int,
        channelCount: Int,
        measuredAt: Date,
        level: RecordingAudioLevelMeasurement?
    ) {
        if lane == .systemAudio {
            updateAccumulator(
                &systemAudioAccumulator,
                presentationTime: presentationTime,
                endTime: endTime,
                sampleRate: sampleRate,
                channelCount: channelCount,
                measuredAt: measuredAt,
                level: level
            )
        } else {
            updateAccumulator(
                &microphoneAccumulator,
                presentationTime: presentationTime,
                endTime: endTime,
                sampleRate: sampleRate,
                channelCount: channelCount,
                measuredAt: measuredAt,
                level: level
            )
        }
    }

    private func updateAccumulator(
        _ accumulator: inout AudioLaneAccumulator,
        presentationTime: CMTime,
        endTime: CMTime,
        sampleRate: Int,
        channelCount: Int,
        measuredAt: Date,
        level: RecordingAudioLevelMeasurement?
    ) {
        accumulator.receivedSampleBufferCount += 1
        if accumulator.firstPresentationTime == nil {
            accumulator.firstPresentationTime = presentationTime
        }
        accumulator.lastEndTime = endTime
        accumulator.sampleRate = sampleRate
        accumulator.channelCount = channelCount
        accumulator.lastSampleAt = measuredAt
        let timestamp = CMTimeGetSeconds(presentationTime)
        accumulator.lastSourceTimestampSeconds = timestamp.isFinite ? timestamp : nil
        if let level {
            accumulator.currentRMS = level.rms
            accumulator.currentPeak = level.peak
            accumulator.levelMeasuredAt = measuredAt
            accumulator.rmsTotal += level.rms
            accumulator.maximumPeak = max(accumulator.maximumPeak, level.peak)
            accumulator.measurementCount += 1
        }
    }

    private func laneMetricsLocked(
        accumulator: AudioLaneAccumulator,
        requested: Bool
    ) -> RecordingAudioLaneMetrics {
        let duration: Double
        if let first = accumulator.firstPresentationTime,
            let last = accumulator.lastEndTime
        {
            let value = CMTimeGetSeconds(CMTimeSubtract(last, first))
            duration = value.isFinite ? max(0, value) : 0
        } else {
            duration = 0
        }
        return RecordingAudioLaneMetrics(
            requested: requested,
            sampleBufferCount: accumulator.receivedSampleBufferCount,
            durationSeconds: duration,
            sampleRate: accumulator.sampleRate,
            channelCount: accumulator.channelCount,
            lastSampleAt: accumulator.lastSampleAt,
            lastSourceTimestampSeconds: accumulator.lastSourceTimestampSeconds,
            currentRMS: accumulator.currentRMS,
            currentPeak: accumulator.currentPeak,
            levelMeasuredAt: accumulator.levelMeasuredAt,
            averageRMS: accumulator.measurementCount > 0
                ? accumulator.rmsTotal / Double(accumulator.measurementCount)
                : nil,
            maximumPeak: accumulator.measurementCount > 0
                ? accumulator.maximumPeak
                : nil,
            measurementCount: accumulator.measurementCount
        )
    }

    private func laneAccumulator(_ lane: RecordingAudioLane) -> AudioLaneAccumulator {
        lane == .systemAudio ? systemAudioAccumulator : microphoneAccumulator
    }

    private func laneIsRequested(_ lane: RecordingAudioLane) -> Bool {
        lane == .systemAudio ? audioSource.usesSystemAudio : audioSource.usesMicrophone
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
            CMTime(
                seconds: max(CMTimeGetSeconds(frameDuration), wallDurationSeconds),
                preferredTimescale: 60_000
            )
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

    private func audioEndTime(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 {
            return CMTimeAdd(presentationTime, duration)
        }
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        let sourceRate =
            formatDescription.flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate
            } ?? Double(MupawConstants.recordingMixedAudioSampleRate)
        let durationSeconds = Double(sampleCount) / max(1, sourceRate)
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

    private func drainOutputQueues() {
        videoOutputQueue.sync {}
        audioOutputQueue.sync {}
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
}
