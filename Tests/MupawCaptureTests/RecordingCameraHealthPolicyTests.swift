import Foundation
import XCTest

@testable import MupawCapture

final class RecordingCameraHealthPolicyTests: XCTestCase {
    func testUnrequestedCameraNeverFails() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let failure = RecordingCameraHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(60),
            observation: RecordingCameraHealthObservation(
                requested: false,
                frameCount: 0,
                lastFrameAt: nil
            )
        )
        XCTAssertNil(failure)
    }

    func testMissingCameraIsAllowedInsideStartupWindow() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let failure = RecordingCameraHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(3.9),
            observation: RecordingCameraHealthObservation(
                requested: true,
                frameCount: 0,
                lastFrameAt: nil
            )
        )
        XCTAssertNil(failure)
    }

    func testMissingCameraFailsAfterStartupDeadline() {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let failure = RecordingCameraHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(4.1),
            observation: RecordingCameraHealthObservation(
                requested: true,
                frameCount: 0,
                lastFrameAt: nil
            )
        )
        XCTAssertEqual(failure, .missing)
    }

    func testCameraStallIsDetected() {
        let startedAt = Date(timeIntervalSince1970: 4_000)
        let failure = RecordingCameraHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(10),
            observation: RecordingCameraHealthObservation(
                requested: true,
                frameCount: 120,
                lastFrameAt: startedAt.addingTimeInterval(6.9)
            )
        )
        XCTAssertEqual(failure, .stalled)
    }

    func testHealthyCameraRemainsActive() {
        let startedAt = Date(timeIntervalSince1970: 5_000)
        let now = startedAt.addingTimeInterval(30)
        let failure = RecordingCameraHealthPolicy.evaluate(
            startedAt: startedAt,
            now: now,
            observation: RecordingCameraHealthObservation(
                requested: true,
                frameCount: 900,
                lastFrameAt: now.addingTimeInterval(-0.03)
            )
        )
        XCTAssertNil(failure)
    }
}
