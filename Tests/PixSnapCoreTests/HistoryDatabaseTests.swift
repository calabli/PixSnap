#if canImport(SQLite3)
import SQLite3
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

    func testBasketHidesEntriesUntilRestored() throws {
        let database = try HistoryDatabase(url: databaseURL)
        let kept = entry(minutesAgo: 20), thrown = entry(minutesAgo: 10), later = entry(minutesAgo: 1)
        try [kept, thrown, later].forEach(database.insert)
        let throwTime = Date(timeIntervalSince1970: 1_800_000_100)
        try database.setTrashed(throwTime, ids: [thrown.id])
        try database.setTrashed(throwTime.addingTimeInterval(60), ids: [later.id])

        XCTAssertEqual(try database.recent(limit: 10).map(\.id), [kept.id])
        XCTAssertEqual(try database.count(), 1)
        // Most recently thrown first, with the time it went in.
        XCTAssertEqual(try database.basket().map(\.id), [later.id, thrown.id])
        XCTAssertEqual(try database.entry(id: thrown.id)?.trashedAt, throwTime)
        XCTAssertEqual(try database.ids(trashedBefore: throwTime.addingTimeInterval(30)), [thrown.id])

        try database.setTrashed(nil, ids: [thrown.id])
        XCTAssertEqual(try database.recent(limit: 10).map(\.id), [thrown.id, kept.id])
        XCTAssertNil(try database.entry(id: thrown.id)?.trashedAt)
    }

    func testAddsTheBasketToAFirstVersionDatabase() throws {
        // The schema as first shipped, before the basket column.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        sqlite3_exec(handle, """
            CREATE TABLE captures (id TEXT PRIMARY KEY, created_at REAL NOT NULL, pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL, scale REAL NOT NULL, source_app_name TEXT, source_bundle_id TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0, ocr_text TEXT);
            INSERT INTO captures VALUES ('\(UUID().uuidString)', 1800000000, 100, 50, 2, NULL, NULL, 0, NULL);
            """, nil, nil, nil)
        sqlite3_close(handle)

        let database = try HistoryDatabase(url: databaseURL)
        XCTAssertEqual(try database.count(), 1)
        XCTAssertNil(try database.recent(limit: 1).first?.trashedAt)
        // Opening again doesn't try to add the column twice.
        XCTAssertEqual(try HistoryDatabase(url: databaseURL).count(), 1)
    }

    func testCountsAndTogglesFavorites() throws {
        let database = try HistoryDatabase(url: databaseURL)
        let plain = entry(minutesAgo: 3), loved = entry(minutesAgo: 2, favorite: true), thrown = entry(minutesAgo: 1, favorite: true)
        try [plain, loved, thrown].forEach(database.insert)
        try database.setTrashed(Date(timeIntervalSince1970: 1_800_000_100), ids: [thrown.id])
        // The basket doesn't count.
        XCTAssertEqual(try database.favoriteCount(), 1)

        try database.setFavorite(true, id: plain.id)
        try database.setFavorite(false, id: loved.id)
        XCTAssertEqual(try database.entry(id: plain.id)?.isFavorite, true)
        XCTAssertEqual(try database.entry(id: loved.id)?.isFavorite, false)
        XCTAssertEqual(try database.favoriteCount(), 1)
    }
}
#endif
