import Foundation

public enum RecordingFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case mp4
}

public enum RecordingVideoCodec: String, Codable, Sendable, CaseIterable, Hashable {
    case h264
}

public enum RecordingAudioCodec: String, Codable, Sendable, CaseIterable, Hashable {
    case aac
}

public enum RecordingAudioSource: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case systemAudio = "system_audio"
    case microphone
    case systemAudioAndMicrophone = "system_audio_and_microphone"

    public var isEnabled: Bool { self != .none }

    public var usesSystemAudio: Bool {
        switch self {
        case .systemAudio, .systemAudioAndMicrophone:
            true
        case .none, .microphone:
            false
        }
    }

    public var usesMicrophone: Bool {
        switch self {
        case .microphone, .systemAudioAndMicrophone:
            true
        case .none, .systemAudio:
            false
        }
    }

    public var isMixed: Bool { self == .systemAudioAndMicrophone }
}

public enum RecordingCameraOverlayPosition: String, Codable, Sendable, CaseIterable, Hashable {
    case topLeft = "top_left"
    case topRight = "top_right"
    case bottomLeft = "bottom_left"
    case bottomRight = "bottom_right"
}

public enum RecordingCameraOverlaySize: String, Codable, Sendable, CaseIterable, Hashable {
    case small
    case medium
    case large

    fileprivate var widthFraction: Double {
        switch self {
        case .small:
            0.18
        case .medium:
            0.24
        case .large:
            0.32
        }
    }
}

public enum RecordingCameraOverlayShape: String, Codable, Sendable, CaseIterable, Hashable {
    case circle
    case roundedRectangle = "rounded_rectangle"
}

public struct RecordingCameraOverlayConfiguration: Codable, Sendable, Equatable, Hashable {
    public let enabled: Bool
    public let deviceID: String?
    public let visible: Bool
    public let position: RecordingCameraOverlayPosition
    public let size: RecordingCameraOverlaySize
    public let shape: RecordingCameraOverlayShape
    public let cornerRadius: Double
    public let margin: Double

    public init(
        enabled: Bool = false,
        deviceID: String? = nil,
        visible: Bool? = nil,
        position: RecordingCameraOverlayPosition = .bottomRight,
        size: RecordingCameraOverlaySize = .medium,
        shape: RecordingCameraOverlayShape = .circle,
        cornerRadius: Double = 0.12,
        margin: Double = 0.025
    ) {
        self.enabled = enabled
        self.deviceID = deviceID
        self.visible = visible ?? enabled
        self.position = position
        self.size = size
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.margin = margin
    }

    public var isValid: Bool {
        let cornerRange =
            MupawConstants.minimumRecordingCameraCornerRadius...MupawConstants.maximumRecordingCameraCornerRadius
        let marginRange =
            MupawConstants.minimumRecordingCameraMargin...MupawConstants.maximumRecordingCameraMargin
        return cornerRadius.isFinite
            && margin.isFinite
            && cornerRange.contains(cornerRadius)
            && marginRange.contains(margin)
            && (enabled || (deviceID == nil && !visible))
    }

    public func applying(
        _ update: RecordingCameraOverlayUpdateRequest
    ) -> RecordingCameraOverlayConfiguration {
        RecordingCameraOverlayConfiguration(
            enabled: enabled,
            deviceID: deviceID,
            visible: update.visible ?? visible,
            position: update.position ?? position,
            size: update.size ?? size,
            shape: update.shape ?? shape,
            cornerRadius: update.cornerRadius ?? cornerRadius,
            margin: update.margin ?? margin
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case deviceID
        case visible
        case position
        case size
        case shape
        case cornerRadius
        case margin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.init(
            enabled: enabled,
            deviceID: try container.decodeIfPresent(String.self, forKey: .deviceID),
            visible: try container.decodeIfPresent(Bool.self, forKey: .visible),
            position: try container.decodeIfPresent(
                RecordingCameraOverlayPosition.self,
                forKey: .position
            ) ?? .bottomRight,
            size: try container.decodeIfPresent(RecordingCameraOverlaySize.self, forKey: .size)
                ?? .medium,
            shape: try container.decodeIfPresent(RecordingCameraOverlayShape.self, forKey: .shape)
                ?? .circle,
            cornerRadius: try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0.12,
            margin: try container.decodeIfPresent(Double.self, forKey: .margin) ?? 0.025
        )
    }

    public static let disabled = RecordingCameraOverlayConfiguration()
}

public enum RecordingCameraState: String, Codable, Sendable, CaseIterable, Hashable {
    case disabled
    case waiting
    case capturing
    case completed
    case failed
    case cancelled
}

public enum CameraDevicePosition: String, Codable, Sendable, CaseIterable, Hashable {
    case front
    case back
    case unspecified
}

public struct CameraDeviceDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let manufacturer: String?
    public let position: CameraDevicePosition
    public let isDefault: Bool
    public let isConnected: Bool

    public init(
        id: String,
        name: String,
        manufacturer: String? = nil,
        position: CameraDevicePosition,
        isDefault: Bool,
        isConnected: Bool
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.position = position
        self.isDefault = isDefault
        self.isConnected = isConnected
    }
}

public struct CameraDeviceListResult: Codable, Sendable, Equatable {
    public let refreshedAt: Date
    public let permission: PermissionStatus
    public let defaultDeviceID: String?
    public let devices: [CameraDeviceDescriptor]

    public init(
        refreshedAt: Date = Date(),
        permission: PermissionStatus,
        defaultDeviceID: String?,
        devices: [CameraDeviceDescriptor]
    ) {
        self.refreshedAt = refreshedAt
        self.permission = permission
        self.defaultDeviceID = defaultDeviceID
        self.devices = devices
    }
}

public struct RecordingCameraInfo: Codable, Sendable, Equatable {
    public let requested: Bool
    public let state: RecordingCameraState
    public let deviceID: String?
    public let deviceName: String?
    public let visible: Bool?
    public let position: RecordingCameraOverlayPosition?
    public let size: RecordingCameraOverlaySize?
    public let shape: RecordingCameraOverlayShape?
    public let cornerRadius: Double?
    public let margin: Double?
    public let overlayRectPixels: CaptureRect?
    public let sourcePixelWidth: Int?
    public let sourcePixelHeight: Int?
    public let frameCount: Int
    public let lastFrameAt: Date?
    public let lastSourceTimestampSeconds: Double?
    public let isStale: Bool
    public let controlEventCount: Int

    public init(
        requested: Bool,
        state: RecordingCameraState,
        deviceID: String? = nil,
        deviceName: String? = nil,
        visible: Bool? = nil,
        position: RecordingCameraOverlayPosition? = nil,
        size: RecordingCameraOverlaySize? = nil,
        shape: RecordingCameraOverlayShape? = nil,
        cornerRadius: Double? = nil,
        margin: Double? = nil,
        overlayRectPixels: CaptureRect? = nil,
        sourcePixelWidth: Int? = nil,
        sourcePixelHeight: Int? = nil,
        frameCount: Int = 0,
        lastFrameAt: Date? = nil,
        lastSourceTimestampSeconds: Double? = nil,
        isStale: Bool = false,
        controlEventCount: Int = 0
    ) {
        self.requested = requested
        self.state = state
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.visible = visible
        self.position = position
        self.size = size
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.margin = margin
        self.overlayRectPixels = overlayRectPixels
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.frameCount = frameCount
        self.lastFrameAt = lastFrameAt
        self.lastSourceTimestampSeconds = lastSourceTimestampSeconds
        self.isStale = isStale
        self.controlEventCount = controlEventCount
    }

    private enum CodingKeys: String, CodingKey {
        case requested
        case state
        case deviceID
        case deviceName
        case visible
        case position
        case size
        case shape
        case cornerRadius
        case margin
        case overlayRectPixels
        case sourcePixelWidth
        case sourcePixelHeight
        case frameCount
        case lastFrameAt
        case lastSourceTimestampSeconds
        case isStale
        case controlEventCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requested = try container.decodeIfPresent(Bool.self, forKey: .requested) ?? false
        state = try container.decode(RecordingCameraState.self, forKey: .state)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible)
        position = try container.decodeIfPresent(RecordingCameraOverlayPosition.self, forKey: .position)
        size = try container.decodeIfPresent(RecordingCameraOverlaySize.self, forKey: .size)
        shape = try container.decodeIfPresent(RecordingCameraOverlayShape.self, forKey: .shape)
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius)
        margin = try container.decodeIfPresent(Double.self, forKey: .margin)
        overlayRectPixels = try container.decodeIfPresent(CaptureRect.self, forKey: .overlayRectPixels)
        sourcePixelWidth = try container.decodeIfPresent(Int.self, forKey: .sourcePixelWidth)
        sourcePixelHeight = try container.decodeIfPresent(Int.self, forKey: .sourcePixelHeight)
        frameCount = try container.decodeIfPresent(Int.self, forKey: .frameCount) ?? 0
        lastFrameAt = try container.decodeIfPresent(Date.self, forKey: .lastFrameAt)
        lastSourceTimestampSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .lastSourceTimestampSeconds
        )
        isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
        controlEventCount = try container.decodeIfPresent(Int.self, forKey: .controlEventCount) ?? 0
    }

    public static let disabled = RecordingCameraInfo(
        requested: false,
        state: .disabled
    )
}

public enum RecordingCameraLayoutPlanningError: Error, Sendable, Equatable {
    case invalidOutputSize
    case invalidConfiguration
}

public enum RecordingCameraLayoutPlanner {
    public static func makeRect(
        outputPixelWidth: Int,
        outputPixelHeight: Int,
        configuration: RecordingCameraOverlayConfiguration
    ) throws -> CaptureRect {
        guard outputPixelWidth > 0, outputPixelHeight > 0 else {
            throw RecordingCameraLayoutPlanningError.invalidOutputSize
        }
        guard configuration.isValid else {
            throw RecordingCameraLayoutPlanningError.invalidConfiguration
        }

        let outputWidth = Double(outputPixelWidth)
        let outputHeight = Double(outputPixelHeight)
        let shortestSide = min(outputWidth, outputHeight)
        let margin = floor(shortestSide * configuration.margin)
        let maximumWidth = max(2, outputWidth - margin * 2)
        let requestedWidth = max(96, floor(shortestSide * configuration.size.widthFraction))
        let width = min(maximumWidth, requestedWidth)
        let requestedHeight =
            configuration.shape == .circle
            ? width
            : floor(width * 9 / 16)
        let height = min(max(54, requestedHeight), max(2, outputHeight - margin * 2))

        let x: Double
        switch configuration.position {
        case .topLeft, .bottomLeft:
            x = margin
        case .topRight, .bottomRight:
            x = outputWidth - margin - width
        }

        let y: Double
        switch configuration.position {
        case .topLeft, .topRight:
            y = margin
        case .bottomLeft, .bottomRight:
            y = outputHeight - margin - height
        }

        let rect = CaptureRect(x: x, y: y, width: width, height: height)
        guard rect.isFinite, rect.hasPositiveArea,
            rect.minX >= 0, rect.minY >= 0,
            rect.maxX <= outputWidth, rect.maxY <= outputHeight
        else {
            throw RecordingCameraLayoutPlanningError.invalidOutputSize
        }
        return rect
    }
}

public struct RecordingAudioControls: Codable, Sendable, Equatable, Hashable {
    public let systemAudioGain: Double
    public let microphoneGain: Double
    public let systemAudioMuted: Bool
    public let microphoneMuted: Bool

    public init(
        systemAudioGain: Double = 1,
        microphoneGain: Double = 1,
        systemAudioMuted: Bool = false,
        microphoneMuted: Bool = false
    ) {
        self.systemAudioGain = systemAudioGain
        self.microphoneGain = microphoneGain
        self.systemAudioMuted = systemAudioMuted
        self.microphoneMuted = microphoneMuted
    }

    public var isValid: Bool {
        systemAudioGain.isFinite
            && microphoneGain.isFinite
            && (MupawConstants.minimumRecordingAudioGain...MupawConstants.maximumRecordingAudioGain)
                .contains(systemAudioGain)
            && (MupawConstants.minimumRecordingAudioGain...MupawConstants.maximumRecordingAudioGain)
                .contains(microphoneGain)
    }

    public func applying(_ update: RecordingAudioControlUpdateRequest) -> RecordingAudioControls {
        RecordingAudioControls(
            systemAudioGain: update.systemAudioGain ?? systemAudioGain,
            microphoneGain: update.microphoneGain ?? microphoneGain,
            systemAudioMuted: update.systemAudioMuted ?? systemAudioMuted,
            microphoneMuted: update.microphoneMuted ?? microphoneMuted
        )
    }
}

public enum RecordingAudioState: String, Codable, Sendable, CaseIterable, Hashable {
    case disabled
    case waiting
    case capturing
    case completed
    case failed
    case cancelled
}

public struct RecordingAudioLevel: Codable, Sendable, Equatable {
    public let rms: Double
    public let peak: Double
    public let measuredAt: Date
    public let sourceTimestampSeconds: Double?
    public let isStale: Bool

    public init(
        rms: Double,
        peak: Double,
        measuredAt: Date,
        sourceTimestampSeconds: Double? = nil,
        isStale: Bool = false
    ) {
        self.rms = rms
        self.peak = peak
        self.measuredAt = measuredAt
        self.sourceTimestampSeconds = sourceTimestampSeconds
        self.isStale = isStale
    }
}

public struct RecordingAudioLevelSummary: Codable, Sendable, Equatable {
    public let averageRMS: Double
    public let maximumPeak: Double
    public let measurementCount: Int

    public init(averageRMS: Double, maximumPeak: Double, measurementCount: Int) {
        self.averageRMS = averageRMS
        self.maximumPeak = maximumPeak
        self.measurementCount = measurementCount
    }
}

public struct RecordingAudioInputInfo: Codable, Sendable, Equatable {
    public let requested: Bool
    public let state: RecordingAudioState
    public let sampleRate: Int?
    public let channelCount: Int?
    public let durationSeconds: Double?
    public let sampleBufferCount: Int
    public let lastSampleAt: Date?
    public let lastSourceTimestampSeconds: Double?
    public let currentLevel: RecordingAudioLevel?
    public let levelSummary: RecordingAudioLevelSummary?
    public let deviceID: String?
    public let deviceName: String?

    public init(
        requested: Bool,
        state: RecordingAudioState,
        sampleRate: Int? = nil,
        channelCount: Int? = nil,
        durationSeconds: Double? = nil,
        sampleBufferCount: Int = 0,
        lastSampleAt: Date? = nil,
        lastSourceTimestampSeconds: Double? = nil,
        currentLevel: RecordingAudioLevel? = nil,
        levelSummary: RecordingAudioLevelSummary? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil
    ) {
        self.requested = requested
        self.state = state
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationSeconds = durationSeconds
        self.sampleBufferCount = sampleBufferCount
        self.lastSampleAt = lastSampleAt
        self.lastSourceTimestampSeconds = lastSourceTimestampSeconds
        self.currentLevel = currentLevel
        self.levelSummary = levelSummary
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

public struct RecordingAudioInfo: Codable, Sendable, Equatable {
    public let requested: Bool
    public let source: RecordingAudioSource
    public let state: RecordingAudioState
    public let codec: RecordingAudioCodec?
    public let trackCount: Int
    public let sampleRate: Int?
    public let channelCount: Int?
    public let durationSeconds: Double?
    public let sampleBufferCount: Int
    public let audioVideoDurationDifferenceSeconds: Double?
    public let deviceID: String?
    public let deviceName: String?
    public let controls: RecordingAudioControls
    public let systemAudioInput: RecordingAudioInputInfo?
    public let microphoneInput: RecordingAudioInputInfo?
    public let mixedLevel: RecordingAudioLevel?
    public let controlEventCount: Int

    public init(
        requested: Bool,
        source: RecordingAudioSource? = nil,
        state: RecordingAudioState,
        codec: RecordingAudioCodec? = nil,
        trackCount: Int = 0,
        sampleRate: Int? = nil,
        channelCount: Int? = nil,
        durationSeconds: Double? = nil,
        sampleBufferCount: Int = 0,
        audioVideoDurationDifferenceSeconds: Double? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil,
        controls: RecordingAudioControls = RecordingAudioControls(),
        systemAudioInput: RecordingAudioInputInfo? = nil,
        microphoneInput: RecordingAudioInputInfo? = nil,
        mixedLevel: RecordingAudioLevel? = nil,
        controlEventCount: Int = 0
    ) {
        self.requested = requested
        self.source = source ?? (requested ? .systemAudio : .none)
        self.state = state
        self.codec = codec
        self.trackCount = trackCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationSeconds = durationSeconds
        self.sampleBufferCount = sampleBufferCount
        self.audioVideoDurationDifferenceSeconds = audioVideoDurationDifferenceSeconds
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.controls = controls
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
        self.mixedLevel = mixedLevel
        self.controlEventCount = controlEventCount
    }

    private enum CodingKeys: String, CodingKey {
        case requested
        case source
        case state
        case codec
        case trackCount
        case sampleRate
        case channelCount
        case durationSeconds
        case sampleBufferCount
        case audioVideoDurationDifferenceSeconds
        case deviceID
        case deviceName
        case controls
        case systemAudioInput
        case microphoneInput
        case mixedLevel
        case controlEventCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requested = try container.decodeIfPresent(Bool.self, forKey: .requested) ?? false
        source =
            try container.decodeIfPresent(RecordingAudioSource.self, forKey: .source)
            ?? (requested ? .systemAudio : .none)
        state = try container.decode(RecordingAudioState.self, forKey: .state)
        codec = try container.decodeIfPresent(RecordingAudioCodec.self, forKey: .codec)
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        sampleBufferCount = try container.decodeIfPresent(Int.self, forKey: .sampleBufferCount) ?? 0
        audioVideoDurationDifferenceSeconds =
            try container.decodeIfPresent(
                Double.self,
                forKey: .audioVideoDurationDifferenceSeconds
            )
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        controls =
            try container.decodeIfPresent(RecordingAudioControls.self, forKey: .controls)
            ?? RecordingAudioControls()
        systemAudioInput = try container.decodeIfPresent(
            RecordingAudioInputInfo.self,
            forKey: .systemAudioInput
        )
        microphoneInput = try container.decodeIfPresent(
            RecordingAudioInputInfo.self,
            forKey: .microphoneInput
        )
        mixedLevel = try container.decodeIfPresent(RecordingAudioLevel.self, forKey: .mixedLevel)
        controlEventCount = try container.decodeIfPresent(Int.self, forKey: .controlEventCount) ?? 0
    }

    public static let disabled = RecordingAudioInfo(
        requested: false,
        source: .none,
        state: .disabled
    )
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
    public let audioSource: RecordingAudioSource
    public let includeSystemAudio: Bool
    public let includeMicrophone: Bool
    public let microphoneDeviceID: String?
    public let systemAudioGain: Double
    public let microphoneGain: Double
    public let systemAudioMuted: Bool
    public let microphoneMuted: Bool
    public let cameraOverlay: RecordingCameraOverlayConfiguration
    public let excludeMupawUI: Bool
    public let fileName: String?

    public var hasConflictingAudioSelection: Bool {
        (includeSystemAudio && !audioSource.usesSystemAudio)
            || (includeMicrophone && !audioSource.usesMicrophone)
    }

    public var audioControls: RecordingAudioControls {
        RecordingAudioControls(
            systemAudioGain: systemAudioGain,
            microphoneGain: microphoneGain,
            systemAudioMuted: systemAudioMuted,
            microphoneMuted: microphoneMuted
        )
    }

    public init(
        mode: ScreenshotCaptureMode,
        sourceID: String? = nil,
        region: CaptureRegion? = nil,
        format: RecordingFormat = .mp4,
        frameRate: Int = 30,
        quality: RecordingVideoQuality = .standard,
        includeCursor: Bool = false,
        audioSource: RecordingAudioSource? = nil,
        includeSystemAudio: Bool = false,
        includeMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        systemAudioGain: Double = 1,
        microphoneGain: Double = 1,
        systemAudioMuted: Bool = false,
        microphoneMuted: Bool = false,
        cameraOverlay: RecordingCameraOverlayConfiguration = .disabled,
        excludeMupawUI: Bool = true,
        fileName: String? = nil
    ) {
        let resolvedAudioSource: RecordingAudioSource
        if let audioSource {
            resolvedAudioSource = audioSource
        } else if includeSystemAudio && includeMicrophone {
            resolvedAudioSource = .systemAudioAndMicrophone
        } else if includeSystemAudio && !includeMicrophone {
            resolvedAudioSource = .systemAudio
        } else if includeMicrophone && !includeSystemAudio {
            resolvedAudioSource = .microphone
        } else {
            resolvedAudioSource = .none
        }

        self.mode = mode
        self.sourceID = sourceID
        self.region = region
        self.format = format
        self.frameRate = frameRate
        self.quality = quality
        self.includeCursor = includeCursor
        self.audioSource = resolvedAudioSource
        self.includeSystemAudio = includeSystemAudio || resolvedAudioSource.usesSystemAudio
        self.includeMicrophone = includeMicrophone || resolvedAudioSource.usesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.systemAudioGain = systemAudioGain
        self.microphoneGain = microphoneGain
        self.systemAudioMuted = systemAudioMuted
        self.microphoneMuted = microphoneMuted
        self.cameraOverlay = cameraOverlay
        self.excludeMupawUI = excludeMupawUI
        self.fileName = fileName
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case sourceID
        case region
        case format
        case frameRate
        case quality
        case includeCursor
        case audioSource
        case includeSystemAudio
        case includeMicrophone
        case microphoneDeviceID
        case systemAudioGain
        case microphoneGain
        case systemAudioMuted
        case microphoneMuted
        case cameraOverlay
        case excludeMupawUI
        case fileName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(ScreenshotCaptureMode.self, forKey: .mode)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        region = try container.decodeIfPresent(CaptureRegion.self, forKey: .region)
        format = try container.decodeIfPresent(RecordingFormat.self, forKey: .format) ?? .mp4
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate) ?? 30
        quality =
            try container.decodeIfPresent(RecordingVideoQuality.self, forKey: .quality) ?? .standard
        includeCursor = try container.decodeIfPresent(Bool.self, forKey: .includeCursor) ?? false

        let explicitAudioSource =
            try container.decodeIfPresent(RecordingAudioSource.self, forKey: .audioSource)
        let legacySystemAudio =
            try container.decodeIfPresent(Bool.self, forKey: .includeSystemAudio) ?? false
        let legacyMicrophone =
            try container.decodeIfPresent(Bool.self, forKey: .includeMicrophone) ?? false
        if let explicitAudioSource {
            audioSource = explicitAudioSource
        } else if legacySystemAudio && legacyMicrophone {
            audioSource = .systemAudioAndMicrophone
        } else if legacySystemAudio && !legacyMicrophone {
            audioSource = .systemAudio
        } else if legacyMicrophone && !legacySystemAudio {
            audioSource = .microphone
        } else {
            audioSource = .none
        }
        includeSystemAudio = legacySystemAudio || audioSource.usesSystemAudio
        includeMicrophone = legacyMicrophone || audioSource.usesMicrophone
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        systemAudioGain =
            try container.decodeIfPresent(Double.self, forKey: .systemAudioGain) ?? 1
        microphoneGain = try container.decodeIfPresent(Double.self, forKey: .microphoneGain) ?? 1
        systemAudioMuted =
            try container.decodeIfPresent(Bool.self, forKey: .systemAudioMuted) ?? false
        microphoneMuted =
            try container.decodeIfPresent(Bool.self, forKey: .microphoneMuted) ?? false
        cameraOverlay =
            try container.decodeIfPresent(
                RecordingCameraOverlayConfiguration.self,
                forKey: .cameraOverlay
            ) ?? .disabled
        excludeMupawUI = try container.decodeIfPresent(Bool.self, forKey: .excludeMupawUI) ?? true
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
    }
}

public struct MicrophoneDeviceDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let manufacturer: String?
    public let isDefault: Bool
    public let isConnected: Bool

    public init(
        id: String,
        name: String,
        manufacturer: String? = nil,
        isDefault: Bool,
        isConnected: Bool
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isDefault = isDefault
        self.isConnected = isConnected
    }
}

public struct MicrophoneDeviceListResult: Codable, Sendable, Equatable {
    public let refreshedAt: Date
    public let permission: PermissionStatus
    public let defaultDeviceID: String?
    public let devices: [MicrophoneDeviceDescriptor]

    public init(
        refreshedAt: Date = Date(),
        permission: PermissionStatus,
        defaultDeviceID: String?,
        devices: [MicrophoneDeviceDescriptor]
    ) {
        self.refreshedAt = refreshedAt
        self.permission = permission
        self.defaultDeviceID = defaultDeviceID
        self.devices = devices
    }
}

public struct RecordingSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

public struct RecordingCameraOverlayUpdateRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let visible: Bool?
    public let position: RecordingCameraOverlayPosition?
    public let size: RecordingCameraOverlaySize?
    public let shape: RecordingCameraOverlayShape?
    public let cornerRadius: Double?
    public let margin: Double?

    public init(
        sessionID: String,
        visible: Bool? = nil,
        position: RecordingCameraOverlayPosition? = nil,
        size: RecordingCameraOverlaySize? = nil,
        shape: RecordingCameraOverlayShape? = nil,
        cornerRadius: Double? = nil,
        margin: Double? = nil
    ) {
        self.sessionID = sessionID
        self.visible = visible
        self.position = position
        self.size = size
        self.shape = shape
        self.cornerRadius = cornerRadius
        self.margin = margin
    }

    public var hasChanges: Bool {
        visible != nil
            || position != nil
            || size != nil
            || shape != nil
            || cornerRadius != nil
            || margin != nil
    }
}

public struct RecordingAudioControlUpdateRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let systemAudioGain: Double?
    public let microphoneGain: Double?
    public let systemAudioMuted: Bool?
    public let microphoneMuted: Bool?

    public init(
        sessionID: String,
        systemAudioGain: Double? = nil,
        microphoneGain: Double? = nil,
        systemAudioMuted: Bool? = nil,
        microphoneMuted: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.systemAudioGain = systemAudioGain
        self.microphoneGain = microphoneGain
        self.systemAudioMuted = systemAudioMuted
        self.microphoneMuted = microphoneMuted
    }

    public var hasChanges: Bool {
        systemAudioGain != nil
            || microphoneGain != nil
            || systemAudioMuted != nil
            || microphoneMuted != nil
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
    public let audio: RecordingAudioInfo
    public let camera: RecordingCameraInfo
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
        audio: RecordingAudioInfo = .disabled,
        camera: RecordingCameraInfo = .disabled,
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
        self.audio = audio
        self.camera = camera
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
    public let audio: RecordingAudioInfo
    public let camera: RecordingCameraInfo
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
        audio: RecordingAudioInfo = .disabled,
        camera: RecordingCameraInfo = .disabled,
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
        self.audio = audio
        self.camera = camera
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.elapsedDurationSeconds = elapsedDurationSeconds
        self.frameCount = frameCount
        self.artifact = artifact
        self.errorMessage = errorMessage
    }
}
