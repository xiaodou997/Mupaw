import Foundation
import XCTest

@testable import MupawCore

final class VisualStyleModelTests: XCTestCase {
    func testLegacyProjectContentDecodesWithoutVisualStyle() throws {
        let data = Data(#"{"cropRect":null,"objects":[]}"#.utf8)

        let content = try JSONDecoder.mupaw.decode(ScreenshotProjectContent.self, from: data)

        XCTAssertEqual(content, .empty)
        XCTAssertNil(content.visualStyle)
    }

    func testVisualStyleAndCommandsRoundTrip() throws {
        let style = ScreenshotVisualStyle(
            background: ScreenshotBackgroundStyle(
                mode: .linearGradient,
                startColor: RGBAColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1),
                endColor: RGBAColor(red: 0.1, green: 0.8, blue: 0.7, alpha: 1),
                angleDegrees: 32
            ),
            padding: 120,
            cornerRadius: 36,
            shadow: ScreenshotShadowStyle(
                color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.35),
                blurRadius: 48,
                offsetX: 4,
                offsetY: 20
            ),
            canvasAspect: .landscapeSixteenNine
        )
        let content = ScreenshotProjectContent(visualStyle: style)

        let encoded = try JSONEncoder.mupaw.encode(content)
        XCTAssertEqual(try JSONDecoder.mupaw.decode(ScreenshotProjectContent.self, from: encoded), content)

        let commands: [ProjectEditCommand] = [
            .setVisualStyle(style),
            .applyStylePreset(.sunset),
            .clearVisualStyle,
        ]
        for command in commands {
            let data = try JSONEncoder.mupaw.encode(command)
            XCTAssertEqual(try JSONDecoder.mupaw.decode(ProjectEditCommand.self, from: data), command)
        }
    }

    func testAutomaticLayoutIncludesPaddingAndShadowExtents() throws {
        let style = ScreenshotVisualStyle(
            background: ScreenshotBackgroundStyle(startColor: .white),
            padding: 40,
            cornerRadius: 10,
            shadow: ScreenshotShadowStyle(
                blurRadius: 10,
                offsetX: 5,
                offsetY: 8
            )
        )

        let layout = try ScreenshotStyleLayoutPlanner.makeLayout(
            contentPixelWidth: 320,
            contentPixelHeight: 240,
            style: style
        )

        XCTAssertEqual(layout.outputPixelWidth, 440)
        XCTAssertEqual(layout.outputPixelHeight, 360)
        XCTAssertEqual(layout.cardFrame, ImagePixelRect(x: 55, y: 52, width: 320, height: 240))
    }

    func testAspectRatioExpandsCanvasWithoutMovingCardOffCenter() throws {
        var style = ScreenshotStylePreset.cleanWhite.style!
        style.padding = 40
        style.shadow.isEnabled = false
        style.canvasAspect = .square

        let layout = try ScreenshotStyleLayoutPlanner.makeLayout(
            contentPixelWidth: 320,
            contentPixelHeight: 240,
            style: style
        )

        XCTAssertEqual(layout.outputPixelWidth, 400)
        XCTAssertEqual(layout.outputPixelHeight, 400)
        XCTAssertEqual(layout.cardFrame, ImagePixelRect(x: 40, y: 80, width: 320, height: 240))
    }

    func testPresetsAreStructuredAndNoneClearsStyle() {
        XCTAssertNil(ScreenshotStylePreset.none.style)
        for preset in ScreenshotStylePreset.allCases where preset != .none {
            let style = preset.style
            XCTAssertNotNil(style)
            XCTAssertTrue(style?.background.startColor.isFiniteAndNormalized == true)
            XCTAssertGreaterThan(style?.padding ?? 0, 0)
        }
    }

    func testLayoutRejectsUnboundedOutput() {
        var style = ScreenshotStylePreset.cleanWhite.style!
        style.padding = MupawConstants.maximumStylePadding
        style.canvasAspect = .portraitNineSixteen

        XCTAssertThrowsError(
            try ScreenshotStyleLayoutPlanner.makeLayout(
                contentPixelWidth: 20_000,
                contentPixelHeight: 20_000,
                style: style,
                maximumPixelCount: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotStyleLayoutPlanningError, .outputTooLarge)
        }
    }
}
