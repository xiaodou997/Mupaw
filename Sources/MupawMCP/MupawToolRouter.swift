import Foundation
import MCP
import MupawCore

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
        guard let sourceID = arguments?["source_id"]?.stringValue,
            !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return failure("source_id is required. Call mupaw_sources_list and use an exact returned identifier.")
        }

        let formatValue = arguments?["format"]?.stringValue ?? "png"
        guard formatValue == ScreenshotFormat.png.rawValue else {
            return failure("M0 supports only PNG screenshots.")
        }

        let request = ScreenshotRequest(
            sourceID: sourceID,
            format: .png,
            includeCursor: arguments?["include_cursor"]?.boolValue ?? false,
            fileName: arguments?["file_name"]?.stringValue
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
