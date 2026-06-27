import XCTest
@testable import MacParakeetCore

final class NemotronLanguageCatalogTests: XCTestCase {
    func testAcceptsTheSixEuropeanCodes() {
        for code in ["en", "es", "fr", "it", "pt", "de"] {
            XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: code), code)
        }
    }

    func testCollapsesRegionAliases() {
        XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: "es-ES"), "es")
        XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: "pt-BR"), "pt")
        XCTAssertEqual(NemotronLanguageCatalog.canonicalCode(for: "EN_us"), "en")
    }

    func testRejectsNonEuropeanAndAuto() {
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "ko"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "ja"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "zh"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: "auto"))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: nil))
        XCTAssertNil(NemotronLanguageCatalog.canonicalCode(for: ""))
    }

    func testDisplayLabels() {
        XCTAssertEqual(NemotronLanguageCatalog.displayLabel(forCode: "fr"), "French")
        XCTAssertNil(NemotronLanguageCatalog.displayLabel(forCode: "ko"))
    }

    func testSupportedCodesAreExactlySix() {
        XCTAssertEqual(Set(NemotronLanguageCatalog.supportedCodes), ["en", "es", "fr", "it", "pt", "de"])
    }
}
