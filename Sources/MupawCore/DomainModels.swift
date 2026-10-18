import Foundation

public enum PermissionStatus: String, Codable, Sendable, CaseIterable {
    case authorized
    case denied
    case notDetermined
    case restricted
    case unavailable
}

public struct PermissionSnapshot: Codable, Sendable, Equatable {
    public let screenCapture: PermissionStatus
    public let microphone: PermissionStatus
    public let camera: PermissionStatus
    public let accessibility: PermissionStatus
    public let inputMonitoring: PermissionStatus

    public init(
        screenCapture: PermissionStatus,
        microphone: PermissionStatus,
        camera: PermissionStatus,
        accessibility: PermissionStatus,
        inputMonitoring: PermissionStatus
    ) {
        self.screenCapture = screenCapture
        self.microphone = microphone
        self.camera = camera
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
}

public enum CapabilityAvailability: String, Codable, Sendable {
    case available
    case planned
    case unavailable
}

public struct CapabilityDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let availability: CapabilityAvailability
    public let detail: String

    public init(id: String, title: String, availability: CapabilityAvailability, detail: String) {
        self.id = id
        self.title = title
        self.availability = availability
        self.detail = detail
    }
}

public struct CapabilitySnapshot: Codable, Sendable, Equatable {
    public let appVersion: String
    public let minimumMacOSVersion: String
    public let rpcProtocolVersion: Int
    public let capabilities: [CapabilityDescriptor]

    public init(
        appVersion: String,
        minimumMacOSVersion: String,
        rpcProtocolVersion: Int,
        capabilities: [CapabilityDescriptor]
    ) {
        self.appVersion = appVersion
        self.minimumMacOSVersion = minimumMacOSVersion
        self.rpcProtocolVersion = rpcProtocolVersion
        self.capabilities = capabilities
    }
}

public enum CaptureSourceKind: String, Codable, Sendable {
    case display
    case window
    case region
}

public struct CaptureSourceDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: CaptureSourceKind
    public let title: String
    public let applicationName: String?
    public let applicationBundleIdentifier: String?
    public let applicationProcessID: Int32?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let framePoints: CaptureRect?
    public let pointPixelScale: Double?
    public let isOnScreen: Bool
    public let isActive: Bool?
    public let isPrimaryDisplay: Bool?

    public init(
        id: String,
        kind: CaptureSourceKind,
        title: String,
        applicationName: String?,
        applicationBundleIdentifier: String? = nil,
        applicationProcessID: Int32? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        framePoints: CaptureRect? = nil,
        pointPixelScale: Double? = nil,
        isOnScreen: Bool,
        isActive: Bool? = nil,
        isPrimaryDisplay: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationProcessID = applicationProcessID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.framePoints = framePoints
        self.pointPixelScale = pointPixelScale
        self.isOnScreen = isOnScreen
        self.isActive = isActive
        self.isPrimaryDisplay = isPrimaryDisplay
    }
}

public struct SourceListResult: Codable, Sendable, Equatable {
    public let refreshedAt: Date
    public let sources: [CaptureSourceDescriptor]

    public init(refreshedAt: Date, sources: [CaptureSourceDescriptor]) {
        self.refreshedAt = refreshedAt
        self.sources = sources
    }
}

public enum ScreenshotFormat: String, Codable, Sendable {
    case png
}

public struct ScreenshotRequest: Codable, Sendable, Equatable {
    public let mode: ScreenshotCaptureMode
    public let sourceID: String?
    public let region: CaptureRegion?
    public let format: ScreenshotFormat
    public let includeCursor: Bool
    public let excludeMupawUI: Bool
    public let fileName: String?

    public init(
        mode: ScreenshotCaptureMode,
        sourceID: String? = nil,
        region: CaptureRegion? = nil,
        format: ScreenshotFormat = .png,
        includeCursor: Bool = false,
        excludeMupawUI: Bool = true,
        fileName: String? = nil
    ) {
        self.mode = mode
        self.sourceID = sourceID
        self.region = region
        self.format = format
        self.includeCursor = includeCursor
        self.excludeMupawUI = excludeMupawUI
        self.fileName = fileName
    }

    public init(
        sourceID: String,
        format: ScreenshotFormat = .png,
        includeCursor: Bool = false,
        fileName: String? = nil
    ) {
        self.init(
            mode: sourceID.hasPrefix("window:") ? .window : .fullScreen,
            sourceID: sourceID,
            format: format,
            includeCursor: includeCursor,
            excludeMupawUI: false,
            fileName: fileName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case sourceID
        case region
        case format
        case includeCursor
        case excludeMupawUI
        case fileName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        let region = try container.decodeIfPresent(CaptureRegion.self, forKey: .region)
        let inferredMode: ScreenshotCaptureMode
        if let explicitMode = try container.decodeIfPresent(ScreenshotCaptureMode.self, forKey: .mode) {
            inferredMode = explicitMode
        } else if region != nil {
            inferredMode = .region
        } else if sourceID?.hasPrefix("window:") == true {
            inferredMode = .window
        } else {
            inferredMode = .fullScreen
        }

        self.mode = inferredMode
        self.sourceID = sourceID
        self.region = region
        self.format = try container.decodeIfPresent(ScreenshotFormat.self, forKey: .format) ?? .png
        self.includeCursor = try container.decodeIfPresent(Bool.self, forKey: .includeCursor) ?? false
        self.excludeMupawUI = try container.decodeIfPresent(Bool.self, forKey: .excludeMupawUI) ?? false
        self.fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
    }
}

public struct ImagePreview: Codable, Sendable, Equatable {
    public let mimeType: String
    public let base64Data: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(mimeType: String, base64Data: String, pixelWidth: Int, pixelHeight: Int) {
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct ScreenshotArtifact: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: CaptureSourceDescriptor
    public let format: ScreenshotFormat
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
    public let sha256: String
    public let createdAt: Date
    public let preview: ImagePreview?

    public init(
        id: String,
        source: CaptureSourceDescriptor,
        format: ScreenshotFormat,
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        sha256: String,
        createdAt: Date,
        preview: ImagePreview?
    ) {
        self.id = id
        self.source = source
        self.format = format
        self.fileURL = fileURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
        self.preview = preview
    }
}

public struct AppStatusResult: Codable, Sendable, Equatable {
    public let running: Bool
    public let appVersion: String
    public let rpcProtocolVersion: Int
    public let processID: Int32
    public let permissions: PermissionSnapshot

    public init(
        running: Bool,
        appVersion: String,
        rpcProtocolVersion: Int,
        processID: Int32,
        permissions: PermissionSnapshot
    ) {
        self.running = running
        self.appVersion = appVersion
        self.rpcProtocolVersion = rpcProtocolVersion
        self.processID = processID
        self.permissions = permissions
    }
}

public struct EmptyPayload: Codable, Sendable, Equatable {
    public init() {}
}
