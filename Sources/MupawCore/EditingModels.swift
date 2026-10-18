import Foundation

public struct ImagePixelPoint: Codable, Sendable, Equatable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite
    }

    public func translated(dx: Double, dy: Double) -> ImagePixelPoint {
        ImagePixelPoint(x: x + dx, y: y + dy)
    }
}

public struct ImagePixelRect: Codable, Sendable, Equatable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { min(x, x + width) }
    public var maxX: Double { max(x, x + width) }
    public var minY: Double { min(y, y + height) }
    public var maxY: Double { max(y, y + height) }

    public var standardized: ImagePixelRect {
        ImagePixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    public var hasPositiveArea: Bool {
        let value = standardized
        return value.width > 0 && value.height > 0
    }

    public var center: ImagePixelPoint {
        let value = standardized
        return ImagePixelPoint(x: value.minX + value.width / 2, y: value.minY + value.height / 2)
    }

    public func contains(_ point: ImagePixelPoint) -> Bool {
        let value = standardized
        return point.x >= value.minX && point.x <= value.maxX
            && point.y >= value.minY && point.y <= value.maxY
    }

    public func contains(_ other: ImagePixelRect) -> Bool {
        let value = standardized
        let candidate = other.standardized
        return candidate.minX >= value.minX && candidate.maxX <= value.maxX
            && candidate.minY >= value.minY && candidate.maxY <= value.maxY
    }

    public func intersection(_ other: ImagePixelRect) -> ImagePixelRect? {
        let value = standardized
        let candidate = other.standardized
        let left = max(value.minX, candidate.minX)
        let top = max(value.minY, candidate.minY)
        let right = min(value.maxX, candidate.maxX)
        let bottom = min(value.maxY, candidate.maxY)
        guard right > left, bottom > top else { return nil }
        return ImagePixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public func translated(dx: Double, dy: Double) -> ImagePixelRect {
        ImagePixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func clamped(to bounds: ImagePixelRect, minimumSize: Double = 1) -> ImagePixelRect {
        let outer = bounds.standardized
        let value = standardized
        let width = min(max(minimumSize, value.width), outer.width)
        let height = min(max(minimumSize, value.height), outer.height)
        let x = min(max(value.minX, outer.minX), outer.maxX - width)
        let y = min(max(value.minY, outer.minY), outer.maxY - height)
        return ImagePixelRect(x: x, y: y, width: width, height: height)
    }
}

public struct RGBAColor: Codable, Sendable, Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let annotationRed = RGBAColor(red: 0.92, green: 0.15, blue: 0.18)
    public static let annotationBlue = RGBAColor(red: 0.10, green: 0.45, blue: 0.95)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)

    public var isFiniteAndNormalized: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
}

public enum ScreenshotEditKind: String, Codable, Sendable, CaseIterable {
    case arrow
    case text
    case mosaic
}

public struct ArrowEdit: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let start: ImagePixelPoint
    public let end: ImagePixelPoint
    public let color: RGBAColor
    public let lineWidth: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        start: ImagePixelPoint,
        end: ImagePixelPoint,
        color: RGBAColor = .annotationRed,
        lineWidth: Double = 8
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }

    public var bounds: ImagePixelRect {
        ImagePixelRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

public struct TextEdit: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let frame: ImagePixelRect
    public let text: String
    public let color: RGBAColor
    public let fontSize: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        frame: ImagePixelRect,
        text: String,
        color: RGBAColor = .annotationRed,
        fontSize: Double = 42
    ) {
        self.id = id
        self.frame = frame
        self.text = text
        self.color = color
        self.fontSize = fontSize
    }
}

public struct MosaicEdit: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let frame: ImagePixelRect
    public let blockSize: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        frame: ImagePixelRect,
        blockSize: Double = 18
    ) {
        self.id = id
        self.frame = frame
        self.blockSize = blockSize
    }
}

public enum ScreenshotEditObject: Codable, Sendable, Equatable, Identifiable {
    case arrow(ArrowEdit)
    case text(TextEdit)
    case mosaic(MosaicEdit)

    private enum CodingKeys: String, CodingKey {
        case kind
        case arrow
        case text
        case mosaic
    }

    public var id: String {
        switch self {
        case .arrow(let value): value.id
        case .text(let value): value.id
        case .mosaic(let value): value.id
        }
    }

    public var kind: ScreenshotEditKind {
        switch self {
        case .arrow: .arrow
        case .text: .text
        case .mosaic: .mosaic
        }
    }

    public var bounds: ImagePixelRect {
        switch self {
        case .arrow(let value): value.bounds
        case .text(let value): value.frame.standardized
        case .mosaic(let value): value.frame.standardized
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ScreenshotEditKind.self, forKey: .kind) {
        case .arrow:
            self = .arrow(try container.decode(ArrowEdit.self, forKey: .arrow))
        case .text:
            self = .text(try container.decode(TextEdit.self, forKey: .text))
        case .mosaic:
            self = .mosaic(try container.decode(MosaicEdit.self, forKey: .mosaic))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .arrow(let value):
            try container.encode(value, forKey: .arrow)
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .mosaic(let value):
            try container.encode(value, forKey: .mosaic)
        }
    }

    public func translated(dx: Double, dy: Double) -> ScreenshotEditObject {
        switch self {
        case .arrow(let value):
            return .arrow(
                ArrowEdit(
                    id: value.id,
                    start: value.start.translated(dx: dx, dy: dy),
                    end: value.end.translated(dx: dx, dy: dy),
                    color: value.color,
                    lineWidth: value.lineWidth
                )
            )
        case .text(let value):
            return .text(
                TextEdit(
                    id: value.id,
                    frame: value.frame.translated(dx: dx, dy: dy),
                    text: value.text,
                    color: value.color,
                    fontSize: value.fontSize
                )
            )
        case .mosaic(let value):
            return .mosaic(
                MosaicEdit(
                    id: value.id,
                    frame: value.frame.translated(dx: dx, dy: dy),
                    blockSize: value.blockSize
                )
            )
        }
    }

    public func replacingBounds(_ newBounds: ImagePixelRect) -> ScreenshotEditObject {
        let target = newBounds.standardized
        switch self {
        case .arrow(let value):
            let old = value.bounds.standardized
            let startXRatio = old.width > 0 ? (value.start.x - old.minX) / old.width : 0
            let startYRatio = old.height > 0 ? (value.start.y - old.minY) / old.height : 0
            let endXRatio = old.width > 0 ? (value.end.x - old.minX) / old.width : 1
            let endYRatio = old.height > 0 ? (value.end.y - old.minY) / old.height : 1
            return .arrow(
                ArrowEdit(
                    id: value.id,
                    start: ImagePixelPoint(
                        x: target.minX + target.width * startXRatio,
                        y: target.minY + target.height * startYRatio
                    ),
                    end: ImagePixelPoint(
                        x: target.minX + target.width * endXRatio,
                        y: target.minY + target.height * endYRatio
                    ),
                    color: value.color,
                    lineWidth: value.lineWidth
                )
            )
        case .text(let value):
            return .text(
                TextEdit(
                    id: value.id,
                    frame: target,
                    text: value.text,
                    color: value.color,
                    fontSize: value.fontSize
                )
            )
        case .mosaic(let value):
            return .mosaic(
                MosaicEdit(id: value.id, frame: target, blockSize: value.blockSize)
            )
        }
    }
}

public struct ScreenshotProjectContent: Codable, Sendable, Equatable {
    public let cropRect: ImagePixelRect?
    public let objects: [ScreenshotEditObject]

    public init(cropRect: ImagePixelRect? = nil, objects: [ScreenshotEditObject] = []) {
        self.cropRect = cropRect
        self.objects = objects
    }

    public static let empty = ScreenshotProjectContent()
}

public struct ScreenshotProjectState: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let schemaVersion: Int
    public let revision: Int
    public let title: String
    public let sourceArtifactID: String?
    public let originalFileURL: URL
    public let originalSHA256: String
    public let originalPixelWidth: Int
    public let originalPixelHeight: Int
    public let content: ScreenshotProjectContent
    public let canUndo: Bool
    public let canRedo: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        schemaVersion: Int,
        revision: Int,
        title: String,
        sourceArtifactID: String?,
        originalFileURL: URL,
        originalSHA256: String,
        originalPixelWidth: Int,
        originalPixelHeight: Int,
        content: ScreenshotProjectContent,
        canUndo: Bool,
        canRedo: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.title = title
        self.sourceArtifactID = sourceArtifactID
        self.originalFileURL = originalFileURL
        self.originalSHA256 = originalSHA256
        self.originalPixelWidth = originalPixelWidth
        self.originalPixelHeight = originalPixelHeight
        self.content = content
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var originalBounds: ImagePixelRect {
        ImagePixelRect(
            x: 0,
            y: 0,
            width: Double(originalPixelWidth),
            height: Double(originalPixelHeight)
        )
    }

    public var visibleBounds: ImagePixelRect {
        content.cropRect?.standardized ?? originalBounds
    }
}

public struct ProjectCreateRequest: Codable, Sendable, Equatable {
    public let sourceFileURL: URL
    public let sourceSHA256: String
    public let sourceArtifactID: String?
    public let title: String?

    public init(
        sourceFileURL: URL,
        sourceSHA256: String,
        sourceArtifactID: String? = nil,
        title: String? = nil
    ) {
        self.sourceFileURL = sourceFileURL
        self.sourceSHA256 = sourceSHA256
        self.sourceArtifactID = sourceArtifactID
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case sourceFileURL = "source_file_url"
        case sourceSHA256 = "source_sha256"
        case sourceArtifactID = "source_artifact_id"
        case title
    }
}

public struct ProjectGetRequest: Codable, Sendable, Equatable {
    public let projectID: String

    public init(projectID: String) {
        self.projectID = projectID
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
    }
}

public enum ProjectEditCommand: Codable, Sendable, Equatable {
    case setCrop(ImagePixelRect?)
    case addObject(ScreenshotEditObject)
    case updateObject(ScreenshotEditObject)
    case deleteObject(String)
    case reset

    public enum Kind: String, Codable, Sendable {
        case setCrop = "set_crop"
        case addObject = "add_object"
        case updateObject = "update_object"
        case deleteObject = "delete_object"
        case reset
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case rect
        case object
        case objectID = "object_id"
    }

    public var kind: Kind {
        switch self {
        case .setCrop: .setCrop
        case .addObject: .addObject
        case .updateObject: .updateObject
        case .deleteObject: .deleteObject
        case .reset: .reset
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .setCrop:
            guard container.contains(.rect) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.rect,
                    .init(
                        codingPath: container.codingPath,
                        debugDescription: "set_crop requires rect; use null to clear the crop."
                    )
                )
            }
            self = .setCrop(try container.decodeIfPresent(ImagePixelRect.self, forKey: .rect))
        case .addObject:
            self = .addObject(try container.decode(ScreenshotEditObject.self, forKey: .object))
        case .updateObject:
            self = .updateObject(try container.decode(ScreenshotEditObject.self, forKey: .object))
        case .deleteObject:
            self = .deleteObject(try container.decode(String.self, forKey: .objectID))
        case .reset:
            self = .reset
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        switch self {
        case .setCrop(let rect):
            if let rect {
                try container.encode(rect, forKey: .rect)
            } else {
                try container.encodeNil(forKey: .rect)
            }
        case .addObject(let object), .updateObject(let object):
            try container.encode(object, forKey: .object)
        case .deleteObject(let objectID):
            try container.encode(objectID, forKey: .objectID)
        case .reset:
            break
        }
    }
}

public struct ProjectApplyEditsRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let expectedRevision: Int
    public let commands: [ProjectEditCommand]

    public init(projectID: String, expectedRevision: Int, commands: [ProjectEditCommand]) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case expectedRevision = "expected_revision"
        case commands
    }
}

public enum ProjectHistoryAction: String, Codable, Sendable {
    case undo
    case redo
}

public struct ProjectHistoryRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let expectedRevision: Int
    public let action: ProjectHistoryAction

    public init(projectID: String, expectedRevision: Int, action: ProjectHistoryAction) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case expectedRevision = "expected_revision"
        case action
    }
}

public struct ProjectPreviewRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let expectedRevision: Int?

    public init(projectID: String, expectedRevision: Int? = nil) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case expectedRevision = "expected_revision"
    }
}

public struct ProjectPreviewResult: Codable, Sendable, Equatable {
    public let projectID: String
    public let revision: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let preview: ImagePreview

    public init(
        projectID: String,
        revision: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        preview: ImagePreview
    ) {
        self.projectID = projectID
        self.revision = revision
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.preview = preview
    }
}

public struct ProjectExportRequest: Codable, Sendable, Equatable {
    public let projectID: String
    public let expectedRevision: Int?
    public let fileName: String?

    public init(projectID: String, expectedRevision: Int? = nil, fileName: String? = nil) {
        self.projectID = projectID
        self.expectedRevision = expectedRevision
        self.fileName = fileName
    }

    private enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case expectedRevision = "expected_revision"
        case fileName = "file_name"
    }
}

public struct ProjectExportArtifact: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let projectRevision: Int
    public let fileURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int
    public let sha256: String
    public let createdAt: Date
    public let preview: ImagePreview

    public init(
        id: String,
        projectID: String,
        projectRevision: Int,
        fileURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int,
        sha256: String,
        createdAt: Date,
        preview: ImagePreview
    ) {
        self.id = id
        self.projectID = projectID
        self.projectRevision = projectRevision
        self.fileURL = fileURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
        self.preview = preview
    }
}
