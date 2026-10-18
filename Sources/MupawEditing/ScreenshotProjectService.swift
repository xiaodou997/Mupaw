import Foundation
import MupawCore

public enum ScreenshotProjectServiceError: Error, LocalizedError, Sendable, Equatable {
    case invalidSourceURL
    case sourceOutsideCaptureDirectory
    case artifactNotFound(URL)
    case artifactHashMismatch(expected: String, actual: String)
    case unsupportedImage
    case canvasTooLarge
    case invalidProjectID(String)
    case projectNotFound(String)
    case invalidProjectData(String)
    case versionConflict(expected: Int, actual: Int)
    case invalidEdit(String)
    case historyUnavailable(ProjectHistoryAction)
    case renderFailed(String)
    case exportFailed(String)
    case invalidAnalysis(String)
    case ocrFailed(String)
    case colorSamplingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL:
            return EditingL10n.string(
                "editing.error.invalid_source_url",
                fallback: "The source image URL is invalid."
            )
        case .sourceOutsideCaptureDirectory:
            return EditingL10n.string(
                "editing.error.source_outside_capture_directory",
                fallback: "Project sources must come from Mupaw's capture directory."
            )
        case .artifactNotFound(let url):
            return EditingL10n.format(
                "editing.error.artifact_not_found.format",
                fallback: "The source image does not exist: %@",
                url.path
            )
        case .artifactHashMismatch(let expected, let actual):
            return EditingL10n.format(
                "editing.error.artifact_hash_mismatch.format",
                fallback: "The source image SHA-256 does not match. Expected %@, received %@.",
                expected,
                actual
            )
        case .unsupportedImage:
            return EditingL10n.string(
                "editing.error.unsupported_image",
                fallback: "The source image is not a supported image."
            )
        case .canvasTooLarge:
            return EditingL10n.string(
                "editing.error.canvas_too_large",
                fallback: "The image canvas is too large to process safely."
            )
        case .invalidProjectID(let id):
            return EditingL10n.format(
                "editing.error.invalid_project_id.format",
                fallback: "The project identifier is invalid: %@",
                id
            )
        case .projectNotFound(let id):
            return EditingL10n.format(
                "editing.error.project_not_found.format",
                fallback: "The screenshot project was not found: %@",
                id
            )
        case .invalidProjectData(let message):
            return EditingL10n.format(
                "editing.error.invalid_project_data.format",
                fallback: "The screenshot project is invalid: %@",
                message
            )
        case .versionConflict(let expected, let actual):
            return EditingL10n.format(
                "editing.error.version_conflict.format",
                fallback: "Project revision conflict. Expected %d, current revision is %d.",
                expected,
                actual
            )
        case .invalidEdit(let message):
            return EditingL10n.format(
                "editing.error.invalid_edit.format",
                fallback: "The edit is invalid: %@",
                message
            )
        case .historyUnavailable(let action):
            return EditingL10n.format(
                "editing.error.history_unavailable.format",
                fallback: "Project history cannot perform %@.",
                EditingL10n.historyAction(action)
            )
        case .renderFailed(let message):
            return EditingL10n.format(
                "editing.error.render_failed.format",
                fallback: "The project could not be rendered: %@",
                message
            )
        case .exportFailed(let message):
            return EditingL10n.format(
                "editing.error.export_failed.format",
                fallback: "The project could not be exported: %@",
                message
            )
        case .invalidAnalysis(let message):
            return EditingL10n.format(
                "analysis.error.invalid_analysis.format",
                fallback: "The analysis request is invalid: %@",
                message
            )
        case .ocrFailed(let message):
            return EditingL10n.format(
                "analysis.error.ocr_failed.format",
                fallback: "OCR failed: %@",
                message
            )
        case .colorSamplingFailed(let message):
            return EditingL10n.format(
                "analysis.error.color_sampling_failed.format",
                fallback: "Color sampling failed: %@",
                message
            )
        }
    }
}

public actor ScreenshotProjectService {
    private let paths: MupawPaths
    private let store: ScreenshotProjectStore
    private let renderer = ScreenshotRenderer()
    private let analyzer: ScreenshotAnalyzer

    public init(paths: MupawPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.store = ScreenshotProjectStore(paths: paths, fileManager: fileManager)
        self.analyzer = ScreenshotAnalyzer()
    }

    public init(
        paths: MupawPaths,
        fileManager: FileManager = .default,
        textRecognizer: any ScreenshotTextRecognizing
    ) {
        self.paths = paths
        self.store = ScreenshotProjectStore(paths: paths, fileManager: fileManager)
        self.analyzer = ScreenshotAnalyzer(textRecognizer: textRecognizer)
    }

    public func createProject(_ request: ProjectCreateRequest) throws -> ScreenshotProjectState {
        let record = try store.create(request: request)
        return store.state(from: record)
    }

    public func getProject(_ request: ProjectGetRequest) throws -> ScreenshotProjectState {
        store.state(
            from: try store.load(
                projectID: request.projectID,
                verifyOriginal: true
            )
        )
    }

    public func applyEdits(_ request: ProjectApplyEditsRequest) throws -> ScreenshotProjectState {
        guard !request.commands.isEmpty else {
            throw ScreenshotProjectServiceError.invalidEdit(
                EditingL10n.string(
                    "editing.detail.command_required",
                    fallback: "At least one command is required."
                )
            )
        }
        guard request.commands.count <= MupawConstants.maximumProjectCommandsPerBatch else {
            throw ScreenshotProjectServiceError.invalidEdit(
                EditingL10n.format(
                    "editing.detail.too_many_commands.format",
                    fallback: "A batch may contain at most %d commands.",
                    MupawConstants.maximumProjectCommandsPerBatch
                )
            )
        }
        var record = try store.load(projectID: request.projectID)
        try verifyRevision(request.expectedRevision, record: record)

        let previous = record.content
        var content = record.content
        for command in request.commands {
            content = try applying(command, to: content)
        }
        try validate(content: content, record: record)

        record.undoStack.append(previous)
        if record.undoStack.count > MupawConstants.maximumProjectHistoryDepth {
            record.undoStack.removeFirst(record.undoStack.count - MupawConstants.maximumProjectHistoryDepth)
        }
        record.redoStack.removeAll()
        record.content = content
        record.revision += 1
        record.updatedAt = ScreenshotProjectStore.normalizedTimestamp()
        try store.save(record)
        return store.state(from: record)
    }

    public func performHistory(_ request: ProjectHistoryRequest) throws -> ScreenshotProjectState {
        var record = try store.load(projectID: request.projectID)
        try verifyRevision(request.expectedRevision, record: record)

        switch request.action {
        case .undo:
            guard let content = record.undoStack.popLast() else {
                throw ScreenshotProjectServiceError.historyUnavailable(.undo)
            }
            record.redoStack.append(record.content)
            if record.redoStack.count > MupawConstants.maximumProjectHistoryDepth {
                record.redoStack.removeFirst(record.redoStack.count - MupawConstants.maximumProjectHistoryDepth)
            }
            record.content = content
        case .redo:
            guard let content = record.redoStack.popLast() else {
                throw ScreenshotProjectServiceError.historyUnavailable(.redo)
            }
            record.undoStack.append(record.content)
            if record.undoStack.count > MupawConstants.maximumProjectHistoryDepth {
                record.undoStack.removeFirst(record.undoStack.count - MupawConstants.maximumProjectHistoryDepth)
            }
            record.content = content
        }

        try validate(content: record.content, record: record)
        record.revision += 1
        record.updatedAt = ScreenshotProjectStore.normalizedTimestamp()
        try store.save(record)
        return store.state(from: record)
    }

    public func previewProject(_ request: ProjectPreviewRequest) throws -> ProjectPreviewResult {
        let record = try store.load(
            projectID: request.projectID,
            verifyOriginal: true
        )
        if let expectedRevision = request.expectedRevision {
            try verifyRevision(expectedRevision, record: record)
        }
        let image = try renderer.render(record: record, originalURL: store.originalURL(for: record))
        return try renderer.preview(image: image, projectID: record.id, revision: record.revision)
    }

    public func exportProject(_ request: ProjectExportRequest) throws -> ProjectExportArtifact {
        let record = try store.load(
            projectID: request.projectID,
            verifyOriginal: true
        )
        if let expectedRevision = request.expectedRevision {
            try verifyRevision(expectedRevision, record: record)
        }
        do {
            let image = try renderer.render(record: record, originalURL: store.originalURL(for: record))
            return try EditingImageEncoder.exportPNG(
                image: image,
                record: record,
                fileName: request.fileName,
                paths: paths
            )
        } catch let error as ScreenshotProjectServiceError {
            throw error
        } catch {
            throw ScreenshotProjectServiceError.exportFailed(error.localizedDescription)
        }
    }

    public func recognizeText(_ request: ProjectOCRRequest) async throws -> ProjectOCRResult {
        let record = try store.load(
            projectID: request.projectID,
            verifyOriginal: true
        )
        if let expectedRevision = request.expectedRevision {
            try verifyRevision(expectedRevision, record: record)
        }
        return try await analyzer.recognizeText(
            record: record,
            originalURL: store.originalURL(for: record),
            request: request
        )
    }

    public func sampleColor(
        _ request: ProjectColorSampleRequest
    ) throws -> ProjectColorSampleResult {
        let record = try store.load(
            projectID: request.projectID,
            verifyOriginal: true
        )
        if let expectedRevision = request.expectedRevision {
            try verifyRevision(expectedRevision, record: record)
        }
        return try analyzer.sampleColor(
            record: record,
            originalURL: store.originalURL(for: record),
            request: request
        )
    }

    private func verifyRevision(_ expected: Int, record: StoredScreenshotProject) throws {
        guard expected == record.revision else {
            throw ScreenshotProjectServiceError.versionConflict(
                expected: expected,
                actual: record.revision
            )
        }
    }

    private func applying(
        _ command: ProjectEditCommand,
        to content: ScreenshotProjectContent
    ) throws -> ScreenshotProjectContent {
        var cropRect = content.cropRect
        var objects = content.objects

        switch command {
        case .setCrop(let rect):
            cropRect = rect?.standardized
        case .addObject(let object):
            guard !objects.contains(where: { $0.id == object.id }) else {
                throw ScreenshotProjectServiceError.invalidEdit(
                    EditingL10n.format(
                        "editing.detail.duplicate_object_id.format",
                        fallback: "An object with identifier %@ already exists.",
                        object.id
                    )
                )
            }
            objects.append(object)
        case .updateObject(let object):
            guard let index = objects.firstIndex(where: { $0.id == object.id }) else {
                throw ScreenshotProjectServiceError.invalidEdit(
                    EditingL10n.format(
                        "editing.detail.update_object_missing.format",
                        fallback: "The object to update does not exist: %@",
                        object.id
                    )
                )
            }
            objects[index] = object
        case .deleteObject(let objectID):
            guard let index = objects.firstIndex(where: { $0.id == objectID }) else {
                throw ScreenshotProjectServiceError.invalidEdit(
                    EditingL10n.format(
                        "editing.detail.delete_object_missing.format",
                        fallback: "The object to delete does not exist: %@",
                        objectID
                    )
                )
            }
            objects.remove(at: index)
        case .reset:
            cropRect = nil
            objects.removeAll()
        }

        return ScreenshotProjectContent(cropRect: cropRect, objects: objects)
    }

    private func validate(
        content: ScreenshotProjectContent,
        record: StoredScreenshotProject
    ) throws {
        let bounds = ImagePixelRect(
            x: 0,
            y: 0,
            width: Double(record.originalPixelWidth),
            height: Double(record.originalPixelHeight)
        )
        if let crop = content.cropRect {
            let value = crop.standardized
            guard value.isFinite, value.width >= 1, value.height >= 1, bounds.contains(value) else {
                throw ScreenshotProjectServiceError.invalidEdit(
                    EditingL10n.string(
                        "editing.detail.invalid_crop",
                        fallback: "The crop must be a finite rectangle fully inside the source image."
                    )
                )
            }
        }
        guard content.objects.count <= MupawConstants.maximumProjectObjects else {
            throw ScreenshotProjectServiceError.invalidEdit(
                EditingL10n.format(
                    "editing.detail.too_many_objects.format",
                    fallback: "A project may contain at most %d objects.",
                    MupawConstants.maximumProjectObjects
                )
            )
        }

        var identifiers = Set<String>()
        for object in content.objects {
            guard UUID(uuidString: object.id) != nil else {
                throw ScreenshotProjectServiceError.invalidEdit(
                    EditingL10n.string(
                        "editing.detail.object_id_uuid",
                        fallback: "Object identifiers must be UUID strings."
                    )
                )
            }
            guard identifiers.insert(object.id.lowercased()).inserted else {
                throw ScreenshotProjectServiceError.invalidEdit(
                    EditingL10n.string(
                        "editing.detail.object_ids_unique",
                        fallback: "Object identifiers must be unique."
                    )
                )
            }

            switch object {
            case .arrow(let arrow):
                guard arrow.start.isFinite, arrow.end.isFinite,
                    bounds.contains(arrow.start), bounds.contains(arrow.end),
                    arrow.color.isFiniteAndNormalized,
                    arrow.lineWidth.isFinite,
                    arrow.lineWidth >= 1,
                    arrow.lineWidth <= MupawConstants.maximumEditorLineWidth,
                    hypot(arrow.end.x - arrow.start.x, arrow.end.y - arrow.start.y)
                        >= MupawConstants.minimumEditorObjectSize
                else {
                    throw ScreenshotProjectServiceError.invalidEdit(
                        EditingL10n.string(
                            "editing.detail.invalid_arrow",
                            fallback: "Arrow coordinates, color, length, or line width are invalid."
                        )
                    )
                }
            case .text(let text):
                let frame = text.frame.standardized
                let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard frame.isFinite,
                    frame.width >= MupawConstants.minimumEditorObjectSize,
                    frame.height >= MupawConstants.minimumEditorObjectSize,
                    bounds.contains(frame),
                    !trimmed.isEmpty,
                    text.text.utf8.count <= MupawConstants.maximumTextEditUTF8Bytes,
                    text.color.isFiniteAndNormalized,
                    text.fontSize.isFinite,
                    text.fontSize >= MupawConstants.minimumEditorFontSize,
                    text.fontSize <= MupawConstants.maximumEditorFontSize
                else {
                    throw ScreenshotProjectServiceError.invalidEdit(
                        EditingL10n.string(
                            "editing.detail.invalid_text",
                            fallback: "Text content, frame, color, or font size is invalid."
                        )
                    )
                }
            case .mosaic(let mosaic):
                let frame = mosaic.frame.standardized
                guard frame.isFinite,
                    frame.width >= MupawConstants.minimumEditorObjectSize,
                    frame.height >= MupawConstants.minimumEditorObjectSize,
                    bounds.contains(frame),
                    mosaic.blockSize.isFinite,
                    mosaic.blockSize >= MupawConstants.minimumMosaicBlockSize,
                    mosaic.blockSize <= MupawConstants.maximumMosaicBlockSize
                else {
                    throw ScreenshotProjectServiceError.invalidEdit(
                        EditingL10n.string(
                            "editing.detail.invalid_mosaic",
                            fallback: "The mosaic frame or block size is invalid."
                        )
                    )
                }
            }
        }
    }
}
