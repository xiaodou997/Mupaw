import XCTest

@testable import MupawCore

final class FileNameSanitizerTests: XCTestCase {
    func testSanitizesPathAndExtensionCharacters() {
        let value = FileNameSanitizer.sanitizedBaseName(
            "  ../Demo: Capture?.png  ",
            fallback: "fallback"
        )
        XCTAssertEqual(value, "Demo-Capture")
        XCTAssertFalse(value.contains("/"))
        XCTAssertFalse(value.contains("."))
    }

    func testUsesFallbackForEmptyName() {
        XCTAssertEqual(
            FileNameSanitizer.sanitizedBaseName("   ", fallback: "Mupaw-1"),
            "Mupaw-1"
        )
    }

    func testBoundsNameLength() {
        let value = FileNameSanitizer.sanitizedBaseName(
            String(repeating: "a", count: 200),
            fallback: "fallback"
        )
        XCTAssertEqual(value.count, 80)
    }
}
