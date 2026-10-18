@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import MupawCore

public enum RecordingArtifactEncoderError: Error, LocalizedError, Sendable {
    case fileMissing
    case invalidVideoTrack
    case invalidDuration
    case previewFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing:
            "The completed MP4 file is missing."
        case .invalidVideoTrack:
            "The completed MP4 does not contain one valid video track."
        case .invalidDuration:
            "The completed MP4 has an invalid or empty duration."
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
            audioTracks.isEmpty,
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
}
