@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import MupawCore

public enum RecordingArtifactEncoderError: Error, LocalizedError, Sendable {
    case fileMissing
    case invalidVideoTrack
    case invalidAudioTrack
    case invalidCameraMetadata
    case invalidDuration
    case audioVideoDurationMismatch(Double)
    case previewFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing:
            "The completed MP4 file is missing."
        case .invalidVideoTrack:
            "The completed MP4 does not contain one valid video track."
        case .invalidAudioTrack:
            "The completed MP4 does not contain the requested valid AAC audio track."
        case .invalidCameraMetadata:
            "The completed MP4 does not contain valid camera overlay metadata."
        case .invalidDuration:
            "The completed MP4 has an invalid or empty duration."
        case .audioVideoDurationMismatch(let difference):
            "The completed MP4 audio and video durations differ by \(String(format: "%.3f", difference)) seconds."
        case .previewFailed(let message):
            "Mupaw could not create the recording preview: \(message)"
        }
    }
}

enum RecordingArtifactEncoder {
    static func finalize(
        sessionID: String,
        source: CaptureSourceDescriptor,
        request: RecordingRequest,
        microphoneDevice: MicrophoneDeviceDescriptor?,
        cameraDevice: CameraDeviceDescriptor?,
        fileURL: URL,
        expectedResolution: RecordingResolution,
        metrics: RecordingFrameMetrics,
        startedAt: Date,
        completedAt: Date = Date()
    ) async throws -> RecordingArtifact {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RecordingArtifactEncoderError.fileMissing
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite,
            durationSeconds >= MupawConstants.minimumCompletedRecordingDurationSeconds
        else {
            throw RecordingArtifactEncoderError.invalidDuration
        }

        let isPlayable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard isPlayable,
            tracks.count == 1,
            let videoTrack = tracks.first
        else {
            throw RecordingArtifactEncoderError.invalidVideoTrack
        }
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        guard
            formatDescriptions.contains(where: {
                CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
            })
        else {
            throw RecordingArtifactEncoderError.invalidVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let pixelWidth = max(1, Int(abs(transformed.width).rounded()))
        let pixelHeight = max(1, Int(abs(transformed.height).rounded()))
        guard pixelWidth == expectedResolution.pixelWidth,
            pixelHeight == expectedResolution.pixelHeight
        else {
            throw RecordingArtifactEncoderError.invalidVideoTrack
        }

        let videoTimeRange = try await videoTrack.load(.timeRange)
        let videoDurationSeconds = CMTimeGetSeconds(videoTimeRange.duration)
        guard videoDurationSeconds.isFinite, videoDurationSeconds > 0 else {
            throw RecordingArtifactEncoderError.invalidDuration
        }

        let audioInfo: RecordingAudioInfo
        if request.audioSource.isEnabled {
            guard audioTracks.count == 1,
                metrics.audioSampleBufferCount > 0,
                let audioTrack = audioTracks.first
            else {
                throw RecordingArtifactEncoderError.invalidAudioTrack
            }
            let audioDescriptions = try await audioTrack.load(.formatDescriptions)
            guard
                audioDescriptions.contains(where: {
                    CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
                }),
                let audioDescription = audioDescriptions.first,
                let basic = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee
            else {
                throw RecordingArtifactEncoderError.invalidAudioTrack
            }
            let sampleRate = Int(basic.mSampleRate.rounded())
            let channelCount = Int(basic.mChannelsPerFrame)
            switch request.audioSource {
            case .none:
                throw RecordingArtifactEncoderError.invalidAudioTrack
            case .systemAudio, .systemAudioAndMicrophone:
                guard sampleRate == MupawConstants.recordingMixedAudioSampleRate,
                    channelCount == MupawConstants.recordingMixedAudioChannelCount
                else {
                    throw RecordingArtifactEncoderError.invalidAudioTrack
                }
            case .microphone:
                guard sampleRate == MupawConstants.recordingMicrophoneAudioSampleRate,
                    (1...MupawConstants.maximumRecordingMicrophoneChannelCount).contains(channelCount)
                else {
                    throw RecordingArtifactEncoderError.invalidAudioTrack
                }
            }
            let audioTimeRange = try await audioTrack.load(.timeRange)
            let audioDurationSeconds = CMTimeGetSeconds(audioTimeRange.duration)
            guard audioDurationSeconds.isFinite,
                audioDurationSeconds >= MupawConstants.minimumCompletedRecordingDurationSeconds
            else {
                throw RecordingArtifactEncoderError.invalidAudioTrack
            }
            let durationDifference = abs(videoDurationSeconds - audioDurationSeconds)
            guard
                durationDifference
                    <= MupawConstants.maximumRecordingAudioVideoDurationDifferenceSeconds
            else {
                throw RecordingArtifactEncoderError.audioVideoDurationMismatch(durationDifference)
            }
            audioInfo = RecordingAudioInfo(
                requested: true,
                source: request.audioSource,
                state: .completed,
                codec: .aac,
                trackCount: 1,
                sampleRate: sampleRate,
                channelCount: channelCount,
                durationSeconds: audioDurationSeconds,
                sampleBufferCount: metrics.audioSampleBufferCount,
                audioVideoDurationDifferenceSeconds: durationDifference,
                deviceID: microphoneDevice?.id,
                deviceName: microphoneDevice?.name,
                controls: metrics.controls,
                systemAudioInput: request.audioSource.usesSystemAudio
                    ? inputInfo(metrics.systemAudio, device: nil)
                    : nil,
                microphoneInput: request.audioSource.usesMicrophone
                    ? inputInfo(metrics.microphone, device: microphoneDevice)
                    : nil,
                controlEventCount: metrics.controlEvents.count
            )
        } else {
            guard audioTracks.isEmpty, metrics.audioSampleBufferCount == 0 else {
                throw RecordingArtifactEncoderError.invalidAudioTrack
            }
            audioInfo = .disabled
        }

        let cameraInfo: RecordingCameraInfo
        if request.cameraOverlay.enabled {
            guard metrics.camera.requested,
                metrics.camera.frameCount > 0,
                let cameraDevice,
                let lastFrameAt = metrics.camera.lastFrameAt
            else {
                throw RecordingArtifactEncoderError.invalidCameraMetadata
            }
            let configuration = metrics.camera.configuration
            guard configuration.enabled, configuration.isValid else {
                throw RecordingArtifactEncoderError.invalidCameraMetadata
            }
            let overlayRect: CaptureRect
            do {
                overlayRect = try RecordingCameraLayoutPlanner.makeRect(
                    outputPixelWidth: pixelWidth,
                    outputPixelHeight: pixelHeight,
                    configuration: configuration
                )
            } catch {
                throw RecordingArtifactEncoderError.invalidCameraMetadata
            }
            cameraInfo = RecordingCameraInfo(
                requested: true,
                state: .completed,
                deviceID: cameraDevice.id,
                deviceName: cameraDevice.name,
                visible: configuration.visible,
                position: configuration.position,
                size: configuration.size,
                shape: configuration.shape,
                cornerRadius: configuration.cornerRadius,
                margin: configuration.margin,
                overlayRectPixels: overlayRect,
                sourcePixelWidth: metrics.camera.sourcePixelWidth,
                sourcePixelHeight: metrics.camera.sourcePixelHeight,
                frameCount: metrics.camera.frameCount,
                lastFrameAt: lastFrameAt,
                lastSourceTimestampSeconds: metrics.camera.lastSourceTimestampSeconds,
                isStale: false,
                controlEventCount: metrics.camera.controlEvents.count
            )
        } else {
            guard !metrics.camera.requested, metrics.camera.frameCount == 0 else {
                throw RecordingArtifactEncoderError.invalidCameraMetadata
            }
            cameraInfo = .disabled
        }

        let previewImage: CGImage
        do {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(
                width: MupawConstants.previewMaximumDimension,
                height: MupawConstants.previewMaximumDimension
            )
            let requestedTime = CMTime(
                seconds: min(max(0, durationSeconds / 2), max(0, durationSeconds - 0.01)),
                preferredTimescale: 600
            )
            previewImage = try await generator.image(at: requestedTime).image
        } catch {
            throw RecordingArtifactEncoderError.previewFailed(error.localizedDescription)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0 else {
            throw RecordingArtifactEncoderError.fileMissing
        }
        let sha256 = try hashFile(at: fileURL)
        let averageFrameRate = Double(metrics.frameCount) / durationSeconds

        return RecordingArtifact(
            id: UUID().uuidString.lowercased(),
            sessionID: sessionID,
            source: source,
            format: request.format,
            codec: .h264,
            fileURL: fileURL,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            requestedFrameRate: request.frameRate,
            averageFrameRate: averageFrameRate,
            durationSeconds: durationSeconds,
            frameCount: metrics.frameCount,
            audio: audioInfo,
            camera: cameraInfo,
            byteCount: byteCount,
            sha256: sha256,
            createdAt: startedAt,
            completedAt: completedAt,
            preview: try ImageArtifactEncoder.makePreview(image: previewImage)
        )
    }

    private static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func inputInfo(
        _ metrics: RecordingAudioLaneMetrics,
        device: MicrophoneDeviceDescriptor?
    ) -> RecordingAudioInputInfo {
        let summary: RecordingAudioLevelSummary?
        if let averageRMS = metrics.averageRMS,
            let maximumPeak = metrics.maximumPeak,
            metrics.measurementCount > 0
        {
            summary = RecordingAudioLevelSummary(
                averageRMS: averageRMS,
                maximumPeak: maximumPeak,
                measurementCount: metrics.measurementCount
            )
        } else {
            summary = nil
        }
        return RecordingAudioInputInfo(
            requested: metrics.requested,
            state: .completed,
            sampleRate: metrics.sampleRate,
            channelCount: metrics.channelCount,
            durationSeconds: metrics.durationSeconds,
            sampleBufferCount: metrics.sampleBufferCount,
            lastSampleAt: metrics.lastSampleAt,
            lastSourceTimestampSeconds: metrics.lastSourceTimestampSeconds,
            currentLevel: nil,
            levelSummary: summary,
            deviceID: device?.id,
            deviceName: device?.name
        )
    }
}
