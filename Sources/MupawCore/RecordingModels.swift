import Foundation

public enum RecordingFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case mp4
}

public enum RecordingVideoCodec: String, Codable, Sendable, CaseIterable, Hashable {
    case h264
}

public enum RecordingVideoQuality: String, Codable, Sendable, CaseIterable, Hashable {
    case standard
    case high

    public func estimatedBitRate(
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Int
    ) -> Int {
        let factor: Double =
            switch self {
            case .standard: 0.10
            case .high: 0.18
            }
        let pixelsPerSecond = Double(pixelWidth) * Double(pixelHeight) * Double(frameRate)
        let estimate = Int((pixelsPerSecond * factor).rounded())
        return min(
            MupawConstants.maximumRecordingBitRate,
            max(MupawConstants.minimumRecordingBitRate, estimate)
        )
    }
}

public enum RecordingPhase: String, Codable, Sendable, CaseIterable, Hashable {
    case starting
    case recording
    case stopping
    case completed
    case failed
    case cancelled

    public var isActive: Bool {
        switch self {
        case .starting, .recording, .stopping:
            true
        case .completed, .failed, .cancelled:
            false
        }
    }
}

public struct RecordingRequest: Codable, Sendable, Equatable {
    public let mode: ScreenshotCaptureMode
    public let sourceID: String?
    public let region: CaptureRegion?
    public let format: RecordingFormat
    public let frameRate: Int
    public let quality: RecordingVideoQuality
    public let includeCursor: Bool
    public let excludeMupawUI: Bool
    public let fileName: String?

    public init(
        mode: ScreenshotCaptureMode,
        sourceID: String? = nil,
        region: CaptureRegion? = nil,
        format: RecordingFormat = .mp4,
        frameRate: Int = 30,
        quality: RecordingVideoQuality = .standard,
        includeCursor: Bool = false,
        excludeMupawUI: Bool = true,
        fileName: String? = nil
    ) {
        self.mode = mode
        self.sourceID = sourceID
        self.region = region
        self.format = format
        self.frameRate = frameRate
        self.quality = quality
        self.includeCursor = includeCursor
        self.excludeMupawUI = excludeMupawUI
        self.fileName = fileName
    }
}

public struct RecordingSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public struct RecordingResolution: Codable, Sendable, Equatable, Hashable {
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum RecordingResolutionPlanningError: Error, Sendable, Equatable {
    case invalidSourceSize
    case outputTooLarge
}

public enum RecordingResolutionPlanner {
    public static func makeResolution(
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        maximumDimension: Int = MupawConstants.maximumRecordingDimension,
        maximumPixelCount: Int = MupawConstants.maximumRecordingPixelCount
    ) throws -> RecordingResolution {
        guard sourcePixelWidth > 0,
            sourcePixelHeight > 0,
            maximumDimension >= 2,
            maximumPixelCount >= 4
        else {
            throw RecordingResolutionPlanningError.invalidSourceSize
        }

        let sourcePixels = Double(sourcePixelWidth) * Double(sourcePixelHeight)
        guard sourcePixels.isFinite, sourcePixels > 0 else {
            throw RecordingResolutionPlanningError.invalidSourceSize
        }

        let dimensionScale = min(
            1,
            Double(maximumDimension) / Double(max(sourcePixelWidth, sourcePixelHeight))
        )
        let pixelScale = min(1, sqrt(Double(maximumPixelCount) / sourcePixels))
        let scale = min(dimensionScale, pixelScale)
        guard scale.isFinite, scale > 0 else {
            throw RecordingResolutionPlanningError.outputTooLarge
        }

        func evenFloor(_ value: Double) -> Int {
            let floored = max(2, Int(floor(value)))
            return floored.isMultiple(of: 2) ? floored : floored - 1
        }

        var width = evenFloor(Double(sourcePixelWidth) * scale)
        var height = evenFloor(Double(sourcePixelHeight) * scale)
        width = min(width, maximumDimension - maximumDimension % 2)
        height = min(height, maximumDimension - maximumDimension % 2)

        guard width >= 2,
            height >= 2,
            width <= maximumPixelCount / height
        else {
            throw RecordingResolutionPlanningError.outputTooLarge
        }
        return RecordingResolution(pixelWidth: width, pixelHeight: height)
    }
}

public struct RecordingArtifact: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let source: CaptureSourceDescriptor
    public let format: RecordingFormat
    public let codec: RecordingVideoCodec
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let requestedFrameRate: Int
    public let averageFrameRate: Double
    public let durationSeconds: Double
    public let frameCount: Int
    public let byteCount: Int
    public let sha256: String
    public let createdAt: Date
    public let completedAt: Date
    public let preview: ImagePreview

    public init(
        id: String,
        sessionID: String,
        source: CaptureSourceDescriptor,
        format: RecordingFormat,
        codec: RecordingVideoCodec,
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        requestedFrameRate: Int,
        averageFrameRate: Double,
        durationSeconds: Double,
        frameCount: Int,
        byteCount: Int,
        sha256: String,
        createdAt: Date,
        completedAt: Date,
        preview: ImagePreview
    ) {
        self.id = id
        self.sessionID = sessionID
        self.source = source
        self.format = format
        self.codec = codec
        self.fileURL = fileURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.requestedFrameRate = requestedFrameRate
        self.averageFrameRate = averageFrameRate
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.preview = preview
    }
}

public struct RecordingSessionStatus: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let phase: RecordingPhase
    public let source: CaptureSourceDescriptor
    public let format: RecordingFormat
    public let codec: RecordingVideoCodec
    public let frameRate: Int
    public let quality: RecordingVideoQuality
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let includeCursor: Bool
    public let startedAt: Date
    public let updatedAt: Date
    public let elapsedDurationSeconds: Double
    public let frameCount: Int
    public let artifact: RecordingArtifact?
    public let errorMessage: String?

    public init(
        id: String,
        phase: RecordingPhase,
        source: CaptureSourceDescriptor,
        format: RecordingFormat,
        codec: RecordingVideoCodec,
        frameRate: Int,
        quality: RecordingVideoQuality,
        pixelWidth: Int,
        pixelHeight: Int,
        includeCursor: Bool,
        startedAt: Date,
        updatedAt: Date,
        elapsedDurationSeconds: Double,
        frameCount: Int,
        artifact: RecordingArtifact? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.phase = phase
        self.source = source
        self.format = format
        self.codec = codec
        self.frameRate = frameRate
        self.quality = quality
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.includeCursor = includeCursor
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.elapsedDurationSeconds = elapsedDurationSeconds
        self.frameCount = frameCount
        self.artifact = artifact
        self.errorMessage = errorMessage
    }
}
