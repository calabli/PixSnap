import XCTest
@testable import PixSnapCore

final class ClotheslineLayoutTests: XCTestCase {
    func testPhotosKeepTheCaptureShape() {
        // Wide: limited by the box width.
        XCTAssertEqual(ClotheslineLayout.photoSize(pixelWidth: 2560, pixelHeight: 1440), CGSize(width: 150, height: 84))
        // Square and tall: limited by the box height.
        XCTAssertEqual(ClotheslineLayout.photoSize(pixelWidth: 500, pixelHeight: 500), CGSize(width: 90, height: 90))
        XCTAssertEqual(ClotheslineLayout.photoSize(pixelWidth: 900, pixelHeight: 1600), CGSize(width: 51, height: 90))
    }

    func testSliversAreWidenedToTheMinimum() {
        XCTAssertEqual(ClotheslineLayout.photoSize(pixelWidth: 3000, pixelHeight: 60), CGSize(width: 150, height: 26))
        XCTAssertEqual(ClotheslineLayout.photoSize(pixelWidth: 0, pixelHeight: 0), ClotheslineLayout.maximumPhotoSize)
    }

    func testKeepsTheNewestPhotosThatFit() {
        // 18 + (100 + 18) * 3 = 372: three fit in 400, not four.
        XCTAssertEqual(ClotheslineLayout.fittingCount(widths: [100, 100, 100, 100], length: 400), 3)
        // The newest is at the end; a wide one there leaves room for fewer.
        XCTAssertEqual(ClotheslineLayout.fittingCount(widths: [50, 50, 300], length: 400), 1)
        XCTAssertEqual(ClotheslineLayout.fittingCount(widths: [], length: 400), 0)
    }

    func testSpreadsPhotosWithEqualGaps() {
        // 1000 - 300 = 700 of space, in 4 gaps of 175.
        XCTAssertEqual(ClotheslineLayout.centers(widths: [100, 100, 100], length: 1000), [225, 500, 775])
        XCTAssertEqual(ClotheslineLayout.centers(widths: [200], length: 1000), [500])
    }

    func testPreviewFitsWithoutEnlarging() {
        let bounds = CGSize(width: 1600, height: 1000)
        XCTAssertEqual(ClotheslineLayout.previewSize(imageSize: CGSize(width: 3200, height: 1000), bounds: bounds), CGSize(width: 1600, height: 500))
        XCTAssertEqual(ClotheslineLayout.previewSize(imageSize: CGSize(width: 400, height: 300), bounds: bounds), CGSize(width: 400, height: 300))
    }
}
