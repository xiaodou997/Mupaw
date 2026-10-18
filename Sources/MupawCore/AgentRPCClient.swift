import Darwin
import Foundation

public struct AgentRPCClient: Sendable {
    public let descriptor: AgentConnectionDescriptor
    public let timeout: TimeInterval

    public init(
        descriptor: AgentConnectionDescriptor,
        timeout: TimeInterval = TimeInterval(MupawConstants.rpcSocketTimeoutSeconds)
    ) {
        self.descriptor = descriptor
        self.timeout = timeout
    }

    public func call<Payload: Encodable & Sendable, Result: Decodable & Sendable>(
        method: AgentRPCMethod,
        payload: Payload,
        responseType: Result.Type
    ) async throws -> Result {
        guard descriptor.protocolVersion == MupawConstants.rpcProtocolVersion else {
            throw AgentRPCClientError.appUnavailable(
                "Protocol version \(descriptor.protocolVersion) is incompatible with \(MupawConstants.rpcProtocolVersion)."
            )
        }

        let request = AgentRPCRequest(
            token: descriptor.token,
            method: method,
            parameters: try JSONValue.wrapping(payload)
        )
        let timeout =
            method == .projectOCR
            ? max(timeout, MupawConstants.ocrRPCTimeoutSeconds)
            : timeout
        let descriptor = descriptor

        let response = try await Task.detached(priority: .userInitiated) {
            try Self.performRequest(request, descriptor: descriptor, timeout: timeout)
        }.value

        guard response.id == request.id else {
            throw AgentRPCClientError.malformedResponse(
                "Response identifier mismatch: expected \(request.id), received \(response.id)."
            )
        }
        if let error = response.error {
            throw AgentRPCClientError.requestFailed(error)
        }
        guard let result = response.result else {
            throw AgentRPCClientError.malformedResponse("A successful response did not include a result.")
        }
        return try result.decode(responseType)
    }

    private static func configureSocket(_ socketFD: Int32, timeout: TimeInterval) throws {
        var timeoutValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        let receiveTimeoutResult = withUnsafePointer(to: &timeoutValue) { pointer in
            Darwin.setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard receiveTimeoutResult == 0 else {
            throw AgentRPCClientError.appUnavailable(errnoMessage(prefix: "setsockopt receive timeout"))
        }

        let sendTimeoutResult = withUnsafePointer(to: &timeoutValue) { pointer in
            Darwin.setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard sendTimeoutResult == 0 else {
            throw AgentRPCClientError.appUnavailable(errnoMessage(prefix: "setsockopt send timeout"))
        }

        var noSignal: Int32 = 1
        guard
            Darwin.setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else {
            throw AgentRPCClientError.appUnavailable(errnoMessage(prefix: "setsockopt no-sigpipe"))
        }
    }

    private static func performRequest(
        _ request: AgentRPCRequest,
        descriptor: AgentConnectionDescriptor,
        timeout: TimeInterval
    ) throws -> AgentRPCResponse {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw AgentRPCClientError.appUnavailable(errnoMessage(prefix: "socket"))
        }
        defer { Darwin.close(socketFD) }

        try configureSocket(socketFD, timeout: timeout)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = descriptor.port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    socketFD,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connected == 0 else {
            throw AgentRPCClientError.appUnavailable(errnoMessage(prefix: "connect"))
        }

        let payload = try AgentRPCProtocolCodec.encodeRequestFrame(request)
        try sendAll(payload, socketFD: socketFD)
        _ = Darwin.shutdown(socketFD, SHUT_WR)
        let responseData = try receiveLine(socketFD: socketFD)

        do {
            return try JSONDecoder.mupaw.decode(AgentRPCResponse.self, from: responseData)
        } catch {
            throw AgentRPCClientError.malformedResponse(error.localizedDescription)
        }
    }

    private static func sendAll(_ data: Data, socketFD: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let result = Darwin.send(
                    socketFD,
                    baseAddress.advanced(by: sent),
                    data.count - sent,
                    0
                )
                if result < 0 && errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw AgentRPCClientError.appUnavailable(errnoMessage(prefix: "send"))
                }
                sent += result
            }
        }
    }

    private static func receiveLine(socketFD: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while data.count <= MupawConstants.maximumRPCFrameBytes {
            let count = Darwin.recv(socketFD, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 && errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw AgentRPCClientError.appUnavailable(errnoMessage(prefix: "receive"))
            }

            if let newlineIndex = buffer[..<count].firstIndex(of: 0x0A) {
                guard data.count + newlineIndex + 1 <= MupawConstants.maximumRPCFrameBytes else {
                    throw AgentRPCClientError.frameTooLarge
                }
                data.append(contentsOf: buffer[..<newlineIndex])
                return data
            }
            guard data.count + count + 1 <= MupawConstants.maximumRPCFrameBytes else {
                throw AgentRPCClientError.frameTooLarge
            }
            data.append(contentsOf: buffer[..<count])
        }

        guard data.count <= MupawConstants.maximumRPCFrameBytes else {
            throw AgentRPCClientError.frameTooLarge
        }
        guard !data.isEmpty else {
            throw AgentRPCClientError.malformedResponse("The app closed the connection without a response.")
        }
        return data
    }

    private static func errnoMessage(prefix: String) -> String {
        let message = String(cString: strerror(errno))
        return "\(prefix) failed: \(message)"
    }
}
