import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest

@testable import MupawCore
@testable import MupawEditing

final class ScreenshotVisualStyleTests: XCTestCase {
    func testCustomStyleUsesSharedPreviewExportRendererAndPreservesOriginal() async throws {
        let fixture = try StyleFixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)
        let originalBefore = try Data(contentsOf: created.originalFileURL)

        let style = ScreenshotVisualStyle(
            background: ScreenshotBackgroundStyle(
                startColor: RGBAColor(red: 0.95, green: 0.15, blue: 0.20, alpha: 1)
            ),
            padding: 20,
            cornerRadius: 0,
            shadow: ScreenshotShadowStyle(isEnabled: false),
            canvasAspect: .automatic
        )
        let styled = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                commands: [.setVisualStyle(style)]
            )
        )
        XCTAssertEqual(styled.revision, 2)
        XCTAssertEqual(styled.content.visualStyle, style)

        let preview = try await service.previewProject(
            ProjectPreviewRequest(projectID: styled.id, expectedRevision: styled.revision)
        )
        let export = try await service.exportProject(
            ProjectExportRequest(
                projectID: styled.id,
                expectedRevision: styled.revision,
                fileName: "M1d Style Test"
            )
        )
        XCTAssertEqual(preview.pixelWidth, 360)
        XCTAssertEqual(preview.pixelHeight, 280)
        XCTAssertEqual(export.pixelWidth, preview.pixelWidth)
        XCTAssertEqual(export.pixelHeight, preview.pixelHeight)

        let outputData = try Data(contentsOf: export.fileURL)
        XCTAssertEqual(StyleFixture.sha256(outputData), export.sha256)
        XCTAssertEqual(try Data(contentsOf: created.originalFileURL), originalBefore)

        let output = try XCTUnwrap(StyleFixture.image(from: outputData))
        let background = try StyleFixture.color(in: output, x: 2, y: 2)
        XCTAssertEqual(background.red, 0.95, accuracy: 0.03)
        XCTAssertEqual(background.green, 0.15, accuracy: 0.03)
        let sourceLeft = try StyleFixture.color(in: output, x: 40, y: 120)
        XCTAssertEqual(sourceLeft.blue, 0.72, accuracy: 0.03)
        let sourceRight = try StyleFixture.color(in: output, x: 300, y: 120)
        XCTAssertEqual(sourceRight.green, 0.58, accuracy: 0.03)
    }

    func testPresetUndoRedoClearAndResetAreRevisioned() async throws {
        let fixture = try StyleFixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)

        let preset = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                commands: [.applyStylePreset(.ocean)]
            )
        )
        XCTAssertEqual(preset.content.visualStyle, ScreenshotStylePreset.ocean.style)

        let undone = try await service.performHistory(
            ProjectHistoryRequest(
                projectID: preset.id,
                expectedRevision: preset.revision,
                action: .undo
            )
        )
        XCTAssertNil(undone.content.visualStyle)

        let redone = try await service.performHistory(
            ProjectHistoryRequest(
                projectID: undone.id,
                expectedRevision: undone.revision,
                action: .redo
            )
        )
        XCTAssertEqual(redone.content.visualStyle, ScreenshotStylePreset.ocean.style)

        let cleared = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: redone.id,
                expectedRevision: redone.revision,
                commands: [.clearVisualStyle]
            )
        )
        XCTAssertNil(cleared.content.visualStyle)

        let restyled = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: cleared.id,
                expectedRevision: cleared.revision,
                commands: [.applyStylePreset(.midnight)]
            )
        )
        let reset = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: restyled.id,
                expectedRevision: restyled.revision,
                commands: [.reset]
            )
        )
        XCTAssertEqual(reset.content, .empty)
    }

    func testInvalidStyleRejectsAtomicBatchWithoutRevisionChange() async throws {
        let fixture = try StyleFixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)
        var invalid = ScreenshotStylePreset.cleanWhite.style!
        invalid.padding = MupawConstants.maximumStylePadding + 1

        await assertStyleThrows(
            try await service.applyEdits(
                ProjectApplyEditsRequest(
                    projectID: created.id,
                    expectedRevision: created.revision,
                    commands: [
                        .setCrop(ImagePixelRect(x: 20, y: 20, width: 200, height: 100)),
                        .setVisualStyle(invalid),
                    ]
                )
            )
        ) { error in
            guard case .invalidEdit = error as? ScreenshotProjectServiceError else { return false }
            return true
        }

        let unchanged = try await service.getProject(ProjectGetRequest(projectID: created.id))
        XCTAssertEqual(unchanged.revision, created.revision)
        XCTAssertEqual(unchanged.content, .empty)
    }

    func testRoundedCardKeepsBackgroundVisibleAtCardCorner() async throws {
        let fixture = try StyleFixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)
        let style = ScreenshotVisualStyle(
            background: ScreenshotBackgroundStyle(startColor: .white),
            padding: 20,
            cornerRadius: 40,
            shadow: ScreenshotShadowStyle(isEnabled: false)
        )
        let state = try await service.applyEdits(
            ProjectApplyEditsRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                commands: [.setVisualStyle(style)]
            )
        )
        let export = try await service.exportProject(
            ProjectExportRequest(projectID: state.id, expectedRevision: state.revision)
        )
        let image = try XCTUnwrap(StyleFixture.image(from: Data(contentsOf: export.fileURL)))

        let roundedCorner = try StyleFixture.color(in: image, x: 20, y: 20)
        XCTAssertEqual(roundedCorner.red, 1, accuracy: 0.03)
        XCTAssertEqual(roundedCorner.green, 1, accuracy: 0.03)
        XCTAssertEqual(roundedCorner.blue, 1, accuracy: 0.03)
        let cardCenter = try StyleFixture.color(in: image, x: 180, y: 140)
        XCTAssertLessThan(cardCenter.red, 0.3)
    }
}

private struct StyleFixture {
    let root: URL
    let paths: MupawPaths
    let captureURL: URL
    let hash: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MupawStyleTests-\(UUID().uuidString)", isDirectory: true)
        paths = MupawPaths(rootDirectory: root)
        try paths.prepare()
        captureURL = paths.capturesDirectory.appendingPathComponent("style-fixture.png")
        let data = try Self.makePNG(width: 320, height: 240)
        try data.write(to: captureURL, options: .atomic)
        hash = Self.sha256(data)
    }

    var createRequest: ProjectCreateRequest {
        ProjectCreateRequest(
            sourceFileURL: captureURL,
            sourceSHA256: hash,
            sourceArtifactID: "style-fixture",
            title: "Style Fixture"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func color(in image: CGImage, x: Int, y: Int) throws -> RGBAColor {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let created = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:
                        CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard created else { throw NSError(domain: "StyleFixture", code: 10) }
        let safeX = min(max(0, x), image.width - 1)
        let safeY = min(max(0, y), image.height - 1)
        let index = (safeY * image.width + safeX) * 4
        let alpha = Double(bytes[index + 3]) / 255
        guard alpha > 0 else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
        return RGBAColor(
            red: min(1, Double(bytes[index]) / 255 / alpha),
            green: min(1, Double(bytes[index + 1]) / 255 / alpha),
            blue: min(1, Double(bytes[index + 2]) / 255 / alpha),
            alpha: alpha
        )
    }

    private static func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NSError(domain: "StyleFixture", code: 1)
        }
        context.setFillColor(
            CGColor(colorSpace: colorSpace, components: [0.12, 0.22, 0.72, 1])!
        )
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(
            CGColor(colorSpace: colorSpace, components: [0.10, 0.58, 0.38, 1])!
        )
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "StyleFixture", code: 2)
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
            throw NSError(domain: "StyleFixture", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "StyleFixture", code: 4)
        }
        return data as Data
    }
}

private func assertStyleThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    matching predicate: (Error) -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        XCTAssertTrue(predicate(error), "Unexpected error: \(error)", file: file, line: line)
    }
}
