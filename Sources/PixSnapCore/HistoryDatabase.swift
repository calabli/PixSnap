#if canImport(SQLite3)
import Foundation
import SQLite3

/// One saved capture. The images live next to the database as files named by `id`.
public struct HistoryEntry: Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point of the screen it was taken on.
    public var scale: Double
    public var sourceAppName: String?
    public var sourceBundleID: String?
    /// Favorites are never removed by automatic cleanup.
    public var isFavorite: Bool
    /// Filled in later by text recognition, for search.
    public var ocrText: String?
    /// When it was thrown into the laundry basket; nil while it hangs on the line. Basket entries
    /// are left out of `recent` and `count` until restored, and emptied for good later.
    public var trashedAt: Date?
    /// For a screen recording, its length in seconds; nil for a screenshot. A recording's file is
    /// an MP4 next to the others, with a still poster and a small moving thumbnail.
    public var recordingDuration: Double?

    public var isRecording: Bool { recordingDuration != nil }

    public init(
        id: UUID = UUID(), createdAt: Date, pixelWidth: Int, pixelHeight: Int, scale: Double,
        sourceAppName: String? = nil, sourceBundleID: String? = nil, isFavorite: Bool = false, ocrText: String? = nil,
        trashedAt: Date? = nil, recordingDuration: Double? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.isFavorite = isFavorite
        self.ocrText = ocrText
        self.trashedAt = trashedAt
        self.recordingDuration = recordingDuration
    }
}

public struct HistoryDatabaseError: Error, CustomStringConvertible {
    public let description: String
}

/// The capture history index, a small SQLite database. SQLite rather than a platform store keeps the
/// format readable by other platforms. Not thread-safe: use it from one thread or actor.
public final class HistoryDatabase {
    private var handle: OpaquePointer?

    public init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(handle)
            handle = nil
            throw HistoryDatabaseError(description: message)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS captures (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                scale REAL NOT NULL,
                source_app_name TEXT,
                source_bundle_id TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                ocr_text TEXT
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS captures_created_at ON captures (created_at)")
        try migrate()
    }

    /// Schema changes since the first version, tracked in `user_version`.
    private func migrate() throws {
        var version = 0
        try step("PRAGMA user_version", []) { version = Int(sqlite3_column_int64($0, 0)) }
        if version < 1 {
            // 1: the laundry basket.
            try execute("ALTER TABLE captures ADD COLUMN trashed_at REAL")
            try execute("PRAGMA user_version = 1")
        }
        if version < 2 {
            // 2: screen recordings.
            try execute("ALTER TABLE captures ADD COLUMN recording_duration REAL")
            try execute("PRAGMA user_version = 2")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    public func insert(_ entry: HistoryEntry) throws {
        try run("""
            INSERT INTO captures (id, created_at, pixel_width, pixel_height, scale, source_app_name, source_bundle_id, is_favorite, ocr_text,
                                  recording_duration)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [
                .text(entry.id.uuidString), .real(entry.createdAt.timeIntervalSince1970),
                .integer(entry.pixelWidth), .integer(entry.pixelHeight), .real(entry.scale),
                .optionalText(entry.sourceAppName), .optionalText(entry.sourceBundleID),
                .integer(entry.isFavorite ? 1 : 0), .optionalText(entry.ocrText),
                entry.recordingDuration.map { .real($0) } ?? .null,
            ])
    }

    /// Newest first, leaving out the basket.
    public func recent(limit: Int) throws -> [HistoryEntry] {
        try query("SELECT \(Self.columns) FROM captures WHERE trashed_at IS NULL ORDER BY created_at DESC LIMIT ?", [.integer(limit)])
    }

    /// Captures on the lines whose recognized text or source app contains every word of `text`
    /// (case doesn't matter), newest first.
    public func search(_ text: String, limit: Int) throws -> [HistoryEntry] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return try recent(limit: limit) }
        // Each word must appear in the text or the app name; LIKE's wildcards in it are taken literally.
        let condition = words.map { _ in "(ocr_text LIKE ? ESCAPE '\\' OR source_app_name LIKE ? ESCAPE '\\')" }.joined(separator: " AND ")
        let values = words.flatMap { word -> [Value] in
            let pattern = "%" + Self.escapeLike(word) + "%"
            return [.text(pattern), .text(pattern)]
        }
        return try query("SELECT \(Self.columns) FROM captures WHERE trashed_at IS NULL AND \(condition) ORDER BY created_at DESC LIMIT ?",
                         values + [.integer(limit)])
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Stores what text recognition found ("" when there was none, so it isn't tried again).
    public func setRecognizedText(_ text: String, id: UUID) throws {
        try run("UPDATE captures SET ocr_text = ? WHERE id = ?", [.text(text), .text(id.uuidString)])
    }

    /// Captures whose text hasn't been recognized yet, newest first.
    public func idsAwaitingRecognition(limit: Int) throws -> [UUID] {
        try ids("SELECT id FROM captures WHERE ocr_text IS NULL ORDER BY created_at DESC LIMIT ?", [.integer(limit)])
    }

    /// What's in the laundry basket, most recently thrown first.
    public func basket() throws -> [HistoryEntry] {
        try query("SELECT \(Self.columns) FROM captures WHERE trashed_at IS NOT NULL ORDER BY trashed_at DESC", [])
    }

    public func entry(id: UUID) throws -> HistoryEntry? {
        try query("SELECT \(Self.columns) FROM captures WHERE id = ?", [.text(id.uuidString)]).first
    }

    public func count() throws -> Int {
        var total = 0
        try step("SELECT COUNT(*) FROM captures WHERE trashed_at IS NULL", []) { total = Int(sqlite3_column_int64($0, 0)) }
        return total
    }

    /// Favorites on the lines, not counting the basket.
    public func favoriteCount() throws -> Int {
        var total = 0
        try step("SELECT COUNT(*) FROM captures WHERE is_favorite = 1 AND trashed_at IS NULL", []) { total = Int(sqlite3_column_int64($0, 0)) }
        return total
    }

    public func setFavorite(_ isFavorite: Bool, id: UUID) throws {
        try run("UPDATE captures SET is_favorite = ? WHERE id = ?", [.integer(isFavorite ? 1 : 0), .text(id.uuidString)])
    }

    /// Into the basket at `date`, or back on the line with nil.
    public func setTrashed(_ date: Date?, ids: [UUID]) throws {
        try transaction {
            for id in ids {
                try run("UPDATE captures SET trashed_at = ? WHERE id = ?", [date.map { .real($0.timeIntervalSince1970) } ?? .null, .text(id.uuidString)])
            }
        }
    }

    /// IDs of basket entries thrown before `date`.
    public func ids(trashedBefore date: Date) throws -> [UUID] {
        try ids("SELECT id FROM captures WHERE trashed_at < ?", [.real(date.timeIntervalSince1970)])
    }

    /// IDs of entries taken before `date`; favorites are left out unless asked for.
    public func ids(createdBefore date: Date, includingFavorites: Bool = false) throws -> [UUID] {
        let sql = "SELECT id FROM captures WHERE created_at < ?" + (includingFavorites ? "" : " AND is_favorite = 0")
        return try ids(sql, [.real(date.timeIntervalSince1970)])
    }

    public func allIDs() throws -> [UUID] {
        try ids(createdBefore: .distantFuture, includingFavorites: true)
    }

    public func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            for id in ids { try run("DELETE FROM captures WHERE id = ?", [.text(id.uuidString)]) }
        }
    }

    // MARK: SQLite plumbing

    private static let columns =
        "id, created_at, pixel_width, pixel_height, scale, source_app_name, source_bundle_id, is_favorite, ocr_text, trashed_at, recording_duration"

    private enum Value {
        case text(String)
        case optionalText(String?)
        case integer(Int)
        case real(Double)
        case null
    }

    /// Tells SQLite to copy bound strings, since Swift's buffers don't outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func ids(_ sql: String, _ values: [Value]) throws -> [UUID] {
        var ids: [UUID] = []
        try step(sql, values) { statement in
            if let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) { ids.append(id) }
        }
        return ids
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        try step(sql, values) { _ in }
    }

    private func query(_ sql: String, _ values: [Value]) throws -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        try step(sql, values) { statement in
            if let entry = Self.entry(from: statement) { entries.append(entry) }
        }
        return entries
    }

    /// Prepares `sql`, binds `values`, and calls `row` for every result row.
    private func step(_ sql: String, _ values: [Value], row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .optionalText(let text):
                if let text { sqlite3_bind_text(statement, index, text, -1, Self.transient) } else { sqlite3_bind_null(statement, index) }
            case .integer(let number):
                sqlite3_bind_int64(statement, index, Int64(number))
            case .real(let number):
                sqlite3_bind_double(statement, index, number)
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return
            default: throw lastError()
            }
        }
    }

    private static func entry(from statement: OpaquePointer) -> HistoryEntry? {
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        guard let idText = text(0), let id = UUID(uuidString: idText) else { return nil }
        return HistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            pixelWidth: Int(sqlite3_column_int64(statement, 2)),
            pixelHeight: Int(sqlite3_column_int64(statement, 3)),
            scale: sqlite3_column_double(statement, 4),
            sourceAppName: text(5),
            sourceBundleID: text(6),
            isFavorite: sqlite3_column_int64(statement, 7) != 0,
            ocrText: text(8),
            trashedAt: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
            recordingDuration: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 10)
        )
    }

    private func lastError() -> HistoryDatabaseError {
        HistoryDatabaseError(description: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed")
    }
}
#endif
