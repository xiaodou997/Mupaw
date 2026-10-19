import Foundation
import XCTest

@testable import MupawCapture

final class RecordingAudioHealthPolicyTests: XCTestCase {
    func testMissingRequestedMicrophoneFailsAfterStartupDeadline() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let failure = RecordingAudioHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(4.1),
            systemAudio: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 12,
                lastSampleAt: startedAt.addingTimeInterval(4.0)
            ),
            microphone: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 0,
                lastSampleAt: nil
            )
        )

        XCTAssertEqual(failure, .missing(.microphone))
    }

    func testMissingSourceIsAllowedInsideStartupWindow() {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let failure = RecordingAudioHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(3.9),
            systemAudio: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 0,
                lastSampleAt: nil
            ),
            microphone: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 0,
                lastSampleAt: nil
            )
        )

        XCTAssertNil(failure)
    }

    func testRequestedMicrophoneStallIsDetectedRepeatably() {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let failure = RecordingAudioHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(8),
            systemAudio: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 300,
                lastSampleAt: startedAt.addingTimeInterval(7.9)
            ),
            microphone: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 140,
                lastSampleAt: startedAt.addingTimeInterval(4.9)
            )
        )

        XCTAssertEqual(failure, .stalled(.microphone))
    }

    func testUnrequestedLaneDoesNotFailHealthPolicy() {
        let startedAt = Date(timeIntervalSince1970: 4_000)
        let failure = RecordingAudioHealthPolicy.evaluate(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(30),
            systemAudio: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 1_000,
                lastSampleAt: startedAt.addingTimeInterval(29.9)
            ),
            microphone: RecordingAudioHealthObservation(
                requested: false,
                sampleBufferCount: 0,
                lastSampleAt: nil
            )
        )

        XCTAssertNil(failure)
    }

    func testHealthyMixedSourcesRemainActive() {
        let startedAt = Date(timeIntervalSince1970: 5_000)
        let now = startedAt.addingTimeInterval(45)
        let failure = RecordingAudioHealthPolicy.evaluate(
            startedAt: startedAt,
            now: now,
            systemAudio: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 2_000,
                lastSampleAt: now.addingTimeInterval(-0.02)
            ),
            microphone: RecordingAudioHealthObservation(
                requested: true,
                sampleBufferCount: 4_000,
                lastSampleAt: now.addingTimeInterval(-0.01)
            )
        )

        XCTAssertNil(failure)
    }
}
