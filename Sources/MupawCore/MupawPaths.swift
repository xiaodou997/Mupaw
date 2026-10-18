import Foundation

public struct MupawPaths: Sendable, Equatable {
    public let rootDirectory: URL
    public let capturesDirectory: URL
    public let connectionDescriptorURL: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.capturesDirectory = rootDirectory.appendingPathComponent("Captures", isDirectory: true)
        self.connectionDescriptorURL = rootDirectory.appendingPathComponent("agent-connection.json")
    }

    public static func live(fileManager: FileManager = .default) throws -> MupawPaths {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return MupawPaths(rootDirectory: base.appendingPathComponent("Mupaw", isDirectory: true))
    }

    public func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(
            at: capturesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
