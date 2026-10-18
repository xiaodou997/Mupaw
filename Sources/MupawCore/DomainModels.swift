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
}

public struct CaptureSourceDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: CaptureSourceKind
    public let title: String
    public let applicationName: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isOnScreen: Bool

    public init(
        id: String,
        kind: CaptureSourceKind,
        title: String,
        applicationName: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        isOnScreen: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isOnScreen = isOnScreen
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
    public let sourceID: String
    public let format: ScreenshotFormat
    public let includeCursor: Bool
    public let fileName: String?

    public init(
        sourceID: String,
        format: ScreenshotFormat = .png,
        includeCursor: Bool = false,
        fileName: String? = nil
    ) {
        self.sourceID = sourceID
        self.format = format
        self.includeCursor = includeCursor
        self.fileName = fileName
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
