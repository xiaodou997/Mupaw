import AVFoundation
import Foundation
import MupawCore

public enum MicrophoneDeviceServiceError: Error, LocalizedError, Sendable {
    case permissionRequired(PermissionStatus)
    case deviceNotFound(String)
    case noDefaultDevice

    public var errorDescription: String? {
        switch self {
        case .permissionRequired(let status):
            return "Microphone permission is required before recording (status: \(status.rawValue))."
        case .deviceNotFound(let identifier):
            return "The microphone device is unavailable: \(identifier)"
        case .noDefaultDevice:
            return "No default microphone device is available."
        }
    }
}

@MainActor
public final class MicrophoneDeviceService {
    public init() {}

    public func listDevices() -> MicrophoneDeviceListResult {
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices
            .map { descriptor(for: $0, defaultDeviceID: defaultDevice?.uniqueID) }
            .sorted {
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return MicrophoneDeviceListResult(
            permission: permissionStatus(),
            defaultDeviceID: defaultDevice?.uniqueID,
            devices: devices
        )
    }

    public func permissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
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
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted
    }

    func resolveDevice(
        identifier: String?
    ) throws -> (device: AVCaptureDevice, descriptor: MicrophoneDeviceDescriptor) {
        let status = permissionStatus()
        guard status == .authorized else {
            throw MicrophoneDeviceServiceError.permissionRequired(status)
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let requested = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let device: AVCaptureDevice
        if let requested, !requested.isEmpty {
            guard
                let resolved = discovery.devices.first(where: { $0.uniqueID == requested }),
                resolved.isConnected
            else {
                throw MicrophoneDeviceServiceError.deviceNotFound(requested)
            }
            device = resolved
        } else {
            guard let defaultDevice = AVCaptureDevice.default(for: .audio),
                defaultDevice.isConnected,
                discovery.devices.contains(where: { $0.uniqueID == defaultDevice.uniqueID })
            else {
                throw MicrophoneDeviceServiceError.noDefaultDevice
            }
            device = defaultDevice
        }

        return (
            device,
            descriptor(
                for: device,
                defaultDeviceID: AVCaptureDevice.default(for: .audio)?.uniqueID
            )
        )
    }

    private func descriptor(
        for device: AVCaptureDevice,
        defaultDeviceID: String?
    ) -> MicrophoneDeviceDescriptor {
        let manufacturer = device.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        return MicrophoneDeviceDescriptor(
            id: device.uniqueID,
            name: device.localizedName,
            manufacturer: manufacturer.isEmpty ? nil : manufacturer,
            isDefault: device.uniqueID == defaultDeviceID,
            isConnected: device.isConnected
        )
    }
}
