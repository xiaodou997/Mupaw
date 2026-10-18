import Foundation

public enum AgentRPCMethod: String, Codable, Sendable, CaseIterable {
    case ping
    case appStatus = "app_status"
    case capabilitiesGet = "capabilities_get"
    case permissionsGet = "permissions_get"
    case sourcesList = "sources_list"
    case screenshotCapture = "screenshot_capture"
    case projectCreate = "project_create"
    case projectGet = "project_get"
    case projectApplyEdits = "project_apply_edits"
    case projectHistory = "project_history"
    case projectPreview = "project_preview"
    case projectExport = "project_export"
    case projectOCR = "project_ocr"
    case projectColorSample = "project_color_sample"
}

public struct AgentRPCRequest: Codable, Sendable, Equatable {
    public let id: String
    public let protocolVersion: Int
    public let token: String
    public let method: AgentRPCMethod
    public let parameters: JSONValue

    public init(
        id: String = UUID().uuidString,
        protocolVersion: Int = MupawConstants.rpcProtocolVersion,
        token: String,
        method: AgentRPCMethod,
        parameters: JSONValue = .object([:])
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.token = token
        self.method = method
        self.parameters = parameters
    }
}

public enum AgentRPCErrorCode: String, Codable, Sendable {
    case appNotRunning = "app_not_running"
    case protocolMismatch = "protocol_mismatch"
    case unauthorized
    case invalidRequest = "invalid_request"
    case unknownMethod = "unknown_method"
    case permissionRequired = "permission_required"
    case sourceNotFound = "source_not_found"
    case invalidRegion = "invalid_region"
    case captureInProgress = "capture_in_progress"
    case captureFailed = "capture_failed"
    case artifactNotFound = "artifact_not_found"
    case artifactHashMismatch = "artifact_hash_mismatch"
    case projectNotFound = "project_not_found"
    case projectVersionConflict = "project_version_conflict"
    case invalidEdit = "invalid_edit"
    case historyUnavailable = "history_unavailable"
    case exportFailed = "export_failed"
    case ocrFailed = "ocr_failed"
    case colorSamplingFailed = "color_sampling_failed"
    case frameTooLarge = "frame_too_large"
    case internalError = "internal_error"
}

public struct AgentRPCErrorPayload: Codable, Sendable, Equatable {
    public let code: AgentRPCErrorCode
    public let message: String
    public let details: JSONValue?

    public init(code: AgentRPCErrorCode, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct AgentRPCResponse: Codable, Sendable, Equatable {
    public let id: String
    public let result: JSONValue?
    public let error: AgentRPCErrorPayload?

    public init(id: String, result: JSONValue?, error: AgentRPCErrorPayload?) {
        self.id = id
        self.result = result
        self.error = error
    }

    public static func success<T: Encodable>(id: String, value: T) throws -> AgentRPCResponse {
        AgentRPCResponse(id: id, result: try JSONValue.wrapping(value), error: nil)
    }

    public static func failure(
        id: String,
        code: AgentRPCErrorCode,
        message: String,
        details: JSONValue? = nil
    ) -> AgentRPCResponse {
        AgentRPCResponse(
            id: id,
            result: nil,
            error: AgentRPCErrorPayload(code: code, message: message, details: details)
        )
    }
}

public enum AgentRPCClientError: Error, LocalizedError, Sendable {
    case descriptorMissing
    case appUnavailable(String)
    case frameTooLarge
    case malformedResponse(String)
    case requestFailed(AgentRPCErrorPayload)

    public var errorDescription: String? {
        switch self {
        case .descriptorMissing:
            return "Mupaw is not running or its local connection descriptor is missing."
        case .appUnavailable(let message):
            return "Mupaw is unavailable: \(message)"
        case .frameTooLarge:
            return "The local Mupaw RPC frame exceeded the maximum allowed size."
        case .malformedResponse(let message):
            return "Mupaw returned a malformed response: \(message)"
        case .requestFailed(let payload):
            return "Mupaw request failed [\(payload.code.rawValue)]: \(payload.message)"
        }
    }
}
