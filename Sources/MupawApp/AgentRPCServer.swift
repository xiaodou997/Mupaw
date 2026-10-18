import Darwin
import Dispatch
import Foundation
import MupawCore

final class AgentRPCServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentRPCRequest) async -> AgentRPCResponse

    private let queue = DispatchQueue(label: "com.xiaodou.mupaw.agent-rpc")
    private let handler: Handler
    private let descriptorStore: AgentConnectionDescriptorStore
    private let token: String
    private let stateLock = NSLock()

    private var listenSocket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var currentDescriptor: AgentConnectionDescriptor?

    init(descriptorStore: AgentConnectionDescriptorStore, handler: @escaping Handler) {
        self.descriptorStore = descriptorStore
        self.handler = handler
        self.token =
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    deinit {
        stop()
    }

    func start() throws -> AgentConnectionDescriptor {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let currentDescriptor {
            return currentDescriptor
        }

        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXServerError(operation: "socket")
        }

        do {
            var reuse: Int32 = 1
            guard
                Darwin.setsockopt(
                    socketFD,
                    SOL_SOCKET,
                    SO_REUSEADDR,
                    &reuse,
                    socklen_t(MemoryLayout<Int32>.size)
                ) == 0
            else {
                throw POSIXServerError(operation: "setsockopt")
            }

            var flags = Darwin.fcntl(socketFD, F_GETFL, 0)
            flags |= O_NONBLOCK
            guard Darwin.fcntl(socketFD, F_SETFL, flags) == 0 else {
                throw POSIXServerError(operation: "fcntl")
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                throw POSIXServerError(operation: "bind")
            }
            guard Darwin.listen(socketFD, 16) == 0 else {
                throw POSIXServerError(operation: "listen")
            }

            var localAddress = sockaddr_in()
            var localLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(socketFD, $0, &localLength)
                }
            }
            guard named == 0 else {
                throw POSIXServerError(operation: "getsockname")
            }

            let descriptor = AgentConnectionDescriptor(
                port: UInt16(bigEndian: localAddress.sin_port),
                token: token,
                processID: getpid()
            )
            try descriptorStore.write(descriptor)

            listenSocket = socketFD
            currentDescriptor = descriptor

            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptPendingConnections()
            }
            readSource = source
            source.resume()
            return descriptor
        } catch {
            Darwin.close(socketFD)
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let socketFD = listenSocket
        let source = readSource
        let descriptor = currentDescriptor
        listenSocket = -1
        readSource = nil
        currentDescriptor = nil
        stateLock.unlock()

        source?.cancel()
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
        if let descriptor {
            try? descriptorStore.remove(matchingToken: descriptor.token)
        }
    }

    private func acceptPendingConnections() {
        while true {
            let clientSocket = Darwin.accept(listenSocket, nil, nil)
            if clientSocket < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }

            do {
                try Self.configureClientSocket(clientSocket)
            } catch {
                Darwin.close(clientSocket)
                continue
            }

            Task.detached(priority: .userInitiated) { [handler, token] in
                await Self.handleClient(socketFD: clientSocket, expectedToken: token, handler: handler)
            }
        }
    }

    private static func configureClientSocket(_ socketFD: Int32) throws {
        let flags = Darwin.fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0 else {
            throw POSIXServerError(operation: "fcntl get accepted socket flags")
        }
        guard Darwin.fcntl(socketFD, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw POSIXServerError(operation: "fcntl clear accepted socket nonblocking")
        }

        var timeoutValue = timeval(
            tv_sec: MupawConstants.rpcSocketTimeoutSeconds,
            tv_usec: 0
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
            throw POSIXServerError(operation: "setsockopt accepted receive timeout")
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
            throw POSIXServerError(operation: "setsockopt accepted send timeout")
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
            throw POSIXServerError(operation: "setsockopt accepted no-sigpipe")
        }
    }

    private static func handleClient(
        socketFD: Int32,
        expectedToken: String,
        handler: Handler
    ) async {
        defer { Darwin.close(socketFD) }

        var response: AgentRPCResponse
        do {
            let data = try receiveLine(socketFD: socketFD)
            let wireRequest = try AgentRPCProtocolCodec.decodeWireRequest(data)

            guard wireRequest.protocolVersion == MupawConstants.rpcProtocolVersion else {
                response = .failure(
                    id: wireRequest.id,
                    code: .protocolMismatch,
                    message: "Unsupported RPC protocol version \(wireRequest.protocolVersion)."
                )
                try send(response, socketFD: socketFD)
                return
            }
            guard wireRequest.token == expectedToken else {
                response = .failure(
                    id: wireRequest.id,
                    code: .unauthorized,
                    message: "Invalid local RPC token."
                )
                try send(response, socketFD: socketFD)
                return
            }

            let request = try AgentRPCProtocolCodec.resolveMethod(in: wireRequest)
            response = await handler(request)
        } catch let failure as AgentRPCProtocolFailure {
            response = failure.response
        } catch AgentRPCClientError.frameTooLarge {
            response = .failure(
                id: "unknown", code: .frameTooLarge, message: "RPC request exceeded the maximum frame size.")
        } catch {
            response = .failure(id: "unknown", code: .invalidRequest, message: error.localizedDescription)
        }

        try? send(response, socketFD: socketFD)
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
                throw POSIXServerError(operation: "receive")
            }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                guard data.count + newline + 1 <= MupawConstants.maximumRPCFrameBytes else {
                    throw AgentRPCClientError.frameTooLarge
                }
                data.append(contentsOf: buffer[..<newline])
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
            throw AgentRPCClientError.malformedResponse("Empty RPC request.")
        }
        return data
    }

    private static func send(_ response: AgentRPCResponse, socketFD: Int32) throws {
        let data = try AgentRPCProtocolCodec.encodeResponseFrame(response)

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(socketFD, base.advanced(by: sent), data.count - sent, 0)
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw POSIXServerError(operation: "send")
                }
                sent += count
            }
        }
    }
}

private struct POSIXServerError: Error, LocalizedError {
    let operation: String
    let code: Int32

    init(operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}
