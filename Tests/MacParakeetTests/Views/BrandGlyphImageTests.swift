import XCTest
@testable import MacParakeet
import MacParakeetCore

/// Guards the brand-mark resource wiring. SPM `.process` flattens resource
/// subdirectories, so the loader must resolve each PDF by basename at the bundle
/// root — a regression here silently degrades every orbit chip to the globe.
@MainActor
final class BrandGlyphImageTests: XCTestCase {

    func testEveryPlatformHasABundledMark() {
        for platform in MediaPlatform.allCases {
            XCTAssertNotNil(BrandGlyphImage.image(for: platform),
                            "missing bundled brand mark for \(platform.displayName)")
        }
    }

    func testMarksAreTemplateImages() {
        // Template rendering is what lets the orbit dim/recolor a single asset.
        for platform in MediaPlatform.allCases {
            XCTAssertEqual(BrandGlyphImage.image(for: platform)?.isTemplate, true,
                           "\(platform.displayName) mark must be a template image")
        }
    }

    func testMarksHaveNonZeroSize() {
        for platform in MediaPlatform.allCases {
            let size = BrandGlyphImage.image(for: platform)?.size ?? .zero
            XCTAssertGreaterThan(size.width, 0, "\(platform.displayName) mark has zero width")
            XCTAssertGreaterThan(size.height, 0, "\(platform.displayName) mark has zero height")
        }
    }
}
