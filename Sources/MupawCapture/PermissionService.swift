import AVFoundation
import ApplicationServices
import CoreGraphics
import MupawCore

@MainActor
public final class PermissionService {
    private static let snapshotCacheDuration: TimeInterval = 1

    private var cachedSnapshot: PermissionSnapshot?
    private var cachedAtUptime: TimeInterval?

    public init() {}

    public func snapshot(forceRefresh: Bool = false) -> PermissionSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
            let cachedSnapshot,
            let cachedAtUptime,
            now - cachedAtUptime < Self.snapshotCacheDuration
        {
            return cachedSnapshot
        }

        let snapshot = PermissionSnapshot(
            screenCapture: CGPreflightScreenCaptureAccess() ? .authorized : .denied,
            microphone: Self.status(for: .audio),
            camera: Self.status(for: .video),
            accessibility: AXIsProcessTrusted() ? .authorized : .denied,
            inputMonitoring: CGPreflightListenEventAccess() ? .authorized : .denied
        )
        cachedSnapshot = snapshot
        cachedAtUptime = now
        return snapshot
    }

    public func invalidateCache() {
        cachedSnapshot = nil
        cachedAtUptime = nil
    }

    @discardableResult
    public func requestScreenCaptureAccess() -> Bool {
        invalidateCache()
        let granted = CGRequestScreenCaptureAccess()
        invalidateCache()
        return granted
    }

    public func requestMicrophoneAccess() async -> Bool {
        invalidateCache()
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        invalidateCache()
        return granted
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
