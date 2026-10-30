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

    func testFewPhotosHangLargeButNeverBeyondTheirOwnSize() {
        // One big capture: as tall as allowed.
        XCTAssertEqual(ClotheslineLayout.photoSizes(pointSizes: [CGSize(width: 1600, height: 900)], ropeLength: 3000, maxHeight: 400),
                       [CGSize(width: 711, height: 400)])
        // A small capture stays its own size.
        XCTAssertEqual(ClotheslineLayout.photoSizes(pointSizes: [CGSize(width: 300, height: 120)], ropeLength: 3000, maxHeight: 400),
                       [CGSize(width: 300, height: 120)])
    }

    func testManyPhotosShrinkToShareTheRope() {
        let sources = Array(repeating: CGSize(width: 1600, height: 1000), count: 10)
        let sizes = ClotheslineLayout.photoSizes(pointSizes: sources, ropeLength: 2000, maxHeight: 400)
        XCTAssertEqual(sizes.count, 10)
        let used = sizes.reduce(ClotheslineLayout.minimumGap) { $0 + $1.width + ClotheslineLayout.minimumGap }
        XCTAssertLessThanOrEqual(used, 2000)
        // Nearly all of the rope is used, at one height for all.
        XCTAssertGreaterThan(used, 1980)
        XCTAssertEqual(Set(sizes.map(\.height)).count, 1)
    }

    func testOldestDropOffWhenEvenSmallOnesDontFit() {
        let sources = Array(repeating: CGSize(width: 1600, height: 1000), count: 40)
        let sizes = ClotheslineLayout.photoSizes(pointSizes: sources, ropeLength: 1000, maxHeight: 400, padding: 16)
        XCTAssertLessThan(sizes.count, 40)
        XCTAssertGreaterThan(sizes.count, 0)
        // The ones left may grow a little into the room the dropped ones leave.
        XCTAssertGreaterThanOrEqual(sizes.first?.height ?? 0, ClotheslineLayout.minimumRowHeight)
        XCTAssertLessThan(sizes.first?.height ?? .infinity, ClotheslineLayout.minimumRowHeight * 1.5)
    }

    func testWidePanoramasLeaveRoomForOthers() {
        let sizes = ClotheslineLayout.photoSizes(pointSizes: [CGSize(width: 5000, height: 300), CGSize(width: 400, height: 400)],
                                                 ropeLength: 2000, maxHeight: 400)
        XCTAssertLessThanOrEqual(sizes[0].width, 900)
        XCTAssertEqual(sizes[1], CGSize(width: 400, height: 400))
    }

    private func shots(_ count: Int, minutesFrom start: Int = 0) -> [HistoryEntry] {
        (0..<count).map { HistoryEntry(createdAt: Date(timeIntervalSince1970: Double(start + $0) * 60), pixelWidth: 400, pixelHeight: 400, scale: 2) }
    }

    func testFittingCountKeepsNewestThatFit() {
        // 200pt squares at 80pt: each takes 80 + 32 gap, plus the first gap: 4 fit in 480.
        let sizes = Array(repeating: CGSize(width: 200, height: 200), count: 10)
        XCTAssertEqual(ClotheslineLayout.fittingCount(pointSizes: sizes, ropeLength: 480, height: 80), 4)
        XCTAssertEqual(ClotheslineLayout.fittingCount(pointSizes: sizes, ropeLength: 10, height: 80), 1)
    }

    func testFullDayCarriesOnToMoreRopesNewestFirst() {
        let today = shots(10, minutesFrom: 100)
        let yesterday = shots(2)
        let ropes = ClotheslineLayout.ropes([HistoryGrouping.Day(title: "今天", entries: today),
                                             HistoryGrouping.Day(title: "昨天", entries: yesterday)],
                                            ropeLength: 480, height: 80)
        XCTAssertEqual(ropes.map(\.title), ["今天", "今天", "今天", "昨天"])
        XCTAssertEqual(ropes.map(\.continued), [false, true, true, false])
        XCTAssertEqual(ropes.map(\.entries.count), [4, 4, 2, 2])
        // The newest on top, at the right end; nothing left out.
        XCTAssertEqual(ropes[0].entries, Array(today.suffix(4)))
        XCTAssertEqual(ropes[2].entries, Array(today.prefix(2)))
        XCTAssertEqual(Set(ropes.flatMap(\.entries).map(\.id)).count, 12)
    }
}

