import Foundation
import XCTest

@testable import MupawCore

final class DescriptorStoreTests: XCTestCase {
    func testWritesReadsAndRemovesOwnerOnlyDescriptor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MupawTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = MupawPaths(rootDirectory: root)
        let store = AgentConnectionDescriptorStore(paths: paths)
        let descriptor = AgentConnectionDescriptor(
            port: 49_321,
            token: "test-token",
            processID: 42,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        try store.write(descriptor)
        XCTAssertEqual(try store.read(), descriptor)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.connectionDescriptorURL.path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        try store.remove(matchingToken: "different-token")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.connectionDescriptorURL.path))

        try store.remove(matchingToken: descriptor.token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.connectionDescriptorURL.path))
    }
}
