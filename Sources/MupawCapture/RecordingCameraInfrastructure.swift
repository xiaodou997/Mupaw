import Foundation
import MupawCore

enum RecordingCameraHealthFailure: Sendable, Equatable {
    case missing
    case stalled
}

struct RecordingCameraHealthObservation: Sendable, Equatable {
    let requested: Bool
    let frameCount: Int
    let lastFrameAt: Date?
}

enum RecordingCameraHealthPolicy {
    static func evaluate(
        startedAt: Date,
        now: Date,
        observation: RecordingCameraHealthObservation
    ) -> RecordingCameraHealthFailure? {
        guard observation.requested else { return nil }
        if observation.frameCount == 0,
            now.timeIntervalSince(startedAt)
                >= MupawConstants.recordingCameraStartupTimeoutSeconds
        {
            return .missing
        }
        if observation.frameCount > 0,
            let lastFrameAt = observation.lastFrameAt,
            now.timeIntervalSince(lastFrameAt)
                >= MupawConstants.recordingCameraSourceStallSeconds
        {
            return .stalled
        }
        return nil
    }
}

struct RecordingCameraControlEvent: Sendable, Equatable {
    let elapsedSeconds: Double
    let configuration: RecordingCameraOverlayConfiguration
}

struct RecordingCameraMetrics: Sendable, Equatable {
    let requested: Bool
    let configuration: RecordingCameraOverlayConfiguration
    let controlEvents: [RecordingCameraControlEvent]
    let frameCount: Int
    let lastFrameAt: Date?
    let lastSourceTimestampSeconds: Double?
    let sourcePixelWidth: Int?
    let sourcePixelHeight: Int?

    static let disabled = RecordingCameraMetrics(
        requested: false,
        configuration: .disabled,
        controlEvents: [],
        frameCount: 0,
        lastFrameAt: nil,
        lastSourceTimestampSeconds: nil,
        sourcePixelWidth: nil,
        sourcePixelHeight: nil
    )
}
