import Foundation
import XCTest

@testable import MupawCore

final class AgentRPCProtocolCodecTests: XCTestCase {
    func testDecodesValidRequestAndDefaultsParameters() throws {
        let data = Data(
            """
            {"id":"request-1","protocolVersion":1,"token":"token","method":"ping"}
            """.utf8
        )

        let request = try AgentRPCProtocolCodec.decodeRequest(data)

        XCTAssertEqual(request.id, "request-1")
        XCTAssertEqual(request.protocolVersion, MupawConstants.rpcProtocolVersion)
        XCTAssertEqual(request.token, "token")
        XCTAssertEqual(request.method, .ping)
        XCTAssertEqual(request.parameters, .object([:]))
    }

    func testUnknownMethodPreservesSafeResponseIdentifier() throws {
        let data = Data(
            """
            {"id":"unknown-method","protocolVersion":1,"token":"token","method":"does_not_exist","parameters":{}}
            """.utf8
        )

        let failure = try protocolFailure {
            _ = try AgentRPCProtocolCodec.decodeRequest(data)
        }

        XCTAssertEqual(failure.responseID, "unknown-method")
        XCTAssertEqual(failure.code, .unknownMethod)
        XCTAssertEqual(failure.details?.objectValue?["method"]?.stringValue, "does_not_exist")
    }

    func testMissingMethodIsInvalidRequestAndPreservesIdentifier() throws {
        let data = Data(
            """
            {"id":"missing-method","protocolVersion":1,"token":"token","parameters":{}}
            """.utf8
        )

        let failure = try protocolFailure {
            _ = try AgentRPCProtocolCodec.decodeRequest(data)
        }

        XCTAssertEqual(failure.responseID, "missing-method")
        XCTAssertEqual(failure.code, .invalidRequest)
        XCTAssertEqual(failure.details?.objectValue?["field"]?.stringValue, "method")
    }

    func testMalformedAndEmptyRequestsUseUnknownIdentifier() throws {
        for data in [Data(), Data("{\"id\":\"broken\",".utf8)] {
            let failure = try protocolFailure {
                _ = try AgentRPCProtocolCodec.decodeRequest(data)
            }
            XCTAssertEqual(failure.responseID, AgentRPCProtocolCodec.unknownResponseID)
            XCTAssertEqual(failure.code, .invalidRequest)
        }
    }

    func testOversizedIdentifierIsNotReflected() throws {
        let oversizedID = String(
            repeating: "x",
            count: MupawConstants.maximumRPCIdentifierUTF8Bytes + 1
        )
        let value = JSONValue.object([
            "id": .string(oversizedID),
            "protocolVersion": .integer(MupawConstants.rpcProtocolVersion),
            "token": .string("token"),
            "method": .string(AgentRPCMethod.ping.rawValue),
            "parameters": .object([:]),
        ])
        let data = try JSONEncoder.mupaw.encode(value)

        let failure = try protocolFailure {
            _ = try AgentRPCProtocolCodec.decodeRequest(data)
        }

        XCTAssertEqual(failure.responseID, AgentRPCProtocolCodec.unknownResponseID)
        XCTAssertEqual(failure.code, .invalidRequest)
    }

    func testRequestFrameLimitIncludesDelimiter() throws {
        let request = AgentRPCRequest(
            token: "token",
            method: .ping,
            parameters: .string(String(repeating: "x", count: 1_024))
        )

        XCTAssertThrowsError(
            try AgentRPCProtocolCodec.encodeRequestFrame(request, maximumFrameBytes: 128)
        ) { error in
            guard case AgentRPCClientError.frameTooLarge = error else {
                return XCTFail("Expected frameTooLarge, received \(error)")
            }
        }
    }

    func testOversizedResponseFallsBackWithSameIdentifier() throws {
        let response = AgentRPCResponse(
            id: "large-response",
            result: .string(String(repeating: "x", count: 2_048)),
            error: nil
        )

        let frame = try AgentRPCProtocolCodec.encodeResponseFrame(
            response,
            maximumFrameBytes: 512
        )

        XCTAssertLessThanOrEqual(frame.count, 512)
        XCTAssertEqual(frame.last, 0x0A)
        let decoded = try JSONDecoder.mupaw.decode(
            AgentRPCResponse.self,
            from: Data(frame.dropLast())
        )
        XCTAssertEqual(decoded.id, response.id)
        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.error?.code, .frameTooLarge)
    }

    private func protocolFailure(
        _ operation: () throws -> Void
    ) throws -> AgentRPCProtocolFailure {
        do {
            try operation()
            XCTFail("Expected AgentRPCProtocolFailure")
            throw TestFailure.expectedProtocolFailure
        } catch let failure as AgentRPCProtocolFailure {
            return failure
        }
    }
}

private enum TestFailure: Error {
    case expectedProtocolFailure
}
