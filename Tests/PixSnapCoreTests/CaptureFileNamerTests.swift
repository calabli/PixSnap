import XCTest
@testable import PixSnapCore

final class CaptureFileNamerTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let date = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26 07.33.20 UTC

    func testBaseNameUsesSortableTimestamp() {
        XCTAssertEqual(CaptureFileNamer.baseName(for: date, timeZone: utc), "PixSnap 2026-10-26 07.33.20")
    }

    func testUniqueURLAddsCounterOnCollision() {
        let folder = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let taken: Set<String> = ["PixSnap 2026-10-26 07.33.20.png", "PixSnap 2026-10-26 07.33.20 (2).png"]
        let url = CaptureFileNamer.uniqueURL(in: folder, for: date, timeZone: utc) { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(url.lastPathComponent, "PixSnap 2026-10-26 07.33.20 (3).png")
    }
}
