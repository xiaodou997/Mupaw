import Foundation
import XCTest

@testable import MupawCore

final class ScreenshotRequestTests: XCTestCase {
    func testLegacyWindowRequestInfersModeAndDefaults() throws {
        let data = Data(
            """
            {"sourceID":"window:42","includeCursor":true,"fileName":"Legacy"}
            """.utf8
        )

        let request = try JSONDecoder.mupaw.decode(ScreenshotRequest.self, from: data)

        XCTAssertEqual(request.mode, .window)
        XCTAssertEqual(request.sourceID, "window:42")
        XCTAssertNil(request.region)
        XCTAssertEqual(request.format, .png)
        XCTAssertTrue(request.includeCursor)
        XCTAssertFalse(request.excludeMupawUI)
        XCTAssertEqual(request.fileName, "Legacy")
    }

    func testLegacyDisplayRequestInfersFullScreen() throws {
        let data = Data("{\"sourceID\":\"display:2\"}".utf8)

        let request = try JSONDecoder.mupaw.decode(ScreenshotRequest.self, from: data)

        XCTAssertEqual(request.mode, .fullScreen)
        XCTAssertEqual(request.sourceID, "display:2")
        XCTAssertFalse(request.excludeMupawUI)
    }

    func testStructuredRegionRoundTrip() throws {
        let request = ScreenshotRequest(
            mode: .region,
            region: CaptureRegion(
                rect: CaptureRect(x: -100, y: 40, width: 640, height: 360)
            ),
            includeCursor: true,
            excludeMupawUI: true,
            fileName: "Region"
        )

        let data = try JSONEncoder.mupaw.encode(request)
        let decoded = try JSONDecoder.mupaw.decode(ScreenshotRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testRegionWithoutExplicitModeInfersRegion() throws {
        let data = Data(
            """
            {
              "region": {
                "coordinateSpace": "global_display_points",
                "rect": {"x": 10, "y": 20, "width": 30, "height": 40}
              }
            }
            """.utf8
        )

        let request = try JSONDecoder.mupaw.decode(ScreenshotRequest.self, from: data)

        XCTAssertEqual(request.mode, .region)
        XCTAssertEqual(
            request.region,
            CaptureRegion(rect: CaptureRect(x: 10, y: 20, width: 30, height: 40))
        )
    }
}
