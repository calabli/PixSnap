import Foundation

/// Names saved captures like "PixSnap 2026-10-27 14.32.05.png", adding " (2)", " (3)"… on collisions.
public enum CaptureFileNamer {
    public static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "PixSnap \(formatter.string(from: date))"
    }

    public static func uniqueURL(
        in folder: URL,
        for date: Date,
        timeZone: TimeZone = .current,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = baseName(for: date, timeZone: timeZone)
        var url = folder.appendingPathComponent("\(base).png")
        var counter = 2
        while fileExists(url) {
            url = folder.appendingPathComponent("\(base) (\(counter)).png")
            counter += 1
        }
        return url
    }
}
