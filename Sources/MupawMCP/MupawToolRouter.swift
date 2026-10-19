import Foundation
import MCP
import MupawCore

private struct ToolArgumentError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

internal struct MupawToolRouter: Sendable {
    func handle(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case "mupaw_app_status":
                return await appStatus()

            case "mupaw_capabilities_get":
                let result: CapabilitySnapshot = try await call(
                    method: .capabilitiesGet,
                    payload: EmptyPayload(),
                    responseType: CapabilitySnapshot.self
                )
                return success(result)

            case "mupaw_sources_list":
                let result: SourceListResult = try await call(
                    method: .sourcesList,
                    payload: EmptyPayload(),
                    responseType: SourceListResult.self
                )
                return success(result)

            case "mupaw_microphones_list":
                let result: MicrophoneDeviceListResult = try await call(
                    method: .microphonesList,
                    payload: EmptyPayload(),
                    responseType: MicrophoneDeviceListResult.self
                )
                return success(result)

            case "mupaw_cameras_list":
                let result: CameraDeviceListResult = try await call(
                    method: .camerasList,
                    payload: EmptyPayload(),
                    responseType: CameraDeviceListResult.self
                )
                return success(result)

            case "mupaw_screenshot_capture":
                return try await screenshot(arguments: arguments)

            case "mupaw_recording_start":
                return try await recordingStart(arguments: arguments)

            case "mupaw_recording_status":
                return try await recordingStatus(arguments: arguments)

            case "mupaw_recording_update_audio_controls":
                return try await recordingUpdateAudioControls(arguments: arguments)

            case "mupaw_recording_update_camera_overlay":
                return try await recordingUpdateCameraOverlay(arguments: arguments)

            case "mupaw_recording_stop":
                return try await recordingStop(arguments: arguments)

            case "mupaw_recording_cancel":
                return try await recordingCancel(arguments: arguments)

            case "mupaw_project_create":
                return try await projectCreate(arguments: arguments)

            case "mupaw_project_get":
                return try await projectGet(arguments: arguments)

            case "mupaw_project_apply_edits":
                return try await projectApplyEdits(arguments: arguments)

            case "mupaw_project_history":
                return try await projectHistory(arguments: arguments)

            case "mupaw_project_preview":
                return try await projectPreview(arguments: arguments)

            case "mupaw_project_export":
                return try await projectExport(arguments: arguments)

            case "mupaw_project_ocr":
                return try await projectOCR(arguments: arguments)

            case "mupaw_project_color_sample":
                return try await projectColorSample(arguments: arguments)

            default:
                return failure("Unknown Mupaw tool: \(name)")
            }
        } catch AgentRPCClientError.descriptorMissing {
            return failure("Mupaw request failed [app_not_running]: Start Mupaw.app and retry.")
        } catch AgentRPCClientError.appUnavailable(let message) {
            return failure("Mupaw request failed [app_not_running]: \(message)")
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func appStatus() async -> CallTool.Result {
        do {
            let result: AppStatusResult = try await call(
                method: .appStatus,
                payload: EmptyPayload(),
                responseType: AppStatusResult.self
            )
            return success(result)
        } catch AgentRPCClientError.descriptorMissing {
            return success(
                JSONValue.object([
                    "running": .bool(false),
                    "message": .string("Mupaw.app is not running. Start Mupaw and retry."),
                ]))
        } catch {
            return success(
                JSONValue.object([
                    "running": .bool(false),
                    "message": .string(error.localizedDescription),
                ]))
        }
    }

    private func screenshot(arguments: [String: Value]?) async throws -> CallTool.Result {
        let arguments = arguments ?? [:]
        let formatValue = arguments["format"]?.stringValue ?? ScreenshotFormat.png.rawValue
        guard formatValue == ScreenshotFormat.png.rawValue else {
            return failure("M1a supports only PNG screenshots.")
        }

        let sourceID = arguments["source_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let region = try parseRegion(arguments["region"])

        let mode: ScreenshotCaptureMode
        if let modeValue = arguments["mode"]?.stringValue {
            guard let explicitMode = ScreenshotCaptureMode(rawValue: modeValue) else {
                return failure("mode must be one of full_screen, window, or region.")
            }
            mode = explicitMode
        } else if region != nil {
            mode = .region
        } else if sourceID?.hasPrefix("window:") == true {
            mode = .window
        } else {
            mode = .fullScreen
        }

        switch mode {
        case .fullScreen, .window:
            guard let sourceID, !sourceID.isEmpty else {
                return failure(
                    "source_id is required for full_screen and window. Call mupaw_sources_list and use an exact returned identifier."
                )
            }
            if region != nil {
                return failure("region must be omitted for full_screen and window capture.")
            }
        case .region:
            guard region != nil else {
                return failure("region is required when mode is region.")
            }
            if let sourceID, !sourceID.isEmpty {
                return failure("source_id must be omitted when mode is region.")
            }
        }

        let request = ScreenshotRequest(
            mode: mode,
            sourceID: sourceID,
            region: region,
            format: .png,
            includeCursor: arguments["include_cursor"]?.boolValue ?? false,
            excludeMupawUI: arguments["exclude_mupaw_ui"]?.boolValue ?? true,
            fileName: arguments["file_name"]?.stringValue
        )
        let artifact: ScreenshotArtifact = try await call(
            method: .screenshotCapture,
            payload: request,
            responseType: ScreenshotArtifact.self
        )

        var content: [Tool.Content] = [
            .text(text: try encodedJSON(artifact), annotations: nil, _meta: nil)
        ]
        if let preview = artifact.preview {
            content.append(
                .image(
                    data: preview.base64Data,
                    mimeType: preview.mimeType,
                    annotations: nil,
                    _meta: nil
                )
            )
        }
        return .init(content: content, isError: false)
    }

    private func recordingStart(arguments: [String: Value]?) async throws -> CallTool.Result {
        let arguments = arguments ?? [:]
        let formatValue = arguments["format"]?.stringValue ?? RecordingFormat.mp4.rawValue
        guard let format = RecordingFormat(rawValue: formatValue), format == .mp4 else {
            return failure("M3a supports H.264 MP4 recording with optional AAC audio and camera overlay.")
        }

        guard let modeValue = arguments["mode"]?.stringValue,
            let mode = ScreenshotCaptureMode(rawValue: modeValue)
        else {
            return failure("mode is required and must be full_screen, window, or region.")
        }
        let sourceID = arguments["source_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let region = try parseRegion(arguments["region"])
        switch mode {
        case .fullScreen, .window:
            guard let sourceID, !sourceID.isEmpty else {
                return failure(
                    "source_id is required for full_screen and window recording. Call mupaw_sources_list and use an exact returned identifier."
                )
            }
            if region != nil {
                return failure("region must be omitted for full_screen and window recording.")
            }
        case .region:
            guard region != nil else {
                return failure("region is required when recording mode is region.")
            }
            if let sourceID, !sourceID.isEmpty {
                return failure("source_id must be omitted when recording mode is region.")
            }
        }

        let frameRate = arguments["frame_rate"]?.intValue ?? 30
        guard MupawConstants.supportedRecordingFrameRates.contains(frameRate) else {
            return failure("frame_rate must be 15, 30, or 60.")
        }
        let qualityValue = arguments["quality"]?.stringValue ?? RecordingVideoQuality.standard.rawValue
        guard let quality = RecordingVideoQuality(rawValue: qualityValue) else {
            return failure("quality must be standard or high.")
        }

        let explicitAudioSource: RecordingAudioSource?
        if let value = arguments["audio_source"]?.stringValue {
            guard let parsed = RecordingAudioSource(rawValue: value) else {
                return failure(
                    "audio_source must be none, system_audio, microphone, or system_audio_and_microphone."
                )
            }
            explicitAudioSource = parsed
        } else {
            explicitAudioSource = nil
        }
        let includeSystemAudio = arguments["include_system_audio"]?.boolValue ?? false
        let includeMicrophone = arguments["include_microphone"]?.boolValue ?? false
        let audioSource: RecordingAudioSource
        if let explicitAudioSource {
            audioSource = explicitAudioSource
            if includeSystemAudio, !explicitAudioSource.usesSystemAudio {
                return failure(
                    "Mupaw request failed [audio_mixing_not_supported]: audio_source conflicts with include_system_audio."
                )
            }
            if includeMicrophone, !explicitAudioSource.usesMicrophone {
                return failure(
                    "Mupaw request failed [audio_mixing_not_supported]: audio_source conflicts with include_microphone."
                )
            }
        } else if includeSystemAudio && includeMicrophone {
            audioSource = .systemAudioAndMicrophone
        } else if includeSystemAudio {
            audioSource = .systemAudio
        } else if includeMicrophone {
            audioSource = .microphone
        } else {
            audioSource = .none
        }
        let microphoneDeviceID = arguments["microphone_device_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !audioSource.usesMicrophone, let microphoneDeviceID, !microphoneDeviceID.isEmpty {
            return failure(
                "microphone_device_id is valid only when audio_source uses microphone input."
            )
        }

        let systemAudioGain = try audioGain(arguments["system_audio_gain"], defaultValue: 1)
        let microphoneGain = try audioGain(arguments["microphone_gain"], defaultValue: 1)
        let systemAudioMuted = arguments["system_audio_muted"]?.boolValue ?? false
        let microphoneMuted = arguments["microphone_muted"]?.boolValue ?? false
        let cameraOverlay = try parseCameraOverlay(arguments["camera_overlay"])

        let request = RecordingRequest(
            mode: mode,
            sourceID: sourceID,
            region: region,
            format: format,
            frameRate: frameRate,
            quality: quality,
            includeCursor: arguments["include_cursor"]?.boolValue ?? false,
            audioSource: audioSource,
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone,
            microphoneDeviceID: microphoneDeviceID,
            systemAudioGain: systemAudioGain,
            microphoneGain: microphoneGain,
            systemAudioMuted: systemAudioMuted,
            microphoneMuted: microphoneMuted,
            cameraOverlay: cameraOverlay,
            excludeMupawUI: arguments["exclude_mupaw_ui"]?.boolValue ?? true,
            fileName: arguments["file_name"]?.stringValue
        )
        let status: RecordingSessionStatus = try await call(
            method: .recordingStart,
            payload: request,
            responseType: RecordingSessionStatus.self
        )
        return recordingResult(status)
    }

    private func recordingStatus(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request = try recordingSessionRequest(arguments)
        let status: RecordingSessionStatus = try await call(
            method: .recordingStatus,
            payload: request,
            responseType: RecordingSessionStatus.self
        )
        return recordingResult(status)
    }

    private func recordingUpdateAudioControls(
        arguments: [String: Value]?
    ) async throws -> CallTool.Result {
        let arguments = arguments ?? [:]
        guard
            let sessionID = arguments["session_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionID.isEmpty
        else {
            throw ToolArgumentError(
                message: "Mupaw request failed [invalid_request]: session_id is required."
            )
        }

        let request = RecordingAudioControlUpdateRequest(
            sessionID: sessionID,
            systemAudioGain: try optionalAudioGain(arguments["system_audio_gain"]),
            microphoneGain: try optionalAudioGain(arguments["microphone_gain"]),
            systemAudioMuted: arguments["system_audio_muted"]?.boolValue,
            microphoneMuted: arguments["microphone_muted"]?.boolValue
        )
        guard request.hasChanges else {
            throw ToolArgumentError(
                message:
                    "Mupaw request failed [invalid_audio_controls]: Provide at least one gain or mute field."
            )
        }
        let status: RecordingSessionStatus = try await call(
            method: .recordingUpdateAudioControls,
            payload: request,
            responseType: RecordingSessionStatus.self
        )
        return recordingResult(status)
    }

    private func recordingUpdateCameraOverlay(
        arguments: [String: Value]?
    ) async throws -> CallTool.Result {
        let arguments = arguments ?? [:]
        guard
            let sessionID = arguments["session_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionID.isEmpty
        else {
            throw ToolArgumentError(
                message: "Mupaw request failed [invalid_request]: session_id is required."
            )
        }

        let position: RecordingCameraOverlayPosition?
        if let value = arguments["position"]?.stringValue {
            guard let parsed = RecordingCameraOverlayPosition(rawValue: value) else {
                throw ToolArgumentError(
                    message:
                        "Mupaw request failed [invalid_camera_overlay]: position must be top_left, top_right, bottom_left, or bottom_right."
                )
            }
            position = parsed
        } else {
            position = nil
        }

        let size: RecordingCameraOverlaySize?
        if let value = arguments["size"]?.stringValue {
            guard let parsed = RecordingCameraOverlaySize(rawValue: value) else {
                throw ToolArgumentError(
                    message:
                        "Mupaw request failed [invalid_camera_overlay]: size must be small, medium, or large."
                )
            }
            size = parsed
        } else {
            size = nil
        }

        let shape: RecordingCameraOverlayShape?
        if let value = arguments["shape"]?.stringValue {
            guard let parsed = RecordingCameraOverlayShape(rawValue: value) else {
                throw ToolArgumentError(
                    message:
                        "Mupaw request failed [invalid_camera_overlay]: shape must be circle or rounded_rectangle."
                )
            }
            shape = parsed
        } else {
            shape = nil
        }

        let request = RecordingCameraOverlayUpdateRequest(
            sessionID: sessionID,
            visible: arguments["visible"]?.boolValue,
            position: position,
            size: size,
            shape: shape,
            cornerRadius: try optionalCameraOverlayNumber(
                arguments["corner_radius"],
                minimum: MupawConstants.minimumRecordingCameraCornerRadius,
                maximum: MupawConstants.maximumRecordingCameraCornerRadius,
                field: "corner_radius"
            ),
            margin: try optionalCameraOverlayNumber(
                arguments["margin"],
                minimum: MupawConstants.minimumRecordingCameraMargin,
                maximum: MupawConstants.maximumRecordingCameraMargin,
                field: "margin"
            )
        )
        guard request.hasChanges else {
            throw ToolArgumentError(
                message:
                    "Mupaw request failed [invalid_camera_overlay]: Provide at least one camera overlay field."
            )
        }
        let status: RecordingSessionStatus = try await call(
            method: .recordingUpdateCameraOverlay,
            payload: request,
            responseType: RecordingSessionStatus.self
        )
        return recordingResult(status)
    }

    private func recordingStop(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request = try recordingSessionRequest(arguments)
        let status: RecordingSessionStatus = try await call(
            method: .recordingStop,
            payload: request,
            responseType: RecordingSessionStatus.self
        )
        return recordingResult(status)
    }

    private func recordingCancel(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request = try recordingSessionRequest(arguments)
        let status: RecordingSessionStatus = try await call(
            method: .recordingCancel,
            payload: request,
            responseType: RecordingSessionStatus.self
        )
        return recordingResult(status)
    }

    private func recordingSessionRequest(
        _ arguments: [String: Value]?
    ) throws -> RecordingSessionRequest {
        guard
            let sessionID = arguments?["session_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionID.isEmpty
        else {
            throw ToolArgumentError(
                message: "Mupaw request failed [invalid_request]: session_id is required."
            )
        }
        return RecordingSessionRequest(sessionID: sessionID)
    }

    private func recordingResult(_ status: RecordingSessionStatus) -> CallTool.Result {
        if let preview = status.artifact?.preview {
            return successWithPreview(status, preview: preview)
        }
        return success(status)
    }

    private func projectCreate(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectCreateRequest = try decodeArguments(arguments)
        let result: ScreenshotProjectState = try await call(
            method: .projectCreate,
            payload: request,
            responseType: ScreenshotProjectState.self
        )
        return success(result)
    }

    private func projectGet(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectGetRequest = try decodeArguments(arguments)
        let result: ScreenshotProjectState = try await call(
            method: .projectGet,
            payload: request,
            responseType: ScreenshotProjectState.self
        )
        return success(result)
    }

    private func projectApplyEdits(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectApplyEditsRequest = try decodeArguments(arguments)
        let result: ScreenshotProjectState = try await call(
            method: .projectApplyEdits,
            payload: request,
            responseType: ScreenshotProjectState.self
        )
        return success(result)
    }

    private func projectHistory(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectHistoryRequest = try decodeArguments(arguments)
        let result: ScreenshotProjectState = try await call(
            method: .projectHistory,
            payload: request,
            responseType: ScreenshotProjectState.self
        )
        return success(result)
    }

    private func projectPreview(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectPreviewRequest = try decodeArguments(arguments)
        let result: ProjectPreviewResult = try await call(
            method: .projectPreview,
            payload: request,
            responseType: ProjectPreviewResult.self
        )
        return successWithPreview(result, preview: result.preview)
    }

    private func projectExport(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectExportRequest = try decodeArguments(arguments)
        let result: ProjectExportArtifact = try await call(
            method: .projectExport,
            payload: request,
            responseType: ProjectExportArtifact.self
        )
        return successWithPreview(result, preview: result.preview)
    }

    private func projectOCR(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectOCRRequest = try decodeArguments(arguments)
        let result: ProjectOCRResult = try await call(
            method: .projectOCR,
            payload: request,
            responseType: ProjectOCRResult.self
        )
        return success(result)
    }

    private func projectColorSample(arguments: [String: Value]?) async throws -> CallTool.Result {
        let request: ProjectColorSampleRequest = try decodeArguments(arguments)
        let result: ProjectColorSampleResult = try await call(
            method: .projectColorSample,
            payload: request,
            responseType: ProjectColorSampleResult.self
        )
        return success(result)
    }

    private func decodeArguments<T: Decodable>(_ arguments: [String: Value]?) throws -> T {
        do {
            let data = try JSONEncoder().encode(Value.object(arguments ?? [:]))
            return try JSONDecoder.mupaw.decode(T.self, from: data)
        } catch {
            throw ToolArgumentError(
                message:
                    "Mupaw request failed [invalid_request]: Invalid Mupaw tool arguments: \(error.localizedDescription)"
            )
        }
    }

    private func parseRegion(_ value: Value?) throws -> CaptureRegion? {
        guard let value else { return nil }
        guard let object = value.objectValue else {
            throw ToolArgumentError(
                message: "region must be an object with x, y, width, and height."
            )
        }
        guard let x = number(object["x"]),
            let y = number(object["y"]),
            let width = number(object["width"]),
            let height = number(object["height"]),
            x.isFinite, y.isFinite, width.isFinite, height.isFinite,
            width > 0, height > 0
        else {
            throw ToolArgumentError(
                message:
                    "region x, y, width, and height must be finite numbers with positive dimensions."
            )
        }

        let coordinateSpaceValue =
            object["coordinate_space"]?.stringValue
            ?? CaptureCoordinateSpace.globalDisplayPoints.rawValue
        guard let coordinateSpace = CaptureCoordinateSpace(rawValue: coordinateSpaceValue) else {
            throw ToolArgumentError(
                message: "region.coordinate_space must be global_display_points."
            )
        }
        return CaptureRegion(
            coordinateSpace: coordinateSpace,
            rect: CaptureRect(x: x, y: y, width: width, height: height)
        )
    }

    private func number(_ value: Value?) -> Double? {
        if let double = value?.doubleValue { return double }
        if let integer = value?.intValue { return Double(integer) }
        return nil
    }

    private func audioGain(_ value: Value?, defaultValue: Double) throws -> Double {
        guard let value else { return defaultValue }
        guard let gain = number(value),
            gain.isFinite,
            (MupawConstants.minimumRecordingAudioGain...MupawConstants.maximumRecordingAudioGain)
                .contains(gain)
        else {
            throw ToolArgumentError(
                message:
                    "Mupaw request failed [invalid_audio_controls]: audio gain must be a finite number from 0.0 through 2.0."
            )
        }
        return gain
    }

    private func optionalAudioGain(_ value: Value?) throws -> Double? {
        guard value != nil else { return nil }
        return try audioGain(value, defaultValue: 1)
    }

    private func parseCameraOverlay(
        _ value: Value?
    ) throws -> RecordingCameraOverlayConfiguration {
        guard let value else { return .disabled }
        guard let object = value.objectValue else {
            throw ToolArgumentError(
                message: "camera_overlay must be an object."
            )
        }
        let enabled = object["enabled"]?.boolValue ?? false
        let visible = object["visible"]?.boolValue ?? enabled
        let deviceID = object["camera_device_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !enabled, deviceID?.isEmpty == false || visible {
            throw ToolArgumentError(
                message:
                    "Mupaw request failed [invalid_camera_overlay]: camera_device_id or visible=true requires camera_overlay.enabled=true."
            )
        }

        let positionValue =
            object["position"]?.stringValue
            ?? RecordingCameraOverlayPosition.bottomRight.rawValue
        guard let position = RecordingCameraOverlayPosition(rawValue: positionValue) else {
            throw ToolArgumentError(
                message:
                    "camera_overlay.position must be top_left, top_right, bottom_left, or bottom_right."
            )
        }
        let sizeValue =
            object["size"]?.stringValue
            ?? RecordingCameraOverlaySize.medium.rawValue
        guard let size = RecordingCameraOverlaySize(rawValue: sizeValue) else {
            throw ToolArgumentError(
                message: "camera_overlay.size must be small, medium, or large."
            )
        }
        let shapeValue =
            object["shape"]?.stringValue
            ?? RecordingCameraOverlayShape.circle.rawValue
        guard let shape = RecordingCameraOverlayShape(rawValue: shapeValue) else {
            throw ToolArgumentError(
                message: "camera_overlay.shape must be circle or rounded_rectangle."
            )
        }
        let cornerRadius = try cameraOverlayNumber(
            object["corner_radius"],
            defaultValue: 0.12,
            minimum: MupawConstants.minimumRecordingCameraCornerRadius,
            maximum: MupawConstants.maximumRecordingCameraCornerRadius,
            field: "corner_radius"
        )
        let margin = try cameraOverlayNumber(
            object["margin"],
            defaultValue: 0.025,
            minimum: MupawConstants.minimumRecordingCameraMargin,
            maximum: MupawConstants.maximumRecordingCameraMargin,
            field: "margin"
        )
        return RecordingCameraOverlayConfiguration(
            enabled: enabled,
            deviceID: enabled ? deviceID : nil,
            visible: visible,
            position: position,
            size: size,
            shape: shape,
            cornerRadius: cornerRadius,
            margin: margin
        )
    }

    private func cameraOverlayNumber(
        _ value: Value?,
        defaultValue: Double,
        minimum: Double,
        maximum: Double,
        field: String
    ) throws -> Double {
        guard let value else { return defaultValue }
        guard let number = number(value), number.isFinite, (minimum...maximum).contains(number)
        else {
            throw ToolArgumentError(
                message:
                    "Mupaw request failed [invalid_camera_overlay]: \(field) must be a finite number from \(minimum) through \(maximum)."
            )
        }
        return number
    }

    private func optionalCameraOverlayNumber(
        _ value: Value?,
        minimum: Double,
        maximum: Double,
        field: String
    ) throws -> Double? {
        guard value != nil else { return nil }
        return try cameraOverlayNumber(
            value,
            defaultValue: minimum,
            minimum: minimum,
            maximum: maximum,
            field: field
        )
    }

    private func call<Payload: Encodable & Sendable, Result: Decodable & Sendable>(
        method: AgentRPCMethod,
        payload: Payload,
        responseType: Result.Type
    ) async throws -> Result {
        let paths = try MupawPaths.live()
        let descriptor = try AgentConnectionDescriptorStore(paths: paths).read()
        let client = AgentRPCClient(descriptor: descriptor)
        return try await client.call(method: method, payload: payload, responseType: responseType)
    }

    private func successWithPreview<T: Encodable>(
        _ value: T,
        preview: ImagePreview
    ) -> CallTool.Result {
        do {
            return .init(
                content: [
                    .text(text: try encodedJSON(value), annotations: nil, _meta: nil),
                    .image(
                        data: preview.base64Data,
                        mimeType: preview.mimeType,
                        annotations: nil,
                        _meta: nil
                    ),
                ],
                isError: false
            )
        } catch {
            return failure("Could not encode Mupaw result: \(error.localizedDescription)")
        }
    }

    private func success<T: Encodable>(_ value: T) -> CallTool.Result {
        do {
            return .init(
                content: [.text(text: try encodedJSON(value), annotations: nil, _meta: nil)],
                isError: false
            )
        } catch {
            return failure("Could not encode Mupaw result: \(error.localizedDescription)")
        }
    }

    private func failure(_ message: String) -> CallTool.Result {
        .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder.mupaw
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "Could not convert encoded result to UTF-8.")
            )
        }
        return string
    }
}
