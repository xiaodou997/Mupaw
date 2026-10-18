import Foundation

public struct AgentRPCProtocolFailure: Error, LocalizedError, Sendable, Equatable {
    public let responseID: String
    public let code: AgentRPCErrorCode
    public let message: String
    public let details: JSONValue?

    public init(
        responseID: String,
        code: AgentRPCErrorCode,
        message: String,
        details: JSONValue? = nil
    ) {
        self.responseID = responseID
        self.code = code
        self.message = message
        self.details = details
    }

    public var errorDescription: String? {
        message
    }

    public var response: AgentRPCResponse {
        .failure(id: responseID, code: code, message: message, details: details)
    }
}

public struct AgentRPCWireRequest: Sendable, Equatable {
    public let id: String
    public let protocolVersion: Int
    public let token: String
    public let methodName: String
    public let parameters: JSONValue

    public init(
        id: String,
        protocolVersion: Int,
        token: String,
        methodName: String,
        parameters: JSONValue
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.token = token
        self.methodName = methodName
        self.parameters = parameters
    }
}

public enum AgentRPCProtocolCodec {
    public static let unknownResponseID = "unknown"

    public static func decodeRequest(_ data: Data) throws -> AgentRPCRequest {
        try resolveMethod(in: decodeWireRequest(data))
    }

    public static func decodeWireRequest(_ data: Data) throws -> AgentRPCWireRequest {
        guard !data.isEmpty else {
            throw failure(
                responseID: unknownResponseID,
                code: .invalidRequest,
                message: "RPC request was empty."
            )
        }

        let root: JSONValue
        do {
            root = try JSONDecoder.mupaw.decode(JSONValue.self, from: data)
        } catch {
            throw failure(
                responseID: unknownResponseID,
                code: .invalidRequest,
                message: "RPC request was not valid JSON."
            )
        }

        guard let object = root.objectValue else {
            throw failure(
                responseID: unknownResponseID,
                code: .invalidRequest,
                message: "RPC request must be a JSON object."
            )
        }

        let candidateID = object["id"]?.stringValue
        let responseID = safeResponseID(candidateID) ?? unknownResponseID
        guard let identifier = candidateID, !identifier.isEmpty else {
            throw failure(
                responseID: unknownResponseID,
                code: .invalidRequest,
                message: "RPC request field 'id' must be a non-empty string.",
                field: "id"
            )
        }
        guard identifier.utf8.count <= MupawConstants.maximumRPCIdentifierUTF8Bytes else {
            throw failure(
                responseID: unknownResponseID,
                code: .invalidRequest,
                message: "RPC request field 'id' exceeded the maximum length.",
                field: "id"
            )
        }

        guard let protocolVersion = object["protocolVersion"]?.integerValue else {
            throw failure(
                responseID: responseID,
                code: .invalidRequest,
                message: "RPC request field 'protocolVersion' must be an integer.",
                field: "protocolVersion"
            )
        }
        guard let token = object["token"]?.stringValue else {
            throw failure(
                responseID: responseID,
                code: .invalidRequest,
                message: "RPC request field 'token' must be a string.",
                field: "token"
            )
        }
        guard let methodName = object["method"]?.stringValue, !methodName.isEmpty else {
            throw failure(
                responseID: responseID,
                code: .invalidRequest,
                message: "RPC request field 'method' must be a non-empty string.",
                field: "method"
            )
        }
        guard methodName.utf8.count <= MupawConstants.maximumRPCMethodUTF8Bytes else {
            throw failure(
                responseID: responseID,
                code: .invalidRequest,
                message: "RPC request field 'method' exceeded the maximum length.",
                field: "method"
            )
        }

        return AgentRPCWireRequest(
            id: identifier,
            protocolVersion: protocolVersion,
            token: token,
            methodName: methodName,
            parameters: object["parameters"] ?? .object([:])
        )
    }

    public static func resolveMethod(
        in wireRequest: AgentRPCWireRequest
    ) throws -> AgentRPCRequest {
        guard let method = AgentRPCMethod(rawValue: wireRequest.methodName) else {
            throw failure(
                responseID: wireRequest.id,
                code: .unknownMethod,
                message: "Unknown RPC method.",
                details: .object(["method": .string(wireRequest.methodName)])
            )
        }

        return AgentRPCRequest(
            id: wireRequest.id,
            protocolVersion: wireRequest.protocolVersion,
            token: wireRequest.token,
            method: method,
            parameters: wireRequest.parameters
        )
    }

    public static func encodeRequestFrame(
        _ request: AgentRPCRequest,
        maximumFrameBytes: Int = MupawConstants.maximumRPCFrameBytes
    ) throws -> Data {
        try encodeFrame(request, maximumFrameBytes: maximumFrameBytes)
    }

    public static func encodeResponseFrame(
        _ response: AgentRPCResponse,
        maximumFrameBytes: Int = MupawConstants.maximumRPCFrameBytes
    ) throws -> Data {
        do {
            return try encodeFrame(response, maximumFrameBytes: maximumFrameBytes)
        } catch AgentRPCClientError.frameTooLarge {
            let fallback = AgentRPCResponse.failure(
                id: safeResponseID(response.id) ?? unknownResponseID,
                code: .frameTooLarge,
                message: "RPC response exceeded the maximum frame size."
            )
            return try encodeFrame(fallback, maximumFrameBytes: maximumFrameBytes)
        }
    }

    private static func encodeFrame<T: Encodable>(
        _ value: T,
        maximumFrameBytes: Int
    ) throws -> Data {
        guard maximumFrameBytes > 1 else {
            throw AgentRPCClientError.frameTooLarge
        }

        var data = try JSONEncoder.mupaw.encode(value)
        data.append(0x0A)
        guard data.count <= maximumFrameBytes else {
            throw AgentRPCClientError.frameTooLarge
        }
        return data
    }

    private static func safeResponseID(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
            value.utf8.count <= MupawConstants.maximumRPCIdentifierUTF8Bytes
        else {
            return nil
        }
        return value
    }

    private static func failure(
        responseID: String,
        code: AgentRPCErrorCode,
        message: String,
        field: String? = nil,
        details: JSONValue? = nil
    ) -> AgentRPCProtocolFailure {
        let resolvedDetails: JSONValue?
        if let details {
            resolvedDetails = details
        } else if let field {
            resolvedDetails = .object(["field": .string(field)])
        } else {
            resolvedDetails = nil
        }
        return AgentRPCProtocolFailure(
            responseID: responseID,
            code: code,
            message: message,
            details: resolvedDetails
        )
    }
}
