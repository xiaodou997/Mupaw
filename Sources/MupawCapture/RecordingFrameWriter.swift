@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MupawCore
@preconcurrency import ScreenCaptureKit

struct RecordingFrameMetrics: Sendable, Equatable {
    let frameCount: Int
    let durationSeconds: Double
}

enum RecordingFrameWriterError: Error, LocalizedError, Sendable {
    case couldNotCreateWriter(String)
    case couldNotAddInput
    case couldNotStartWriting(String)
    case appendFailed(String)
    case noVideoFrames
    case finishFailed(String)
    case alreadyFinishing

    var errorDescription: String? {
        switch self {
        case .couldNotCreateWriter(let message):
            "Could not create the MP4 writer: \(message)"
        case .couldNotAddInput:
            "The MP4 writer could not accept its video input."
        case .couldNotStartWriting(let message):
            "The MP4 writer could not start: \(message)"
        case .appendFailed(let message):
            "The MP4 writer could not append a video frame: \(message)"
        case .noVideoFrames:
            "The recording ended before Mupaw received a video frame."
        case .finishFailed(let message):
            "The MP4 writer could not finish: \(message)"
        case .alreadyFinishing:
            "The MP4 writer is already finishing."
        }
    }
}

final class RecordingFrameWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue: DispatchQueue

    private let outputURL: URL
    private let frameRate: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let stateLock = NSLock()
    private let onFailure: @Sendable (Error) -> Void

    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var lastSampleBuffer: CMSampleBuffer?
    private var wallClockStartedAt: Date?
    private var appendedFrameCount = 0
    private var terminalError: Error?
    private var isFinishing = false
    private var didReportFailure = false

    init(
        outputURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Int,
        quality: RecordingVideoQuality,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        self.outputURL = outputURL
        self.frameRate = frameRate
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
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: compression,
        ]
        self.input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        self.input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecordingFrameWriterError.couldNotAddInput
        }
        writer.add(input)
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
        guard outputType == .screen,
            CMSampleBufferDataIsReady(sampleBuffer),
            CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
            shouldAppend(sampleBuffer)
        else {
            return
        }

        stateLock.lock()
        let finishing = isFinishing
        let existingError = terminalError
        stateLock.unlock()
        guard !finishing, existingError == nil else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else { return }

        stateLock.lock()
        let shouldStartSession = firstPresentationTime == nil
        stateLock.unlock()
        if shouldStartSession {
            writer.startSession(atSourceTime: presentationTime)
            stateLock.lock()
            firstPresentationTime = presentationTime
            stateLock.unlock()
        }
        guard input.isReadyForMoreMediaData else { return }

        if input.append(sampleBuffer) {
            stateLock.lock()
            appendedFrameCount += 1
            lastPresentationTime = presentationTime
            lastSampleBuffer = sampleBuffer
            stateLock.unlock()
        } else {
            reportFailure(
                RecordingFrameWriterError.appendFailed(
                    writer.error?.localizedDescription ?? "Unknown writer error."
                )
            )
        }
    }

    func metricsSnapshot() -> RecordingFrameMetrics {
        stateLock.lock()
        defer { stateLock.unlock() }
        return RecordingFrameMetrics(
            frameCount: appendedFrameCount,
            durationSeconds: durationSecondsLocked()
        )
    }

    func finish() async throws -> RecordingFrameMetrics {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                stateLock.lock()
                if isFinishing {
                    stateLock.unlock()
                    continuation.resume(throwing: RecordingFrameWriterError.alreadyFinishing)
                    return
                }
                isFinishing = true
                let failure = terminalError
                let frameCount = appendedFrameCount
                let firstTime = firstPresentationTime
                let lastTime = lastPresentationTime
                let lastSample = lastSampleBuffer
                let wallStart = wallClockStartedAt
                stateLock.unlock()

                if let failure {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: failure)
                    return
                }
                guard frameCount > 0,
                    let firstTime,
                    let lastTime,
                    let lastSample
                else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: RecordingFrameWriterError.noVideoFrames)
                    return
                }

                let wallDuration = wallStart.map { max(0, Date().timeIntervalSince($0)) } ?? 0
                let terminalTime: CMTime
                do {
                    terminalTime = try appendTerminalFrameIfNeeded(
                        firstTime: firstTime,
                        lastTime: lastTime,
                        lastSample: lastSample,
                        wallDurationSeconds: wallDuration
                    )
                } catch {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: error)
                    return
                }

                input.markAsFinished()
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                writer.endSession(atSourceTime: CMTimeAdd(terminalTime, frameDuration))
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
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                continuation.resume()
            }
        }
    }

    func cancelAndDeleteImmediately() {
        sampleQueue.async { [self] in
            stateLock.lock()
            isFinishing = true
            stateLock.unlock()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func appendTerminalFrameIfNeeded(
        firstTime: CMTime,
        lastTime: CMTime,
        lastSample: CMSampleBuffer,
        wallDurationSeconds: Double
    ) throws -> CMTime {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let desiredDuration = max(CMTimeGetSeconds(frameDuration), wallDurationSeconds)
        let terminalOffset = CMTime(
            seconds: max(0, desiredDuration - CMTimeGetSeconds(frameDuration)),
            preferredTimescale: 60_000
        )
        let desiredTime = CMTimeAdd(firstTime, terminalOffset)
        guard CMTimeCompare(desiredTime, lastTime) > 0 else { return lastTime }

        let deadline = Date().addingTimeInterval(0.5)
        while !input.isReadyForMoreMediaData, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard input.isReadyForMoreMediaData else {
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
            sampleBuffer: lastSample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard result == noErr, let retimed else {
            throw RecordingFrameWriterError.appendFailed(
                "Mupaw could not retime the final held frame (OSStatus \(result))."
            )
        }
        guard input.append(retimed) else {
            throw RecordingFrameWriterError.appendFailed(
                writer.error?.localizedDescription ?? "The final held frame was rejected."
            )
        }

        stateLock.lock()
        appendedFrameCount += 1
        lastPresentationTime = desiredTime
        lastSampleBuffer = retimed
        stateLock.unlock()
        return desiredTime
    }

    private func shouldAppend(_ sampleBuffer: CMSampleBuffer) -> Bool {
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

    private func durationSecondsLocked() -> Double {
        guard appendedFrameCount > 0,
            let firstPresentationTime,
            let lastPresentationTime
        else {
            return 0
        }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(lastPresentationTime, firstPresentationTime))
        let frameDuration = 1.0 / Double(frameRate)
        return max(frameDuration, (elapsed.isFinite ? elapsed : 0) + frameDuration)
    }
}
