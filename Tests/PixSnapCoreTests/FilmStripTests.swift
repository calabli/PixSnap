import XCTest
@testable import PixSnapCore

final class FilmStripTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func entry(_ text: String) -> HistoryEntry {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return HistoryEntry(createdAt: formatter.date(from: text)!, pixelWidth: 200, pixelHeight: 100, scale: 2)
    }

    func testOldestDayFirstEachWithItsMarker() {
        let today1 = entry("2026-11-02 09:00"), today2 = entry("2026-11-02 15:00"), older = entry("2026-10-30 20:00")
        let items = FilmStrip.items([today2, older, today1], now: today2.createdAt.addingTimeInterval(60), calendar: calendar)
        XCTAssertEqual(items, [.day("10月30日", count: 1), .frame(older), .day("今天", count: 2), .frame(today1), .frame(today2)])
        XCTAssertTrue(FilmStrip.items([], now: Date(), calendar: calendar).isEmpty)
    }

    func testPictureWidthKeepsShapeWithinLimits() {
        XCTAssertEqual(FilmStrip.pictureWidth(pixelWidth: 1600, pixelHeight: 1000, height: 100), 160)
        XCTAssertEqual(FilmStrip.pictureWidth(pixelWidth: 8000, pixelHeight: 400, height: 100), 240)
        XCTAssertEqual(FilmStrip.pictureWidth(pixelWidth: 400, pixelHeight: 9000, height: 100), 45)
        XCTAssertEqual(FilmStrip.pictureWidth(pixelWidth: 0, pixelHeight: 0, height: 100), 100)
    }

    func testSprocketsLineUpAcrossPieces() {
        XCTAssertEqual(FilmStrip.sprocketPhase(atX: 0, pitch: 18), 0)
        XCTAssertEqual(FilmStrip.sprocketPhase(atX: 36, pitch: 18), 0)
        XCTAssertEqual(FilmStrip.sprocketPhase(atX: 40, pitch: 18), 14)
    }
}
