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

            case "mupaw_screenshot_capture":
                return try await screenshot(arguments: arguments)

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
