import Foundation
import XCTest

@testable import MupawCore

final class CaptureGeometryTests: XCTestCase {
    func testStandardizesAndIntersectsRects() {
        let reversed = CaptureRect(x: 20, y: 30, width: -10, height: -20)
        XCTAssertEqual(
            reversed.standardized,
            CaptureRect(x: 10, y: 10, width: 10, height: 20)
        )
        XCTAssertEqual(
            reversed.intersection(CaptureRect(x: 15, y: 0, width: 20, height: 20)),
            CaptureRect(x: 15, y: 10, width: 5, height: 10)
        )
        XCTAssertNil(reversed.intersection(CaptureRect(x: 100, y: 100, width: 10, height: 10)))
    }

    func testAppKitAndGlobalDisplayCoordinatesRoundTrip() {
        let appKitRect = CaptureRect(x: -500, y: 100, width: 200, height: 150)
        let globalRect = GlobalDisplayCoordinateMapper.appKitToGlobalDisplay(
            appKitRect,
            primaryScreenMaxY: 900
        )

        XCTAssertEqual(globalRect, CaptureRect(x: -500, y: 650, width: 200, height: 150))
        XCTAssertEqual(
            GlobalDisplayCoordinateMapper.globalDisplayToAppKit(
                globalRect,
                primaryScreenMaxY: 900
            ),
            appKitRect
        )
    }

    func testPlansSingleRetinaDisplayRegion() throws {
        let region = CaptureRegion(
            rect: CaptureRect(x: 100, y: 50, width: 200, height: 100)
        )
        let display = CaptureDisplayGeometry(
            sourceID: "display:1",
            framePoints: CaptureRect(x: 0, y: 0, width: 1_440, height: 900),
            pointPixelScale: 2
        )

        let plan = try RegionCapturePlanner.makePlan(region: region, displays: [display])

        XCTAssertEqual(plan.outputPixelWidth, 400)
        XCTAssertEqual(plan.outputPixelHeight, 200)
        XCTAssertEqual(plan.outputPointPixelScale, 2)
        XCTAssertEqual(
            plan.slices,
            [
                RegionCaptureSlice(
                    sourceID: "display:1",
                    sourceRectPoints: CaptureRect(x: 100, y: 50, width: 200, height: 100),
                    destinationPixelRect: CapturePixelRect(x: 0, y: 0, width: 400, height: 200)
                )
            ]
        )
    }

    func testPlansCrossDisplayRegionAtHighestScale() throws {
        let region = CaptureRegion(
            rect: CaptureRect(x: 900, y: 100, width: 300, height: 200)
        )
        let displays = [
            CaptureDisplayGeometry(
                sourceID: "display:retina",
                framePoints: CaptureRect(x: 0, y: 0, width: 1_000, height: 800),
                pointPixelScale: 2
            ),
            CaptureDisplayGeometry(
                sourceID: "display:standard",
                framePoints: CaptureRect(x: 1_000, y: 0, width: 1_000, height: 800),
                pointPixelScale: 1
            ),
        ]

        let plan = try RegionCapturePlanner.makePlan(region: region, displays: displays)

        XCTAssertEqual(plan.outputPixelWidth, 600)
        XCTAssertEqual(plan.outputPixelHeight, 400)
        XCTAssertEqual(plan.outputPointPixelScale, 2)
        XCTAssertEqual(plan.slices.count, 2)
        XCTAssertEqual(
            plan.slices[0],
            RegionCaptureSlice(
                sourceID: "display:retina",
                sourceRectPoints: CaptureRect(x: 900, y: 100, width: 100, height: 200),
                destinationPixelRect: CapturePixelRect(x: 0, y: 0, width: 200, height: 400)
            )
        )
        XCTAssertEqual(
            plan.slices[1],
            RegionCaptureSlice(
                sourceID: "display:standard",
                sourceRectPoints: CaptureRect(x: 0, y: 100, width: 200, height: 200),
                destinationPixelRect: CapturePixelRect(x: 200, y: 0, width: 400, height: 400)
            )
        )
    }

    func testRejectsInvalidOutsideAndOversizedRegions() {
        let display = CaptureDisplayGeometry(
            sourceID: "display:1",
            framePoints: CaptureRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 2
        )

        XCTAssertThrowsError(
            try RegionCapturePlanner.makePlan(
                region: CaptureRegion(rect: CaptureRect(x: 0, y: 0, width: 0, height: 20)),
                displays: [display]
            )
        ) { error in
            XCTAssertEqual(error as? RegionCapturePlanningError, .invalidRegion)
        }

        XCTAssertThrowsError(
            try RegionCapturePlanner.makePlan(
                region: CaptureRegion(rect: CaptureRect(x: 200, y: 200, width: 20, height: 20)),
                displays: [display]
            )
        ) { error in
            XCTAssertEqual(error as? RegionCapturePlanningError, .noDisplayIntersection)
        }

        XCTAssertThrowsError(
            try RegionCapturePlanner.makePlan(
                region: CaptureRegion(rect: CaptureRect(x: 0, y: 0, width: 100, height: 100)),
                displays: [display],
                maximumPixelCount: 10
            )
        ) { error in
            XCTAssertEqual(error as? RegionCapturePlanningError, .outputTooLarge)
        }
    }
}
