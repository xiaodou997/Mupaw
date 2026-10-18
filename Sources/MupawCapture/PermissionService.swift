import AVFoundation
import ApplicationServices
import CoreGraphics
import MupawCore

@MainActor
public final class PermissionService {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            screenCapture: CGPreflightScreenCaptureAccess() ? .authorized : .denied,
            microphone: Self.status(for: .audio),
            camera: Self.status(for: .video),
            accessibility: AXIsProcessTrusted() ? .authorized : .denied,
            inputMonitoring: CGPreflightListenEventAccess() ? .authorized : .denied
        )
    }

    @discardableResult
    public func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private static func status(for mediaType: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        @unknown default:
            return .unavailable
        }
    }
}
