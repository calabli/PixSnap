import AppKit
import ImageIO
import Observation
import PixSnapCore
import UniformTypeIdentifiers

/// Every capture, kept on this Mac in ~/Library/Application Support/PixSnap/History:
/// `originals/<id>.heic` (or .png where HEIC can't be written), `thumbnails/<id>.jpg`, and the
/// index in `history.sqlite`. Images are encoded off the main thread; the index is tiny and
/// queried on the main thread.
@MainActor
@Observable
final class HistoryLibrary {
    static let shared = HistoryLibrary()

    /// Goes up whenever captures are added or removed, so views showing counts can refresh.
    private(set) var revision = 0

    let folder: URL
    @ObservationIgnored private let originals: URL
    @ObservationIgnored private let thumbnails: URL
    @ObservationIgnored private let database: HistoryDatabase?
    @ObservationIgnored private let settings = AppSettings.shared

    private init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PixSnap/History", isDirectory: true)
        originals = folder.appendingPathComponent("originals", isDirectory: true)
        thumbnails = folder.appendingPathComponent("thumbnails", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
            database = try HistoryDatabase(url: folder.appendingPathComponent("history.sqlite"))
        } catch {
            NSLog("PixSnap history is unavailable: \(error)")
            database = nil
        }
    }

    // MARK: Adding

    /// Saves `capture` when history is on. Encoding a full Retina screen takes a few hundred
    /// milliseconds, so it happens in the background.
    func add(_ capture: Capture, sourceApp: NSRunningApplication?) {
        guard settings.savesHistory, let database else { return }
        let entry = HistoryEntry(
            createdAt: capture.date,
            pixelWidth: capture.image.width,
            pixelHeight: capture.image.height,
            scale: capture.scale,
            sourceAppName: sourceApp?.localizedName,
            sourceBundleID: sourceApp?.bundleIdentifier
        )
        let image = SendableImage(image: capture.image)
        let originals = originals, thumbnails = thumbnails
        Task {
            let written = await Task.detached(priority: .utility) {
                HistoryFiles.write(image.image, id: entry.id, originals: originals, thumbnails: thumbnails)
            }.value
            guard written else { return }
            do {
                try database.insert(entry)
            } catch {
                NSLog("PixSnap could not record a capture in history: \(error)")
                HistoryFiles.remove(id: entry.id, originals: originals, thumbnails: thumbnails)
                return
            }
            cleanUp()
            revision += 1
        }
    }

    // MARK: Reading

    func recent(limit: Int) -> [HistoryEntry] {
        (try? database?.recent(limit: limit)) ?? []
    }

    /// Captures on the lines, not counting the basket.
    var count: Int { (try? database?.count()) ?? 0 }

    /// The laundry basket, most recently thrown first.
    func basket() -> [HistoryEntry] {
        (try? database?.basket()) ?? []
    }

    func thumbnail(for entry: HistoryEntry) -> NSImage? {
        NSImage(contentsOf: thumbnails.appendingPathComponent("\(entry.id.uuidString).jpg"))
    }

    func loadCapture(_ entry: HistoryEntry) -> Capture? {
        guard let url = HistoryFiles.originalURL(id: entry.id, in: originals),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Capture(image: image, scale: entry.scale)
    }

    /// Bytes used by all history files.
    func diskUsage() -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize } }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }

    // MARK: The laundry basket

    /// Days a capture stays in the basket before it's emptied for good.
    static let basketDays = 7

    /// Takes captures off the line into the basket, where they can still be restored.
    func throwIntoBasket(_ entries: [HistoryEntry]) {
        setTrashed(Date(), entries)
    }

    /// Hangs captures from the basket back on the line.
    func restore(_ entries: [HistoryEntry]) {
        setTrashed(nil, entries)
    }

    /// Deletes everything in the basket for good.
    func emptyBasket() {
        remove(basket().map(\.id))
    }

    private func setTrashed(_ date: Date?, _ entries: [HistoryEntry]) {
        do {
            try database?.setTrashed(date, ids: entries.map(\.id))
        } catch {
            NSLog("PixSnap could not update the basket: \(error)")
            return
        }
        revision += 1
    }

    // MARK: Removing

    /// Removes captures older than the retention period, except favorites, and basket captures
    /// thrown more than `basketDays` ago.
    func cleanUp() {
        guard let database else { return }
        var expired = (try? database.ids(trashedBefore: Date().addingTimeInterval(-Double(Self.basketDays) * 24 * 60 * 60))) ?? []
        if let days = settings.historyRetentionDays {
            let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
            expired += (try? database.ids(createdBefore: cutoff)) ?? []
        }
        guard !expired.isEmpty else { return }
        remove(Array(Set(expired)))
    }

    /// Removes everything, favorites included.
    func removeAll() {
        guard let ids = try? database?.allIDs() else { return }
        remove(ids)
    }

    private func remove(_ ids: [UUID]) {
        do {
            try database?.delete(ids: ids)
        } catch {
            NSLog("PixSnap could not remove captures from history: \(error)")
            return
        }
        ids.forEach { HistoryFiles.remove(id: $0, originals: originals, thumbnails: thumbnails) }
        revision += 1
    }
}

/// CGImage is immutable, so handing it to the encoding task is safe.
private struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

/// File work, kept off the main actor.
private enum HistoryFiles {
    /// Longest side of a thumbnail, in pixels.
    static let thumbnailPixelSize = 480

    static func originalURL(id: UUID, in folder: URL) -> URL? {
        ["heic", "png"].map { folder.appendingPathComponent("\(id.uuidString).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Writes the original (HEIC, falling back to PNG) and a JPEG thumbnail. Returns false if either fails.
    static func write(_ image: CGImage, id: UUID, originals: URL, thumbnails: URL) -> Bool {
        let heic = originals.appendingPathComponent("\(id.uuidString).heic")
        let original = encode(image, to: heic, type: .heic, quality: 0.92) ? heic
            : originals.appendingPathComponent("\(id.uuidString).png")
        if original.pathExtension == "png", !encode(image, to: original, type: .png, quality: nil) { return false }

        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else {
            try? FileManager.default.removeItem(at: original)
            return false
        }
        let thumbnailURL = thumbnails.appendingPathComponent("\(id.uuidString).jpg")
        guard encode(thumbnail, to: thumbnailURL, type: .jpeg, quality: 0.8) else {
            try? FileManager.default.removeItem(at: original)
            return false
        }
        return true
    }

    static func remove(id: UUID, originals: URL, thumbnails: URL) {
        for name in ["\(id.uuidString).heic", "\(id.uuidString).png"] {
            try? FileManager.default.removeItem(at: originals.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: thumbnails.appendingPathComponent("\(id.uuidString).jpg"))
    }

    private static func encode(_ image: CGImage, to url: URL, type: UTType, quality: Double?) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }
}
