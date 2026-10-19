@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import MupawCore

enum RecordingAudioLane: String, Sendable, CaseIterable {
    case systemAudio
    case microphone
}

enum RecordingAudioHealthFailure: Sendable, Equatable {
    case missing(RecordingAudioLane)
    case stalled(RecordingAudioLane)
}

struct RecordingAudioHealthObservation: Sendable, Equatable {
    let requested: Bool
    let sampleBufferCount: Int
    let lastSampleAt: Date?
}

enum RecordingAudioHealthPolicy {
    static func evaluate(
        startedAt: Date,
        now: Date,
        systemAudio: RecordingAudioHealthObservation,
        microphone: RecordingAudioHealthObservation
    ) -> RecordingAudioHealthFailure? {
        for (lane, observation) in [
            (RecordingAudioLane.systemAudio, systemAudio),
            (RecordingAudioLane.microphone, microphone),
        ] where observation.requested {
            if observation.sampleBufferCount == 0,
                now.timeIntervalSince(startedAt)
                    >= MupawConstants.recordingAudioStartupTimeoutSeconds
            {
                return .missing(lane)
            }
            if observation.sampleBufferCount > 0,
                let lastSampleAt = observation.lastSampleAt,
                now.timeIntervalSince(lastSampleAt)
                    >= MupawConstants.recordingAudioSourceStallSeconds
            {
                return .stalled(lane)
            }
        }
        return nil
    }
}

struct RecordingAudioControlEvent: Sendable, Equatable {
    let elapsedSeconds: Double
    let controls: RecordingAudioControls
}

struct RecordingAudioLaneMetrics: Sendable, Equatable {
    let requested: Bool
    let sampleBufferCount: Int
    let durationSeconds: Double
    let sampleRate: Int?
    let channelCount: Int?
    let lastSampleAt: Date?
    let lastSourceTimestampSeconds: Double?
    let currentRMS: Double?
    let currentPeak: Double?
    let levelMeasuredAt: Date?
    let averageRMS: Double?
    let maximumPeak: Double?
    let measurementCount: Int

    static func disabled(requested: Bool = false) -> RecordingAudioLaneMetrics {
        RecordingAudioLaneMetrics(
            requested: requested,
            sampleBufferCount: 0,
            durationSeconds: 0,
            sampleRate: nil,
            channelCount: nil,
            lastSampleAt: nil,
            lastSourceTimestampSeconds: nil,
            currentRMS: nil,
            currentPeak: nil,
            levelMeasuredAt: nil,
            averageRMS: nil,
            maximumPeak: nil,
            measurementCount: 0
        )
    }
}

struct RecordingFrameMetrics: Sendable, Equatable {
    let frameCount: Int
    let durationSeconds: Double
    let audioSampleBufferCount: Int
    let audioDurationSeconds: Double
    let audioSampleRate: Int?
    let audioChannelCount: Int?
    let systemAudio: RecordingAudioLaneMetrics
    let microphone: RecordingAudioLaneMetrics
    let controls: RecordingAudioControls
    let controlEvents: [RecordingAudioControlEvent]
}

struct RecordingAudioLevelMeasurement: Sendable, Equatable {
    let rms: Double
    let peak: Double
}

enum RecordingAudioLevelCalculator {
    static func measure(_ sampleBuffer: CMSampleBuffer) -> RecordingAudioLevelMeasurement? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
            basic.mFormatID == kAudioFormatLinearPCM,
            basic.mBitsPerChannel > 0
        else {
            return nil
        }

        var sizeNeeded = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr || sizeNeeded > 0, sizeNeeded >= MemoryLayout<AudioBufferList>.size
        else {
            return nil
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: max(16, MemoryLayout<AudioBufferList>.alignment)
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let flags = basic.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        guard !isBigEndian else { return nil }

        var sumSquares = 0.0
        var peak = 0.0
        var scalarCount = 0

        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if isFloat, basic.mBitsPerChannel == 32 {
                let count = byteCount / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count {
                    accumulate(Double(samples[index]), sumSquares: &sumSquares, peak: &peak)
                }
                scalarCount += count
            } else if isFloat, basic.mBitsPerChannel == 64 {
                let count = byteCount / MemoryLayout<Double>.size
                let samples = data.bindMemory(to: Double.self, capacity: count)
                for index in 0..<count {
                    accumulate(samples[index], sumSquares: &sumSquares, peak: &peak)
                }
                scalarCount += count
            } else if isSignedInteger, basic.mBitsPerChannel == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    accumulate(
                        Double(samples[index]) / Double(Int16.max),
                        sumSquares: &sumSquares,
                        peak: &peak
                    )
                }
                scalarCount += count
            } else if isSignedInteger, basic.mBitsPerChannel == 32 {
                let count = byteCount / MemoryLayout<Int32>.size
                let samples = data.bindMemory(to: Int32.self, capacity: count)
                for index in 0..<count {
                    accumulate(
                        Double(samples[index]) / Double(Int32.max),
                        sumSquares: &sumSquares,
                        peak: &peak
                    )
                }
                scalarCount += count
            }
        }

        guard scalarCount > 0 else { return nil }
        return RecordingAudioLevelMeasurement(
            rms: sqrt(sumSquares / Double(scalarCount)),
            peak: peak
        )
    }

    private static func accumulate(
        _ value: Double,
        sumSquares: inout Double,
        peak: inout Double
    ) {
        guard value.isFinite else { return }
        let bounded = max(-1, min(1, value))
        sumSquares += bounded * bounded
        peak = max(peak, abs(bounded))
    }
}
