import Foundation
import XCTest

@testable import MupawCore

final class JSONValueTests: XCTestCase {
    private struct Sample: Codable, Equatable {
        let name: String
        let count: Int
        let enabled: Bool
        let values: [Double]
    }

    func testCodableRoundTrip() throws {
        let original = Sample(name: "Mupaw", count: 3, enabled: true, values: [1.5, 2.5])
        let value = try JSONValue.wrapping(original)
        let decoded = try value.decode(Sample.self)
        XCTAssertEqual(decoded, original)
    }

    func testObjectAccessorsDoNotCoerceTypes() {
        let value = JSONValue.object([
            "name": .string("Mupaw"),
            "enabled": .bool(true),
            "count": .integer(2),
        ])
        XCTAssertEqual(value.objectValue?["name"]?.stringValue, "Mupaw")
        XCTAssertEqual(value.objectValue?["enabled"]?.boolValue, true)
        XCTAssertEqual(value.objectValue?["count"]?.integerValue, 2)
        XCTAssertNil(value.objectValue?["count"]?.stringValue)
    }
}
