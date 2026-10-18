import Foundation

public struct AgentConnectionDescriptor: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let port: UInt16
    public let token: String
    public let processID: Int32
    public let appVersion: String
    public let startedAt: Date

    public init(
        protocolVersion: Int = MupawConstants.rpcProtocolVersion,
        port: UInt16,
        token: String,
        processID: Int32,
        appVersion: String = MupawConstants.appVersion,
        startedAt: Date = Date()
    ) {
        self.protocolVersion = protocolVersion
        self.port = port
        self.token = token
        self.processID = processID
        self.appVersion = appVersion
        self.startedAt = startedAt
    }
}

public struct AgentConnectionDescriptorStore: Sendable {
    private let paths: MupawPaths

    public init(paths: MupawPaths) {
        self.paths = paths
    }

    public func read(fileManager: FileManager = .default) throws -> AgentConnectionDescriptor {
        guard fileManager.fileExists(atPath: paths.connectionDescriptorURL.path) else {
            throw AgentRPCClientError.descriptorMissing
        }

        do {
            let data = try Data(contentsOf: paths.connectionDescriptorURL)
            return try JSONDecoder.mupaw.decode(AgentConnectionDescriptor.self, from: data)
        } catch let error as AgentRPCClientError {
            throw error
        } catch {
            throw AgentRPCClientError.malformedResponse(error.localizedDescription)
        }
    }

    public func write(
        _ descriptor: AgentConnectionDescriptor,
        fileManager: FileManager = .default
    ) throws {
        try paths.prepare(fileManager: fileManager)
        let data = try JSONEncoder.mupaw.encode(descriptor)
        try data.write(to: paths.connectionDescriptorURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.connectionDescriptorURL.path
        )
    }

    public func remove(
        matchingToken token: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: paths.connectionDescriptorURL.path) else { return }

        if let token {
            let current = try read(fileManager: fileManager)
            guard current.token == token else { return }
        }

        try fileManager.removeItem(at: paths.connectionDescriptorURL)
    }
}
