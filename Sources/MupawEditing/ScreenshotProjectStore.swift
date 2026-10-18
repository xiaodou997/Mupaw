import CryptoKit
import Foundation
import ImageIO
import MupawCore

struct StoredScreenshotProject: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let id: String
    var revision: Int
    var title: String
    let sourceArtifactID: String?
    let originalFileName: String
    let originalSHA256: String
    let originalPixelWidth: Int
    let originalPixelHeight: Int
    var content: ScreenshotProjectContent
    var undoStack: [ScreenshotProjectContent]
    var redoStack: [ScreenshotProjectContent]
    let createdAt: Date
    var updatedAt: Date
}

struct ScreenshotProjectStore {
    let paths: MupawPaths
    let fileManager: FileManager

    init(paths: MupawPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func create(
        request: ProjectCreateRequest,
        now: Date = Date()
    ) throws -> StoredScreenshotProject {
        try paths.prepare(fileManager: fileManager)
        let sourceURL = try validatedSourceURL(request.sourceFileURL)
        let expectedHash = try validatedSHA256(request.sourceSHA256)
        let sourceArtifactID = try validatedSourceArtifactID(request.sourceArtifactID)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ScreenshotProjectServiceError.artifactNotFound(sourceURL)
        }

        let actualHash = try Self.sha256(of: sourceURL)
        guard actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
            throw ScreenshotProjectServiceError.artifactHashMismatch(
                expected: expectedHash,
                actual: actualHash
            )
        }

        let dimensions = try Self.imageDimensions(at: sourceURL)
        try Self.validateCanvas(width: dimensions.width, height: dimensions.height)

        let projectID = UUID().uuidString.lowercased()
        let projectDirectory = directoryURL(for: projectID)
        try fileManager.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: projectDirectory.path
        )

        do {
            let originalFileName = "original.png"
            let originalURL = projectDirectory.appendingPathComponent(originalFileName)
            try fileManager.copyItem(at: sourceURL, to: originalURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)

            let title = try validatedTitle(
                request.title,
                fallback: EditingL10n.string(
                    "editing.project.default_title",
                    fallback: "Mupaw Screenshot"
                )
            )
            let timestamp = Self.normalizedTimestamp(now)
            let record = StoredScreenshotProject(
                schemaVersion: MupawConstants.screenshotProjectSchemaVersion,
                id: projectID,
                revision: 1,
                title: title,
                sourceArtifactID: sourceArtifactID,
                originalFileName: originalFileName,
                originalSHA256: actualHash,
                originalPixelWidth: dimensions.width,
                originalPixelHeight: dimensions.height,
                content: .empty,
                undoStack: [],
                redoStack: [],
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try save(record)
            return record
        } catch {
            try? fileManager.removeItem(at: projectDirectory)
            throw error
        }
    }

    func load(
        projectID: String,
        verifyOriginal: Bool = false
    ) throws -> StoredScreenshotProject {
        let normalizedID = try validatedProjectID(projectID)
        let url = documentURL(for: normalizedID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScreenshotProjectServiceError.projectNotFound(normalizedID)
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let record = try JSONDecoder.mupaw.decode(StoredScreenshotProject.self, from: data)
            guard record.id == normalizedID,
                record.schemaVersion == MupawConstants.screenshotProjectSchemaVersion
            else {
                throw ScreenshotProjectServiceError.invalidProjectData(
                    EditingL10n.string(
                        "editing.detail.invalid_project_identity_or_schema",
                        fallback: "The project identifier or schema version is invalid."
                    )
                )
            }
            if verifyOriginal {
                try verifyOriginalIntegrity(record)
            }
            return record
        } catch let error as ScreenshotProjectServiceError {
            throw error
        } catch {
            throw ScreenshotProjectServiceError.invalidProjectData(error.localizedDescription)
        }
    }

    func save(_ record: StoredScreenshotProject) throws {
        let projectDirectory = directoryURL(for: record.id)
        try fileManager.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: projectDirectory.path
        )
        let encoder = JSONEncoder.mupaw
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let url = documentURL(for: record.id)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func state(from record: StoredScreenshotProject) -> ScreenshotProjectState {
        ScreenshotProjectState(
            id: record.id,
            schemaVersion: record.schemaVersion,
            revision: record.revision,
            title: record.title,
            sourceArtifactID: record.sourceArtifactID,
            originalFileURL: originalURL(for: record),
            originalSHA256: record.originalSHA256,
            originalPixelWidth: record.originalPixelWidth,
            originalPixelHeight: record.originalPixelHeight,
            content: record.content,
            canUndo: !record.undoStack.isEmpty,
            canRedo: !record.redoStack.isEmpty,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    func originalURL(for record: StoredScreenshotProject) -> URL {
        directoryURL(for: record.id).appendingPathComponent(record.originalFileName)
    }

    func directoryURL(for projectID: String) -> URL {
        paths.projectsDirectory.appendingPathComponent(projectID, isDirectory: true)
    }

    private func documentURL(for projectID: String) -> URL {
        directoryURL(for: projectID).appendingPathComponent("project.json")
    }

    private func verifyOriginalIntegrity(_ record: StoredScreenshotProject) throws {
        let url = originalURL(for: record)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScreenshotProjectServiceError.artifactNotFound(url)
        }
        let actualHash = try Self.sha256(of: url)
        guard actualHash.caseInsensitiveCompare(record.originalSHA256) == .orderedSame else {
            throw ScreenshotProjectServiceError.artifactHashMismatch(
                expected: record.originalSHA256,
                actual: actualHash
            )
        }
        let dimensions = try Self.imageDimensions(at: url)
        guard dimensions.width == record.originalPixelWidth,
            dimensions.height == record.originalPixelHeight
        else {
            throw ScreenshotProjectServiceError.invalidProjectData(
                EditingL10n.string(
                    "editing.detail.original_dimensions_changed",
                    fallback: "The copied original image dimensions no longer match the project."
                )
            )
        }
        try Self.validateCanvas(width: dimensions.width, height: dimensions.height)
    }

    private func validatedSHA256(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
            normalized.unicodeScalars.allSatisfy({ scalar in
                ("0"..."9").contains(String(scalar))
                    || ("a"..."f").contains(String(scalar))
            })
        else {
            throw ScreenshotProjectServiceError.invalidEdit(
                EditingL10n.string(
                    "editing.detail.invalid_source_sha256",
                    fallback: "The source SHA-256 must contain exactly 64 hexadecimal characters."
                )
            )
        }
        return normalized
    }

    private func validatedSourceArtifactID(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.utf8.count <= MupawConstants.maximumProjectSourceArtifactIDUTF8Bytes
        else {
            throw ScreenshotProjectServiceError.invalidEdit(
                EditingL10n.string(
                    "editing.detail.invalid_source_artifact_id",
                    fallback: "The source artifact identifier is empty or too long."
                )
            )
        }
        return normalized
    }

    private func validatedSourceURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ScreenshotProjectServiceError.invalidSourceURL
        }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = paths.capturesDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let sourcePath = source.path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard sourcePath.hasPrefix(rootPath) else {
            throw ScreenshotProjectServiceError.sourceOutsideCaptureDirectory
        }
        return source
    }

    private func validatedProjectID(_ projectID: String) throws -> String {
        guard let uuid = UUID(uuidString: projectID) else {
            throw ScreenshotProjectServiceError.invalidProjectID(projectID)
        }
        return uuid.uuidString.lowercased()
    }

    private func validatedTitle(_ title: String?, fallback: String) throws -> String {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = value?.isEmpty == false ? value! : fallback
        guard resolved.utf8.count <= MupawConstants.maximumProjectTitleUTF8Bytes else {
            throw ScreenshotProjectServiceError.invalidEdit(
                EditingL10n.string(
                    "editing.detail.title_too_long",
                    fallback: "The project title is too long."
                )
            )
        }
        return resolved
    }

    static func normalizedTimestamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ScreenshotProjectServiceError.artifactNotFound(url)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func imageDimensions(at url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw ScreenshotProjectServiceError.unsupportedImage
        }
        return (width.intValue, height.intValue)
    }

    static func validateCanvas(width: Int, height: Int) throws {
        guard width > 0, height > 0,
            width <= MupawConstants.maximumScreenshotPixelCount / height
        else {
            throw ScreenshotProjectServiceError.canvasTooLarge
        }
    }
}
