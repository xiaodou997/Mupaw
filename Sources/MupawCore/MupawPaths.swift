import Foundation

public struct MupawPaths: Sendable, Equatable {
    public let rootDirectory: URL
    public let capturesDirectory: URL
    public let projectsDirectory: URL
    public let exportsDirectory: URL
    public let recordingsDirectory: URL
    public let connectionDescriptorURL: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.capturesDirectory = rootDirectory.appendingPathComponent("Captures", isDirectory: true)
        self.projectsDirectory = rootDirectory.appendingPathComponent("Projects", isDirectory: true)
        self.exportsDirectory = rootDirectory.appendingPathComponent("Exports", isDirectory: true)
        self.recordingsDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
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
        let directories = [
            rootDirectory,
            capturesDirectory,
            projectsDirectory,
            exportsDirectory,
            recordingsDirectory,
        ]
        for directory in directories {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }
}
