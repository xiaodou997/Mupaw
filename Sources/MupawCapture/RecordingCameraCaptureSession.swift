@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum RecordingCameraCaptureError: Error, LocalizedError, Sendable {
    case couldNotCreateInput(String)
    case couldNotConfigureInput
    case couldNotConfigureOutput
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotCreateInput(let message):
            "Could not open the selected camera: \(message)"
        case .couldNotConfigureInput:
            "The selected camera could not be added to the capture session."
        case .couldNotConfigureOutput:
            "The camera video output could not be configured."
        case .couldNotStart:
            "The camera capture session did not start."
        }
    }
}

final class RecordingCameraCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(
        label: "com.xiaodou.mupaw.recording.camera.output",
        qos: .userInitiated
    )
    private let onFrame: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (Error) -> Void

    init(
        device: AVCaptureDevice,
        onFrame: @escaping @Sendable (CMSampleBuffer) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        self.onFrame = onFrame
        self.onFailure = onFailure
        super.init()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingCameraCaptureError.couldNotCreateInput(error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }
        guard session.canAddInput(input) else {
            throw RecordingCameraCaptureError.couldNotConfigureInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw RecordingCameraCaptureError.couldNotConfigureOutput
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device.position == .front
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @MainActor
    func start() throws {
        session.startRunning()
        guard session.isRunning else {
            throw RecordingCameraCaptureError.couldNotStart
        }
    }

    @MainActor
    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        outputQueue.sync {}
    }

    @MainActor
    func stopImmediately() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        onFrame(sampleBuffer)
    }

    @objc
    private func sessionRuntimeError(_ notification: Notification) {
        let error =
            (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)
            ?? RecordingCameraCaptureError.couldNotStart
        onFailure(error)
    }
}
