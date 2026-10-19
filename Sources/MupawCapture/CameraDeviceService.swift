import AVFoundation
import Foundation
import MupawCore

public enum CameraDeviceServiceError: Error, LocalizedError, Sendable {
    case permissionRequired(PermissionStatus)
    case deviceNotFound(String)
    case noDefaultDevice

    public var errorDescription: String? {
        switch self {
        case .permissionRequired(let status):
            return "Camera permission is required before recording (status: \(status.rawValue))."
        case .deviceNotFound(let identifier):
            return "The camera device is unavailable: \(identifier)"
        case .noDefaultDevice:
            return "No default camera device is available."
        }
    }
}

@MainActor
public final class CameraDeviceService {
    public init() {}

    public func listDevices() -> CameraDeviceListResult {
        let defaultDevice = AVCaptureDevice.default(for: .video)
        let devices = discoveryDevices()
            .map { descriptor(for: $0, defaultDeviceID: defaultDevice?.uniqueID) }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return CameraDeviceListResult(
            permission: permissionStatus(),
            defaultDeviceID: defaultDevice?.uniqueID,
            devices: devices
        )
    }

    public func permissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
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

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func resolveDevice(
        identifier: String?
    ) throws -> (device: AVCaptureDevice, descriptor: CameraDeviceDescriptor) {
        let status = permissionStatus()
        guard status == .authorized else {
            throw CameraDeviceServiceError.permissionRequired(status)
        }

        let devices = discoveryDevices()
        let requested = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device: AVCaptureDevice
        if let requested, !requested.isEmpty {
            guard let resolved = devices.first(where: { $0.uniqueID == requested }),
                resolved.isConnected
            else {
                throw CameraDeviceServiceError.deviceNotFound(requested)
            }
            device = resolved
        } else {
            guard let defaultDevice = AVCaptureDevice.default(for: .video),
                defaultDevice.isConnected,
                devices.contains(where: { $0.uniqueID == defaultDevice.uniqueID })
            else {
                throw CameraDeviceServiceError.noDefaultDevice
            }
            device = defaultDevice
        }

        return (
            device,
            descriptor(
                for: device,
                defaultDeviceID: AVCaptureDevice.default(for: .video)?.uniqueID
            )
        )
    }

    private func discoveryDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private func descriptor(
        for device: AVCaptureDevice,
        defaultDeviceID: String?
    ) -> CameraDeviceDescriptor {
        let manufacturer = device.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        let position: CameraDevicePosition =
            switch device.position {
            case .front:
                .front
            case .back:
                .back
            case .unspecified:
                .unspecified
            @unknown default:
                .unspecified
            }
        return CameraDeviceDescriptor(
            id: device.uniqueID,
            name: device.localizedName,
            manufacturer: manufacturer.isEmpty ? nil : manufacturer,
            position: position,
            isDefault: device.uniqueID == defaultDeviceID,
            isConnected: device.isConnected
        )
    }
}
