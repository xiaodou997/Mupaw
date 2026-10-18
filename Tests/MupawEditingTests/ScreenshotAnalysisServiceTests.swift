import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest

@testable import MupawCore
@testable import MupawEditing

final class ScreenshotAnalysisServiceTests: XCTestCase {
    func testOCRMapsCoordinatesFiltersOrdersAndDoesNotMutateProject() async throws {
        let fixture = try AnalysisFixture()
        defer { fixture.cleanup() }
        let recognizer = StubTextRecognizer(
            observations: [
                RawOCRObservation(
                    text: "Bottom navigation",
                    confidence: 0.92,
                    normalizedBoundingBox: ImagePixelRect(x: 0.10, y: 0.10, width: 0.30, height: 0.10)
                ),
                RawOCRObservation(
                    text: "Top heading",
                    confidence: 0.83,
                    normalizedBoundingBox: ImagePixelRect(x: 0.20, y: 0.80, width: 0.40, height: 0.10)
                ),
                RawOCRObservation(
                    text: "Low confidence",
                    confidence: 0.10,
                    normalizedBoundingBox: ImagePixelRect(x: 0.10, y: 0.50, width: 0.20, height: 0.10)
                ),
                RawOCRObservation(
                    text: "   ",
                    confidence: 1,
                    normalizedBoundingBox: ImagePixelRect(x: 0.10, y: 0.60, width: 0.20, height: 0.10)
                ),
            ]
        )
        let service = ScreenshotProjectService(
            paths: fixture.paths,
            textRecognizer: recognizer
        )
        let created = try await service.createProject(fixture.createRequest)
        let documentURL = created.originalFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("project.json")
        let documentBefore = try Data(contentsOf: documentURL)

        let result = try await service.recognizeText(
            ProjectOCRRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                region: ImagePixelRect(x: 20, y: 30, width: 200, height: 120),
                recognitionLevel: .accurate,
                recognitionLanguages: ["en-US", "zh-Hans", "en-US"],
                usesLanguageCorrection: false,
                minimumConfidence: 0.5
            )
        )

        XCTAssertEqual(result.projectID, created.id)
        XCTAssertEqual(result.projectRevision, 1)
        XCTAssertEqual(result.source, .original)
        XCTAssertEqual(result.recognitionLanguages, ["en-US", "zh-Hans"])
        XCTAssertEqual(result.recognitionEngine, .visionAccurate)
        XCTAssertEqual(result.effectiveRecognitionLanguages, ["en-US", "zh-Hans"])
        XCTAssertFalse(result.usesLanguageCorrection)
        XCTAssertEqual(result.fullText, "Top heading\nBottom navigation")
        XCTAssertEqual(result.observations.map(\.text), ["Top heading", "Bottom navigation"])
        XCTAssertEqual(result.observations.map(\.id), ["ocr-0001", "ocr-0002"])
        XCTAssertEqual(result.observations.map(\.language), ["en", "en"])
        XCTAssertEqual(result.detectedLanguages, ["en"])

        let top = try XCTUnwrap(result.observations.first)
        XCTAssertEqual(top.boundingBox.x, 60, accuracy: 0.001)
        XCTAssertEqual(top.boundingBox.y, 42, accuracy: 0.001)
        XCTAssertEqual(top.boundingBox.width, 80, accuracy: 0.001)
        XCTAssertEqual(top.boundingBox.height, 12, accuracy: 0.001)

        let bottom = try XCTUnwrap(result.observations.last)
        XCTAssertEqual(bottom.boundingBox.x, 40, accuracy: 0.001)
        XCTAssertEqual(bottom.boundingBox.y, 126, accuracy: 0.001)
        XCTAssertEqual(bottom.boundingBox.width, 60, accuracy: 0.001)
        XCTAssertEqual(bottom.boundingBox.height, 12, accuracy: 0.001)

        XCTAssertEqual(try Data(contentsOf: documentURL), documentBefore)
        let reloaded = try await service.getProject(ProjectGetRequest(projectID: created.id))
        XCTAssertEqual(reloaded, created)
    }

    func testPointAndRegionColorSamplingUseOriginalSRGBPixels() async throws {
        let fixture = try AnalysisFixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(paths: fixture.paths)
        let created = try await service.createProject(fixture.createRequest)

        let left = try await service.sampleColor(
            ProjectColorSampleRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                mode: .point,
                point: ImagePixelPoint(x: 40, y: 120)
            )
        )
        XCTAssertEqual(left.mode, .point)
        XCTAssertEqual(left.sampledPixelCount, 1)
        XCTAssertEqual(left.primaryColor.hexRGB, "#1F38B8")
        XCTAssertEqual(left.primaryColor.rgba.red, 0.12, accuracy: 0.01)
        XCTAssertEqual(left.primaryColor.rgba.green, 0.22, accuracy: 0.01)
        XCTAssertEqual(left.primaryColor.rgba.blue, 0.72, accuracy: 0.01)
        XCTAssertNil(left.averageColor)

        let right = try await service.sampleColor(
            ProjectColorSampleRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                mode: .point,
                point: ImagePixelPoint(x: 240, y: 120)
            )
        )
        XCTAssertEqual(right.primaryColor.hexRGB, "#1A9461")

        let region = try await service.sampleColor(
            ProjectColorSampleRequest(
                projectID: created.id,
                expectedRevision: created.revision,
                mode: .region,
                region: created.originalBounds
            )
        )
        let average = try XCTUnwrap(region.averageColor)
        XCTAssertEqual(region.primaryColor, average)
        XCTAssertEqual(region.sampledPixelCount, 256 * 192)
        XCTAssertLessThanOrEqual(
            region.sampledPixelCount,
            MupawConstants.maximumColorSamplePixels
        )
        XCTAssertEqual(average.rgba.red, 0.11, accuracy: 0.02)
        XCTAssertEqual(average.rgba.green, 0.40, accuracy: 0.02)
        XCTAssertEqual(average.rgba.blue, 0.55, accuracy: 0.02)
        XCTAssertEqual(region.centerColor?.hexRGB, right.primaryColor.hexRGB)
        XCTAssertNotNil(region.dominantColor)
        XCTAssertEqual(region.projectRevision, created.revision)

        let reloaded = try await service.getProject(ProjectGetRequest(projectID: created.id))
        XCTAssertEqual(reloaded, created)
    }

    func testAnalysisValidationRevisionAndOriginalIntegrity() async throws {
        let fixture = try AnalysisFixture()
        defer { fixture.cleanup() }
        let service = ScreenshotProjectService(
            paths: fixture.paths,
            textRecognizer: StubTextRecognizer(observations: [])
        )
        let created = try await service.createProject(fixture.createRequest)

        await assertAnalysisThrows(
            try await service.recognizeText(
                ProjectOCRRequest(
                    projectID: created.id,
                    expectedRevision: created.revision,
                    minimumConfidence: 1.1
                )
            ),
            matching: { error in
                guard case .invalidAnalysis = error as? ScreenshotProjectServiceError else {
                    return false
                }
                return true
            }
        )

        await assertAnalysisThrows(
            try await service.recognizeText(
                ProjectOCRRequest(
                    projectID: created.id,
                    recognitionLanguages: Array(repeating: "en-US", count: 9)
                )
            ),
            matching: { error in
                guard case .invalidAnalysis = error as? ScreenshotProjectServiceError else {
                    return false
                }
                return true
            }
        )

        await assertAnalysisThrows(
            try await service.sampleColor(
                ProjectColorSampleRequest(
                    projectID: created.id,
                    mode: .point,
                    point: ImagePixelPoint(x: 320, y: 10)
                )
            ),
            matching: { error in
                guard case .invalidAnalysis = error as? ScreenshotProjectServiceError else {
                    return false
                }
                return true
            }
        )

        await assertAnalysisThrows(
            try await service.sampleColor(
                ProjectColorSampleRequest(
                    projectID: created.id,
                    mode: .region,
                    point: ImagePixelPoint(x: 10, y: 10),
                    region: ImagePixelRect(x: 0, y: 0, width: 20, height: 20)
                )
            ),
            matching: { error in
                guard case .invalidAnalysis = error as? ScreenshotProjectServiceError else {
                    return false
                }
                return true
            }
        )

        await assertAnalysisThrows(
            try await service.sampleColor(
                ProjectColorSampleRequest(
                    projectID: created.id,
                    expectedRevision: 999,
                    mode: .point,
                    point: ImagePixelPoint(x: 10, y: 10)
                )
            ),
            matching: { error in
                error as? ScreenshotProjectServiceError
                    == .versionConflict(expected: 999, actual: 1)
            }
        )

        var tamperedData = try Data(contentsOf: created.originalFileURL)
        tamperedData.append(0)
        try tamperedData.write(to: created.originalFileURL, options: .atomic)
        let tamperedHash = AnalysisFixture.sha256(tamperedData)
        let expected = ScreenshotProjectServiceError.artifactHashMismatch(
            expected: fixture.hash,
            actual: tamperedHash
        )

        await assertAnalysisThrows(
            try await service.recognizeText(ProjectOCRRequest(projectID: created.id)),
            matching: { $0 as? ScreenshotProjectServiceError == expected }
        )
        await assertAnalysisThrows(
            try await service.sampleColor(
                ProjectColorSampleRequest(
                    projectID: created.id,
                    mode: .point,
                    point: ImagePixelPoint(x: 10, y: 10)
                )
            ),
            matching: { $0 as? ScreenshotProjectServiceError == expected }
        )
    }

    func testAnalysisRequestDefaultsAndSampledColorMetadata() throws {
        let request = try JSONDecoder.mupaw.decode(
            ProjectOCRRequest.self,
            from: Data(#"{"project_id":"abc"}"#.utf8)
        )
        XCTAssertEqual(request.projectID, "abc")
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertEqual(request.recognitionLanguages, [])
        XCTAssertTrue(request.usesLanguageCorrection)
        XCTAssertEqual(request.minimumConfidence, 0)

        let black = SampledColor(rgba: .black)
        XCTAssertEqual(black.hexRGB, "#000000")
        XCTAssertEqual(black.hexRGBA, "#000000FF")
        XCTAssertTrue(black.isDark)
        XCTAssertEqual(black.relativeLuminance, 0, accuracy: 0.0001)

        let white = SampledColor(rgba: .white)
        XCTAssertEqual(white.hexRGB, "#FFFFFF")
        XCTAssertFalse(white.isDark)
        XCTAssertEqual(white.relativeLuminance, 1, accuracy: 0.0001)
    }
}

private struct StubTextRecognizer: ScreenshotTextRecognizing {
    let observations: [RawOCRObservation]
    let engine: OCRRecognitionEngine = .visionAccurate
    let effectiveLanguages = ["en-US", "zh-Hans"]

    func recognizeText(
        in image: CGImage,
        level: OCRRecognitionLevel,
        languages: [String],
        usesLanguageCorrection: Bool
    ) async throws -> RawOCRRecognitionResult {
        RawOCRRecognitionResult(
            engine: engine,
            effectiveLanguages: effectiveLanguages,
            observations: observations
        )
    }
}

private struct AnalysisFixture {
    let root: URL
    let paths: MupawPaths
    let captureURL: URL
    let hash: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MupawAnalysisTests-\(UUID().uuidString)", isDirectory: true)
        paths = MupawPaths(rootDirectory: root)
        try paths.prepare()
        captureURL = paths.capturesDirectory.appendingPathComponent("analysis-fixture.png")
        let data = try Self.makePNG(width: 320, height: 240)
        try data.write(to: captureURL, options: .atomic)
        hash = Self.sha256(data)
    }

    var createRequest: ProjectCreateRequest {
        ProjectCreateRequest(
            sourceFileURL: captureURL,
            sourceSHA256: hash,
            sourceArtifactID: "analysis-fixture",
            title: "Analysis Fixture"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            throw NSError(domain: "AnalysisFixture", code: 1)
        }
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [0.10, 0.58, 0.38, 1]
            ) ?? CGColor(gray: 0, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [0.12, 0.22, 0.72, 1]
            ) ?? CGColor(gray: 0, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "AnalysisFixture", code: 2)
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
            throw NSError(domain: "AnalysisFixture", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "AnalysisFixture", code: 4)
        }
        return data as Data
    }
}

private func assertAnalysisThrows<T>(
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
