#if canImport(SQLite3)
import XCTest
@testable import PixSnapCore

final class HistoryDatabaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryDatabaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var databaseURL: URL { folder.appendingPathComponent("history.sqlite") }

    private func entry(minutesAgo: Double, favorite: Bool = false, app: String? = "微信") -> HistoryEntry {
        HistoryEntry(createdAt: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60), pixelWidth: 1200, pixelHeight: 800,
                     scale: 2, sourceAppName: app, sourceBundleID: app.map { "com.example.\($0)" }, isFavorite: favorite)
    }

    func testStoresAndReturnsNewestFirst() throws {
        let database = try HistoryDatabase(url: databaseURL)
        let old = entry(minutesAgo: 30), new = entry(minutesAgo: 1, app: nil), middle = entry(minutesAgo: 10)
        try [old, new, middle].forEach(database.insert)

        XCTAssertEqual(try database.recent(limit: 10).map(\.id), [new.id, middle.id, old.id])
        XCTAssertEqual(try database.recent(limit: 2).count, 2)
        XCTAssertEqual(try database.count(), 3)
        // Every field round-trips, including missing ones.
        XCTAssertEqual(try database.entry(id: old.id), old)
        XCTAssertEqual(try database.entry(id: new.id), new)
    }

    func testPersistsAcrossReopen() throws {
        let saved = entry(minutesAgo: 5)
        try HistoryDatabase(url: databaseURL).insert(saved)
        XCTAssertEqual(try HistoryDatabase(url: databaseURL).entry(id: saved.id), saved)
    }

    func testCleanupCandidatesSkipFavorites() throws {
        let database = try HistoryDatabase(url: databaseURL)
        let expired = entry(minutesAgo: 120), expiredFavorite = entry(minutesAgo: 120, favorite: true), fresh = entry(minutesAgo: 1)
        try [expired, expiredFavorite, fresh].forEach(database.insert)
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000 - 60 * 60)

        XCTAssertEqual(try database.ids(createdBefore: cutoff), [expired.id])
        XCTAssertEqual(Set(try database.ids(createdBefore: cutoff, includingFavorites: true)), [expired.id, expiredFavorite.id])
    }

    func testFavoriteAndDelete() throws {
        let database = try HistoryDatabase(url: databaseURL)
        let first = entry(minutesAgo: 2), second = entry(minutesAgo: 1)
        try [first, second].forEach(database.insert)

        try database.setFavorite(true, id: first.id)
        XCTAssertEqual(try database.entry(id: first.id)?.isFavorite, true)

        try database.delete(ids: [first.id])
        XCTAssertNil(try database.entry(id: first.id))
        XCTAssertEqual(try database.allIDs(), [second.id])
    }

    func testDuplicateIDIsRejected() throws {
        let database = try HistoryDatabase(url: databaseURL)
        let saved = entry(minutesAgo: 1)
        try database.insert(saved)
        XCTAssertThrowsError(try database.insert(saved))
        XCTAssertEqual(try database.count(), 1)
    }
}
#endif
