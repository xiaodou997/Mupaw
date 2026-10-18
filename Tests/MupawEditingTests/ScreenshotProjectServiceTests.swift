import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest

@testable import MupawCore
@testable import MupawEditing

final class ScreenshotProjectServiceTests: XCTestCase {
    func testCreateApplyPreviewUndoRedoAndExport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)

        let created = try await service.createProject(fixture.createRequest)
        XCTAssertEqual(created.revision, 1)
        XCTAssertEqual(created.originalPixelWidth, 320)
        XCTAssertEqual(created.originalPixelHeight, 240)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.originalFileURL.path))
        XCTAssertFalse(created.canUndo)
        let projectDirectory = created.originalFileURL.deletingLastPathComponent()
        XCTAssertEqual(try Self.permissions(at: fixture.paths.rootDirectory), 0o700)
        XCTAssertEqual(try Self.permissions(at: fixture.paths.capturesDirectory), 0o700)
        XCTAssertEqual(try Self.permissions(at: fixture.paths.projectsDirectory), 0o700)
        XCTAssertEqual(try Self.permissions(at: fixture.paths.exportsDirectory), 0o700)
        XCTAssertEqual(try Self.permissions(at: projectDirectory), 0o700)
        XCTAssertEqual(try Self.permissions(at: created.originalFileURL), 0o600)
        XCTAssertEqual(
            try Self.permissions(at: projectDirectory.appendingPathComponent("project.json")),
            0o600
        )

        let arrowID = UUID().uuidString.lowercased()
        let textID = UUID().uuidString.lowercased()
        let mosaicID = UUID().uuidString.lowercased()
        let edited = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                commands: [
                    .setCrop(ImagePixelRect(x: 20, y: 30, width: 200, height: 120)),
                    .addObject(
                        .arrow(
                            ArrowEdit(
                                id: arrowID,
                                start: ImagePixelPoint(x: 40, y: 60),
                                end: ImagePixelPoint(x: 180, y: 120)
                            )
                        )
                    ),
                    .addObject(
                        .text(
                            TextEdit(
                                id: textID,
                                frame: ImagePixelRect(x: 50, y: 70, width: 120, height: 44),
                                text: "Mupaw",
                                fontSize: 28
                            )
                        )
                    ),
                    .addObject(
                        .mosaic(
                            MosaicEdit(
                                id: mosaicID,
                                frame: ImagePixelRect(x: 80, y: 100, width: 60, height: 40),
                                blockSize: 10
                            )
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(edited.revision, 2)
        XCTAssertEqual(edited.content.objects.count, 3)
        XCTAssertTrue(edited.canUndo)
        XCTAssertFalse(edited.canRedo)

        let preview = try await service.previewProject(
            ProjectPreviewRequest(projectID: edited.id, expectedRevision: edited.revision)
        )
        XCTAssertEqual(preview.pixelWidth, 200)
        XCTAssertEqual(preview.pixelHeight, 120)
        XCTAssertEqual(preview.preview.mimeType, "image/jpeg")
        XCTAssertFalse(preview.preview.base64Data.isEmpty)

        let undone = try await service.performHistory(
            ProjectHistoryRequest(
                projectID: edited.id,
                expectedRevision: edited.revision,
                action: .undo
            )
        )
        XCTAssertEqual(undone.revision, 3)
        XCTAssertNil(undone.content.cropRect)
        XCTAssertTrue(undone.content.objects.isEmpty)
        XCTAssertTrue(undone.canRedo)

        let redone = try await service.performHistory(
            ProjectHistoryRequest(
                projectID: undone.id,
                expectedRevision: undone.revision,
                action: .redo
            )
        )
        XCTAssertEqual(redone.revision, 4)
        XCTAssertEqual(redone.content, edited.content)

        let exported = try await service.exportProject(
            ProjectExportRequest(
                projectID: redone.id,
                expectedRevision: redone.revision,
                fileName: "M1b Test"
            )
        )
        XCTAssertEqual(exported.pixelWidth, preview.pixelWidth)
        XCTAssertEqual(exported.pixelHeight, preview.pixelHeight)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.fileURL.path))
        let data = try Data(contentsOf: exported.fileURL)
        XCTAssertEqual(data.count, exported.byteCount)
        XCTAssertEqual(Self.sha256(data), exported.sha256)
        XCTAssertEqual(try Self.permissions(at: exported.fileURL), 0o600)
    }

    func testVersionConflictInvalidObjectsAndHistoryBoundaries() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)

        await assertThrowsErrorAsync(
            try await service.applyEdits(
                ProjectApplyEditsRequest(
                    projectID: created.id,
                    expectedRevision: 999,
                    commands: [.reset]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ScreenshotProjectServiceError,
                .versionConflict(expected: 999, actual: 1)
            )
        }

        await assertThrowsErrorAsync(
            try await service.applyEdits(
                ProjectApplyEditsRequest(
                    projectID: created.id,
                    expectedRevision: created.revision,
                    commands: [
                        .addObject(
                            .text(
                                TextEdit(
                                    frame: ImagePixelRect(x: 0, y: 0, width: 100, height: 30),
                                    text: "   "
                                )
                            )
                        )
                    ]
                )
            )
        ) { error in
            guard case .invalidEdit = error as? ScreenshotProjectServiceError else {
                return XCTFail("Expected invalidEdit, received \(error)")
            }
        }

        let unchanged = try await service.getProject(ProjectGetRequest(projectID: created.id))
        XCTAssertEqual(unchanged.revision, created.revision)
        XCTAssertEqual(unchanged.content, .empty)

        await assertThrowsErrorAsync(
            try await service.performHistory(
                ProjectHistoryRequest(
                    projectID: created.id,
                    expectedRevision: created.revision,
                    action: .undo
                )
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotProjectServiceError, .historyUnavailable(.undo))
        }
    }

    func testResetPersistsAndClearsRedoAfterNewEdit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)
        let arrow = ScreenshotEditObject.arrow(
            ArrowEdit(
                start: ImagePixelPoint(x: 20, y: 20),
                end: ImagePixelPoint(x: 120, y: 100)
            )
        )
        let edited = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                commands: [.addObject(arrow)]
            )
        )
        let undone = try await service.performHistory(
            ProjectHistoryRequest(
                projectID: edited.id,
                expectedRevision: edited.revision,
                action: .undo
            )
        )
        XCTAssertTrue(undone.canRedo)

        let replacement = ScreenshotEditObject.mosaic(
            MosaicEdit(frame: ImagePixelRect(x: 20, y: 20, width: 60, height: 50))
        )
        let replaced = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: undone.id,
                expectedRevision: undone.revision,
                commands: [.addObject(replacement)]
            )
        )
        XCTAssertFalse(replaced.canRedo)

        let reset = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: replaced.id,
                expectedRevision: replaced.revision,
                commands: [.reset]
            )
        )
        XCTAssertEqual(reset.content, .empty)

        let reloaded = try await ScreenshotProjectService(paths: fixture.paths).getProject(
            ProjectGetRequest(projectID: reset.id)
        )
        XCTAssertEqual(reloaded, reset)
    }

    func testRejectsSourcesOutsideCaptureDirectoryAndOversizedCanvas() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let outside = fixture.root.appendingPathComponent("outside.png")
        try FileManager.default.copyItem(at: fixture.captureURL, to: outside)
        let request = ProjectCreateRequest(
            sourceFileURL: outside,
            sourceSHA256: fixture.hash
        )

        await assertThrowsErrorAsync(try await service.createProject(request)) { error in
            XCTAssertEqual(
                error as? ScreenshotProjectServiceError,
                .sourceOutsideCaptureDirectory
            )
        }
        XCTAssertThrowsError(
            try ScreenshotProjectStore.validateCanvas(
                width: MupawConstants.maximumScreenshotPixelCount,
                height: 2
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotProjectServiceError, .canvasTooLarge)
        }
    }

    func testRejectsWrongHashAndDetectsTamperedOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let wrongHash = String(repeating: "0", count: 64)

        await assertThrowsErrorAsync(
            try await service.createProject(
                ProjectCreateRequest(
                    sourceFileURL: fixture.captureURL,
                    sourceSHA256: "not-a-sha256"
                )
            )
        ) { error in
            guard case .invalidEdit = error as? ScreenshotProjectServiceError else {
                return XCTFail("Expected invalidEdit, received \(error)")
            }
        }

        await assertThrowsErrorAsync(
            try await service.createProject(
                ProjectCreateRequest(
                    sourceFileURL: fixture.captureURL,
                    sourceSHA256: wrongHash
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ScreenshotProjectServiceError,
                .artifactHashMismatch(expected: wrongHash, actual: fixture.hash)
            )
        }

        let created = try await service.createProject(fixture.createRequest)
        var tamperedData = try Data(contentsOf: created.originalFileURL)
        tamperedData.append(0)
        try tamperedData.write(to: created.originalFileURL, options: .atomic)
        let tamperedHash = Self.sha256(tamperedData)
        let expectedError = ScreenshotProjectServiceError.artifactHashMismatch(
            expected: fixture.hash,
            actual: tamperedHash
        )

        await assertThrowsErrorAsync(
            try await service.getProject(ProjectGetRequest(projectID: created.id))
        ) { error in
            XCTAssertEqual(error as? ScreenshotProjectServiceError, expectedError)
        }
        await assertThrowsErrorAsync(
            try await service.previewProject(ProjectPreviewRequest(projectID: created.id))
        ) { error in
            XCTAssertEqual(error as? ScreenshotProjectServiceError, expectedError)
        }
        await assertThrowsErrorAsync(
            try await service.exportProject(ProjectExportRequest(projectID: created.id))
        ) { error in
            XCTAssertEqual(error as? ScreenshotProjectServiceError, expectedError)
        }
    }

    func testSetCropDecodingRequiresRectAndNullClearsCrop() throws {
        let missingRect = Data(#"{"type":"set_crop"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder.mupaw.decode(ProjectEditCommand.self, from: missingRect)
        ) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected keyNotFound, received \(error)")
            }
        }

        let clearCrop = Data(#"{"type":"set_crop","rect":null}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder.mupaw.decode(ProjectEditCommand.self, from: clearCrop),
            .setCrop(nil)
        )
    }

    func testObjectLimitHistoryBoundAndDirectoryPermissionRepair() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)

        let tooManyCommands = Array(
            repeating: ProjectEditCommand.reset,
            count: MupawConstants.maximumProjectCommandsPerBatch + 1
        )
        await assertThrowsErrorAsync(
            try await service.applyEdits(
                ProjectApplyEditsRequest(
                    projectID: created.id,
                    expectedRevision: created.revision,
                    commands: tooManyCommands
                )
            )
        ) { error in
            guard case .invalidEdit = error as? ScreenshotProjectServiceError else {
                return XCTFail("Expected invalidEdit, received \(error)")
            }
        }

        let tooManyObjects = (0...MupawConstants.maximumProjectObjects).map { index in
            ProjectEditCommand.addObject(
                .arrow(
                    ArrowEdit(
                        id: UUID().uuidString.lowercased(),
                        start: ImagePixelPoint(x: 10 + Double(index % 4), y: 10),
                        end: ImagePixelPoint(x: 30 + Double(index % 4), y: 30)
                    )
                )
            )
        }
        await assertThrowsErrorAsync(
            try await service.applyEdits(
                ProjectApplyEditsRequest(
                    projectID: created.id,
                    expectedRevision: created.revision,
                    commands: tooManyObjects
                )
            )
        ) { error in
            guard case .invalidEdit = error as? ScreenshotProjectServiceError else {
                return XCTFail("Expected invalidEdit, received \(error)")
            }
        }
        let unchanged = try await service.getProject(ProjectGetRequest(projectID: created.id))
        XCTAssertEqual(unchanged.revision, 1)
        XCTAssertEqual(unchanged.content, .empty)

        let projectDirectory = created.originalFileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: projectDirectory.path
        )
        var state = created
        for _ in 0..<55 {
            state = try await service.applyEdits(
                ProjectApplyEditsRequest(
                    projectID: state.id,
                    expectedRevision: state.revision,
                    commands: [.reset]
                )
            )
        }
        XCTAssertEqual(try Self.permissions(at: projectDirectory), 0o700)
        let stored = try ScreenshotProjectStore(paths: fixture.paths).load(projectID: state.id)
        XCTAssertEqual(stored.undoStack.count, MupawConstants.maximumProjectHistoryDepth)
        XCTAssertTrue(stored.redoStack.isEmpty)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}

private struct Fixture {
    let root: URL
    let paths: MupawPaths
    let captureURL: URL
    let hash: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MupawEditingTests-\(UUID().uuidString)", isDirectory: true)
        paths = MupawPaths(rootDirectory: root)
        try paths.prepare()
        captureURL = paths.capturesDirectory.appendingPathComponent("fixture.png")
        let data = try Self.makePNG(width: 320, height: 240)
        try data.write(to: captureURL, options: .atomic)
        hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var createRequest: ProjectCreateRequest {
        ProjectCreateRequest(
            sourceFileURL: captureURL,
            sourceSHA256: hash,
            sourceArtifactID: "fixture-artifact",
            title: "Fixture"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NSError(domain: "Fixture", code: 1)
        }
        context.setFillColor(CGColor(red: 0.10, green: 0.58, blue: 0.38, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.12, green: 0.22, blue: 0.72, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "Fixture", code: 2)
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                "public.png" as CFString,
                1,
                nil
            )
        else {
            throw NSError(domain: "Fixture", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Fixture", code: 4)
        }
        return data as Data
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
