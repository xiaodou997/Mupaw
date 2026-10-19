import Foundation
import XCTest

@testable import MupawCore

final class RecordingModelTests: XCTestCase {
    func testRecordingRequestRoundTripAndDefaults() throws {
        let request = RecordingRequest(
            mode: .region,
            region: CaptureRegion(
                rect: CaptureRect(x: 120, y: 80, width: 960, height: 540)
            ),
            frameRate: 30,
            quality: .high,
            includeCursor: true,
            includeSystemAudio: true,
            fileName: "Demo"
        )

        let data = try JSONEncoder.mupaw.encode(request)
        let decoded = try JSONDecoder.mupaw.decode(RecordingRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.format, .mp4)
        XCTAssertEqual(decoded.region?.coordinateSpace, .globalDisplayPoints)
        XCTAssertTrue(decoded.includeSystemAudio)
        XCTAssertEqual(decoded.audioSource, .systemAudio)
        XCTAssertFalse(decoded.includeMicrophone)
    }

    func testLegacyRecordingRequestDefaultsSystemAudioOff() throws {
        let data = Data(
            """
            {
              "mode": "window",
              "sourceID": "window:42",
              "frameRate": 30,
              "includeCursor": true
            }
            """.utf8
        )

        let request = try JSONDecoder.mupaw.decode(RecordingRequest.self, from: data)

        XCTAssertEqual(request.mode, .window)
        XCTAssertEqual(request.sourceID, "window:42")
        XCTAssertEqual(request.format, .mp4)
        XCTAssertEqual(request.quality, .standard)
        XCTAssertTrue(request.includeCursor)
        XCTAssertFalse(request.includeSystemAudio)
        XCTAssertFalse(request.includeMicrophone)
        XCTAssertEqual(request.audioSource, .none)
        XCTAssertEqual(request.systemAudioGain, 1)
        XCTAssertEqual(request.microphoneGain, 1)
        XCTAssertFalse(request.systemAudioMuted)
        XCTAssertFalse(request.microphoneMuted)
        XCTAssertTrue(request.audioControls.isValid)
        XCTAssertFalse(request.cameraOverlay.enabled)
        XCTAssertNil(request.cameraOverlay.deviceID)
        XCTAssertEqual(request.cameraOverlay.position, .bottomRight)
        XCTAssertEqual(request.cameraOverlay.size, .medium)
        XCTAssertEqual(request.cameraOverlay.shape, .circle)
        XCTAssertFalse(request.cameraOverlay.visible)
        XCTAssertEqual(request.cameraOverlay.cornerRadius, 0.12)
        XCTAssertEqual(request.cameraOverlay.margin, 0.025)
        XCTAssertTrue(request.cameraOverlay.isValid)
        XCTAssertTrue(request.excludeMupawUI)
    }

    func testRecordingAudioInfoRoundTrip() throws {
        let value = RecordingAudioInfo(
            requested: true,
            source: .microphone,
            state: .completed,
            codec: .aac,
            trackCount: 1,
            sampleRate: 48_000,
            channelCount: 1,
            durationSeconds: 4.25,
            sampleBufferCount: 200,
            audioVideoDurationDifferenceSeconds: 0.04,
            deviceID: "mic-1",
            deviceName: "Test Microphone",
            controls: RecordingAudioControls(
                systemAudioGain: 0.5,
                microphoneGain: 1.5,
                systemAudioMuted: true,
                microphoneMuted: false
            ),
            microphoneInput: RecordingAudioInputInfo(
                requested: true,
                state: .completed,
                sampleRate: 48_000,
                channelCount: 1,
                durationSeconds: 4.2,
                sampleBufferCount: 200,
                levelSummary: RecordingAudioLevelSummary(
                    averageRMS: 0.12,
                    maximumPeak: 0.8,
                    measurementCount: 200
                ),
                deviceID: "mic-1",
                deviceName: "Test Microphone"
            ),
            controlEventCount: 3
        )

        let data = try JSONEncoder.mupaw.encode(value)
        let decoded = try JSONDecoder.mupaw.decode(RecordingAudioInfo.self, from: data)

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(RecordingAudioInfo.disabled.state, .disabled)
        XCTAssertFalse(RecordingAudioInfo.disabled.requested)
        XCTAssertEqual(decoded.source, .microphone)
        XCTAssertEqual(decoded.deviceID, "mic-1")
        XCTAssertEqual(decoded.deviceName, "Test Microphone")
        XCTAssertEqual(decoded.controls.microphoneGain, 1.5)
        XCTAssertEqual(decoded.microphoneInput?.sampleBufferCount, 200)
        XCTAssertEqual(decoded.controlEventCount, 3)
        XCTAssertEqual(RecordingAudioInfo.disabled.source, .none)
    }

    func testMicrophoneRequestRoundTripAndLegacyCompatibility() throws {
        let request = RecordingRequest(
            mode: .window,
            sourceID: "window:42",
            audioSource: .microphone,
            microphoneDeviceID: "mic-1",
            microphoneGain: 1.25,
            microphoneMuted: true
        )
        let roundTrip = try JSONDecoder.mupaw.decode(
            RecordingRequest.self,
            from: JSONEncoder.mupaw.encode(request)
        )
        XCTAssertEqual(roundTrip.audioSource, .microphone)
        XCTAssertTrue(roundTrip.includeMicrophone)
        XCTAssertFalse(roundTrip.includeSystemAudio)
        XCTAssertEqual(roundTrip.microphoneDeviceID, "mic-1")
        XCTAssertEqual(roundTrip.microphoneGain, 1.25)
        XCTAssertTrue(roundTrip.microphoneMuted)
        XCTAssertFalse(roundTrip.hasConflictingAudioSelection)

        let legacyData = Data(
            """
            {
              "mode": "window",
              "sourceID": "window:42",
              "includeMicrophone": true,
              "microphoneDeviceID": "legacy-mic"
            }
            """.utf8
        )
        let legacy = try JSONDecoder.mupaw.decode(RecordingRequest.self, from: legacyData)
        XCTAssertEqual(legacy.audioSource, .microphone)
        XCTAssertTrue(legacy.includeMicrophone)
        XCTAssertEqual(legacy.microphoneDeviceID, "legacy-mic")
    }

    func testMixedLegacyAudioAndConflictingSelections() throws {
        let bothLegacy = try JSONDecoder.mupaw.decode(
            RecordingRequest.self,
            from: Data(
                """
                {
                  "mode": "window",
                  "sourceID": "window:42",
                  "includeSystemAudio": true,
                  "includeMicrophone": true
                }
                """.utf8
            )
        )
        XCTAssertEqual(bothLegacy.audioSource, .systemAudioAndMicrophone)
        XCTAssertTrue(bothLegacy.includeSystemAudio)
        XCTAssertTrue(bothLegacy.includeMicrophone)
        XCTAssertFalse(bothLegacy.hasConflictingAudioSelection)

        let contradictory = RecordingRequest(
            mode: .window,
            sourceID: "window:42",
            audioSource: .systemAudio,
            includeMicrophone: true
        )
        XCTAssertTrue(contradictory.hasConflictingAudioSelection)
    }

    func testAudioControlsValidateAndApplyPartialUpdates() {
        let controls = RecordingAudioControls(
            systemAudioGain: 0.75,
            microphoneGain: 1.25,
            systemAudioMuted: false,
            microphoneMuted: true
        )
        XCTAssertTrue(controls.isValid)
        XCTAssertFalse(
            RecordingAudioControls(systemAudioGain: -0.01, microphoneGain: 1).isValid
        )
        XCTAssertFalse(
            RecordingAudioControls(systemAudioGain: 1, microphoneGain: 2.01).isValid
        )
        XCTAssertFalse(
            RecordingAudioControls(systemAudioGain: .infinity, microphoneGain: 1).isValid
        )

        let update = RecordingAudioControlUpdateRequest(
            sessionID: "session",
            systemAudioGain: 1.5,
            microphoneMuted: false
        )
        XCTAssertTrue(update.hasChanges)
        let applied = controls.applying(update)
        XCTAssertEqual(applied.systemAudioGain, 1.5)
        XCTAssertEqual(applied.microphoneGain, 1.25)
        XCTAssertFalse(applied.microphoneMuted)
        XCTAssertFalse(RecordingAudioControlUpdateRequest(sessionID: "session").hasChanges)
    }

    func testCanonicalMixedRequestRoundTrip() throws {
        let request = RecordingRequest(
            mode: .window,
            sourceID: "window:42",
            audioSource: .systemAudioAndMicrophone,
            microphoneDeviceID: "mic-1",
            systemAudioGain: 0.6,
            microphoneGain: 1.4,
            systemAudioMuted: false,
            microphoneMuted: true
        )
        let decoded = try JSONDecoder.mupaw.decode(
            RecordingRequest.self,
            from: JSONEncoder.mupaw.encode(request)
        )
        XCTAssertEqual(decoded.audioSource, .systemAudioAndMicrophone)
        XCTAssertTrue(decoded.audioSource.usesSystemAudio)
        XCTAssertTrue(decoded.audioSource.usesMicrophone)
        XCTAssertTrue(decoded.audioSource.isMixed)
        XCTAssertTrue(decoded.includeSystemAudio)
        XCTAssertTrue(decoded.includeMicrophone)
        XCTAssertEqual(decoded.audioControls, request.audioControls)
        XCTAssertFalse(decoded.hasConflictingAudioSelection)
    }

    func testMicrophoneDeviceDescriptorsRoundTrip() throws {
        let value = MicrophoneDeviceListResult(
            permission: .authorized,
            defaultDeviceID: "mic-1",
            devices: [
                MicrophoneDeviceDescriptor(
                    id: "mic-1",
                    name: "Built-in Microphone",
                    manufacturer: "Apple",
                    isDefault: true,
                    isConnected: true
                )
            ]
        )
        let decoded = try JSONDecoder.mupaw.decode(
            MicrophoneDeviceListResult.self,
            from: JSONEncoder.mupaw.encode(value)
        )
        XCTAssertEqual(decoded.permission, value.permission)
        XCTAssertEqual(decoded.defaultDeviceID, value.defaultDeviceID)
        XCTAssertEqual(decoded.devices, value.devices)
    }

    func testCameraRequestAndDeviceDiscoveryRoundTrip() throws {
        let request = RecordingRequest(
            mode: .window,
            sourceID: "window:42",
            audioSource: .systemAudio,
            cameraOverlay: RecordingCameraOverlayConfiguration(
                enabled: true,
                deviceID: "camera-1",
                visible: false,
                position: .topLeft,
                size: .large,
                shape: .roundedRectangle,
                cornerRadius: 0.25,
                margin: 0.08
            )
        )
        let decodedRequest = try JSONDecoder.mupaw.decode(
            RecordingRequest.self,
            from: JSONEncoder.mupaw.encode(request)
        )
        XCTAssertEqual(decodedRequest, request)
        XCTAssertTrue(decodedRequest.cameraOverlay.enabled)
        XCTAssertEqual(decodedRequest.cameraOverlay.deviceID, "camera-1")
        XCTAssertEqual(decodedRequest.cameraOverlay.position, .topLeft)
        XCTAssertEqual(decodedRequest.cameraOverlay.size, .large)
        XCTAssertEqual(decodedRequest.cameraOverlay.shape, .roundedRectangle)
        XCTAssertFalse(decodedRequest.cameraOverlay.visible)
        XCTAssertEqual(decodedRequest.cameraOverlay.cornerRadius, 0.25)
        XCTAssertEqual(decodedRequest.cameraOverlay.margin, 0.08)

        let devices = CameraDeviceListResult(
            refreshedAt: Date(timeIntervalSince1970: 12_345),
            permission: .authorized,
            defaultDeviceID: "camera-1",
            devices: [
                CameraDeviceDescriptor(
                    id: "camera-1",
                    name: "Built-in Camera",
                    manufacturer: "Apple",
                    position: .front,
                    isDefault: true,
                    isConnected: true
                )
            ]
        )
        let decodedDevices = try JSONDecoder.mupaw.decode(
            CameraDeviceListResult.self,
            from: JSONEncoder.mupaw.encode(devices)
        )
        XCTAssertEqual(decodedDevices.permission, devices.permission)
        XCTAssertEqual(decodedDevices.defaultDeviceID, devices.defaultDeviceID)
        XCTAssertEqual(decodedDevices.devices, devices.devices)
        XCTAssertEqual(decodedDevices.refreshedAt, devices.refreshedAt)
    }

    func testCameraInfoRoundTrip() throws {
        let value = RecordingCameraInfo(
            requested: true,
            state: .completed,
            deviceID: "camera-1",
            deviceName: "Built-in Camera",
            visible: true,
            position: .bottomRight,
            size: .medium,
            shape: .circle,
            cornerRadius: 0.2,
            margin: 0.04,
            overlayRectPixels: CaptureRect(x: 1_600, y: 760, width: 280, height: 280),
            sourcePixelWidth: 1_280,
            sourcePixelHeight: 720,
            frameCount: 300,
            lastFrameAt: Date(timeIntervalSince1970: 1_000),
            lastSourceTimestampSeconds: 42.5,
            isStale: false,
            controlEventCount: 4
        )
        let decoded = try JSONDecoder.mupaw.decode(
            RecordingCameraInfo.self,
            from: JSONEncoder.mupaw.encode(value)
        )
        XCTAssertEqual(decoded, value)
        XCTAssertFalse(RecordingCameraInfo.disabled.requested)
        XCTAssertEqual(RecordingCameraInfo.disabled.state, .disabled)
    }

    func testCameraOverlayRuntimeUpdateAndLegacyDefaults() throws {
        let initial = RecordingCameraOverlayConfiguration(
            enabled: true,
            deviceID: "camera-1",
            position: .bottomRight,
            size: .medium,
            shape: .circle
        )
        let update = RecordingCameraOverlayUpdateRequest(
            sessionID: "session-1",
            visible: false,
            position: .topLeft,
            size: .large,
            shape: .roundedRectangle,
            cornerRadius: 0.3,
            margin: 0.1
        )
        let updated = initial.applying(update)
        XCTAssertTrue(update.hasChanges)
        XCTAssertEqual(updated.deviceID, "camera-1")
        XCTAssertFalse(updated.visible)
        XCTAssertEqual(updated.position, .topLeft)
        XCTAssertEqual(updated.size, .large)
        XCTAssertEqual(updated.shape, .roundedRectangle)
        XCTAssertEqual(updated.cornerRadius, 0.3)
        XCTAssertEqual(updated.margin, 0.1)
        XCTAssertTrue(updated.isValid)
        XCTAssertFalse(RecordingCameraOverlayUpdateRequest(sessionID: "session-1").hasChanges)
        XCTAssertFalse(
            RecordingCameraOverlayConfiguration(
                enabled: true,
                cornerRadius: 0.51
            ).isValid
        )
        XCTAssertFalse(
            RecordingCameraOverlayConfiguration(
                enabled: true,
                margin: 0.151
            ).isValid
        )

        let legacy = try JSONDecoder.mupaw.decode(
            RecordingCameraOverlayConfiguration.self,
            from: Data(
                """
                {
                  "enabled": true,
                  "deviceID": "legacy-camera",
                  "position": "bottom_right",
                  "size": "medium",
                  "shape": "circle"
                }
                """.utf8
            )
        )
        XCTAssertTrue(legacy.visible)
        XCTAssertEqual(legacy.cornerRadius, 0.12)
        XCTAssertEqual(legacy.margin, 0.025)
        XCTAssertTrue(legacy.isValid)
    }

    func testCameraLayoutPlannerBoundsPositionsAndShapes() throws {
        let width = 1_920
        let height = 1_080
        var rectangles: [RecordingCameraOverlayPosition: CaptureRect] = [:]
        for position in RecordingCameraOverlayPosition.allCases {
            for size in RecordingCameraOverlaySize.allCases {
                for shape in RecordingCameraOverlayShape.allCases {
                    let rect = try RecordingCameraLayoutPlanner.makeRect(
                        outputPixelWidth: width,
                        outputPixelHeight: height,
                        configuration: RecordingCameraOverlayConfiguration(
                            enabled: true,
                            position: position,
                            size: size,
                            shape: shape
                        )
                    )
                    XCTAssertTrue(rect.hasPositiveArea)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertGreaterThanOrEqual(rect.minY, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, Double(width))
                    XCTAssertLessThanOrEqual(rect.maxY, Double(height))
                    if shape == .circle {
                        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001)
                    } else {
                        XCTAssertEqual(rect.width / rect.height, 16 / 9, accuracy: 0.05)
                    }
                    if size == .medium, shape == .circle {
                        rectangles[position] = rect
                    }
                }
            }
        }

        let topLeft = try XCTUnwrap(rectangles[.topLeft])
        let topRight = try XCTUnwrap(rectangles[.topRight])
        let bottomLeft = try XCTUnwrap(rectangles[.bottomLeft])
        let bottomRight = try XCTUnwrap(rectangles[.bottomRight])
        XCTAssertLessThan(topLeft.minX, topRight.minX)
        XCTAssertLessThan(bottomLeft.minX, bottomRight.minX)
        XCTAssertLessThan(topLeft.minY, bottomLeft.minY)
        XCTAssertLessThan(topRight.minY, bottomRight.minY)
    }

    func testCameraLayoutPlannerUsesBoundedSafeMargin() throws {
        let flush = try RecordingCameraLayoutPlanner.makeRect(
            outputPixelWidth: 1_920,
            outputPixelHeight: 1_080,
            configuration: RecordingCameraOverlayConfiguration(
                enabled: true,
                position: .topLeft,
                margin: 0
            )
        )
        let inset = try RecordingCameraLayoutPlanner.makeRect(
            outputPixelWidth: 1_920,
            outputPixelHeight: 1_080,
            configuration: RecordingCameraOverlayConfiguration(
                enabled: true,
                position: .topLeft,
                margin: 0.1
            )
        )
        XCTAssertGreaterThan(inset.minX, flush.minX)
        XCTAssertGreaterThan(inset.minY, flush.minY)
    }

    func testCameraLayoutPlannerRejectsInvalidOutput() {
        XCTAssertThrowsError(
            try RecordingCameraLayoutPlanner.makeRect(
                outputPixelWidth: 0,
                outputPixelHeight: 1_080,
                configuration: RecordingCameraOverlayConfiguration(enabled: true)
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingCameraLayoutPlanningError,
                .invalidOutputSize
            )
        }
        XCTAssertThrowsError(
            try RecordingCameraLayoutPlanner.makeRect(
                outputPixelWidth: 1_920,
                outputPixelHeight: 1_080,
                configuration: RecordingCameraOverlayConfiguration(
                    enabled: true,
                    margin: 0.2
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? RecordingCameraLayoutPlanningError,
                .invalidConfiguration
            )
        }
    }

    func testResolutionPlannerPreservesAspectAndBoundsSixK() throws {
        let landscape = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 6_016,
            sourcePixelHeight: 3_384
        )
        XCTAssertEqual(landscape, RecordingResolution(pixelWidth: 3_840, pixelHeight: 2_160))

        let portrait = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 3_384,
            sourcePixelHeight: 6_016
        )
        XCTAssertEqual(portrait, RecordingResolution(pixelWidth: 2_160, pixelHeight: 3_840))
    }

    func testResolutionPlannerUsesEvenDimensionsAndPixelLimit() throws {
        let small = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 1_001,
            sourcePixelHeight: 777
        )
        XCTAssertTrue(small.pixelWidth.isMultiple(of: 2))
        XCTAssertTrue(small.pixelHeight.isMultiple(of: 2))
        XCTAssertLessThanOrEqual(
            small.pixelWidth * small.pixelHeight,
            MupawConstants.maximumRecordingPixelCount
        )

        let square = try RecordingResolutionPlanner.makeResolution(
            sourcePixelWidth: 10_000,
            sourcePixelHeight: 10_000
        )
        XCTAssertTrue(square.pixelWidth.isMultiple(of: 2))
        XCTAssertTrue(square.pixelHeight.isMultiple(of: 2))
        XCTAssertLessThanOrEqual(
            square.pixelWidth * square.pixelHeight,
            MupawConstants.maximumRecordingPixelCount
        )
    }

    func testResolutionPlannerRejectsInvalidSources() {
        XCTAssertThrowsError(
            try RecordingResolutionPlanner.makeResolution(
                sourcePixelWidth: 0,
                sourcePixelHeight: 1_080
            )
        ) { error in
            XCTAssertEqual(error as? RecordingResolutionPlanningError, .invalidSourceSize)
        }
    }

    func testQualityBitrateIsBoundedAndHighIsLarger() {
        let standard = RecordingVideoQuality.standard.estimatedBitRate(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            frameRate: 30
        )
        let high = RecordingVideoQuality.high.estimatedBitRate(
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            frameRate: 30
        )
        XCTAssertGreaterThan(high, standard)
        XCTAssertGreaterThanOrEqual(standard, MupawConstants.minimumRecordingBitRate)
        XCTAssertLessThanOrEqual(high, MupawConstants.maximumRecordingBitRate)
    }

    func testPathsPrepareOwnerOnlyRecordingsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MupawRecordingPaths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MupawPaths(rootDirectory: root)

        try paths.prepare()

        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.recordingsDirectory.path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }
}
