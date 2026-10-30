import Foundation

/// Groups history by calendar day for the clothesline: one line per day.
public enum HistoryGrouping {
    public struct Day: Equatable, Sendable {
        /// "今天", "昨天", "10月25日" or, for another year, "2025年10月25日".
        public let title: String
        /// Oldest first, so the newest hangs at the right end of the line.
        public let entries: [HistoryEntry]

        public init(title: String, entries: [HistoryEntry]) {
            self.title = title
            self.entries = entries
        }
    }

    /// The `limit` most recent days that have captures, newest day first.
    public static func days(_ entries: [HistoryEntry], now: Date, calendar: Calendar = .current, limit: Int) -> [Day] {
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.createdAt) }
        return byDay.keys.sorted(by: >).prefix(limit).map { day in
            Day(title: title(for: day, now: now, calendar: calendar),
                entries: byDay[day, default: []].sorted { $0.createdAt < $1.createdAt })
        }
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "昨天"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let monthDay = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        return parts.year == calendar.component(.year, from: now) ? monthDay : "\(parts.year ?? 0)年\(monthDay)"
    }
}
