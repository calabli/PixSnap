import XCTest
@testable import PixSnapCore

final class HistoryGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func entry(_ text: String) -> HistoryEntry {
        HistoryEntry(createdAt: date(text), pixelWidth: 100, pixelHeight: 100, scale: 2)
    }

    func testGroupsByDayNewestDayFirstOldestEntryFirst() {
        let now = date("2026-10-27 16:00")
        let entries = [
            entry("2026-10-27 09:10"), entry("2026-10-25 20:00"), entry("2026-10-27 15:30"),
            entry("2026-10-26 23:59"), entry("2026-10-27 00:01"), entry("2025-12-31 12:00"),
        ]
        let days = HistoryGrouping.days(entries, now: now, calendar: calendar, limit: 10)

        XCTAssertEqual(days.map(\.title), ["今天", "昨天", "10月25日", "2025年12月31日"])
        XCTAssertEqual(days[0].entries.map(\.createdAt), [date("2026-10-27 00:01"), date("2026-10-27 09:10"), date("2026-10-27 15:30")])
    }

    func testLimitKeepsTheMostRecentDays() {
        let now = date("2026-10-27 16:00")
        let entries = [entry("2026-10-20 10:00"), entry("2026-10-21 10:00"), entry("2026-10-27 10:00")]
        XCTAssertEqual(HistoryGrouping.days(entries, now: now, calendar: calendar, limit: 2).map(\.title), ["今天", "10月21日"])
        XCTAssertTrue(HistoryGrouping.days([], now: now, calendar: calendar, limit: 3).isEmpty)
    }
}
