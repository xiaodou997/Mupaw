import Foundation
import XCTest

@testable import MupawCore

final class RecordingModelTests: XCTestCase {
    func testRecordingRequestRoundTripAndDefaults() throws {
        let request = RecordingRequest(
            mode: .region,
            region: CaptureRegion(
                rect: CaptureRect(x: 120, y: 80, width: 960, height: 540)
            ),
            frameRate: 30,
            quality: .high,
            includeCursor: true,
            fileName: "Demo"
        )

        let data = try JSONEncoder.mupaw.encode(request)
        let decoded = try JSONDecoder.mupaw.decode(RecordingRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.format, .mp4)
        XCTAssertEqual(decoded.region?.coordinateSpace, .globalDisplayPoints)
    }

    func testResolutionPlannerPreservesAspectAndBoundsSixK() throws {
        let landscape = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 6_016,
            sourcePixelHeight: 3_384
        )
        XCTAssertEqual(landscape, RecordingResolution(pixelWidth: 3_840, pixelHeight: 2_160))

        let portrait = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 3_384,
            sourcePixelHeight: 6_016
        )
        XCTAssertEqual(portrait, RecordingResolution(pixelWidth: 2_160, pixelHeight: 3_840))
    }

    func testResolutionPlannerUsesEvenDimensionsAndPixelLimit() throws {
        let small = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 1_001,
            sourcePixelHeight: 777
        )
        XCTAssertTrue(small.pixelWidth.isMultiple(of: 2))
        XCTAssertTrue(small.pixelHeight.isMultiple(of: 2))
        XCTAssertLessThanOrEqual(
            small.pixelWidth * small.pixelHeight,
            MupawConstants.maximumRecordingPixelCount
        )

        let square = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 10_000,
            sourcePixelHeight: 10_000
        )
        XCTAssertTrue(square.pixelWidth.isMultiple(of: 2))
        XCTAssertTrue(square.pixelHeight.isMultiple(of: 2))
        XCTAssertLessThanOrEqual(
            square.pixelWidth * square.pixelHeight,
            MupawConstants.maximumRecordingPixelCount
        )
    }

    func testResolutionPlannerRejectsInvalidSources() {
        XCTAssertThrowsError(
            try RecordingResolutionPlanner.makeResolution(
                sourcePixelWidth: 0,
                sourcePixelHeight: 1_080
            )
        ) { error in
            XCTAssertEqual(error as? RecordingResolutionPlanningError, .invalidSourceSize)
        }
    }

    func testQualityBitrateIsBoundedAndHighIsLarger() {
        let standard = RecordingVideoQuality.standard.estimatedBitRate(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            frameRate: 30
        )
        let high = RecordingVideoQuality.high.estimatedBitRate(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            frameRate: 30
        )
        XCTAssertGreaterThan(high, standard)
        XCTAssertGreaterThanOrEqual(standard, MupawConstants.minimumRecordingBitRate)
        XCTAssertLessThanOrEqual(high, MupawConstants.maximumRecordingBitRate)
    }

    func testPathsPrepareOwnerOnlyRecordingsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MupawRecordingPaths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MupawPaths(rootDirectory: root)

        try paths.prepare()

        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.recordingsDirectory.path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }
}
