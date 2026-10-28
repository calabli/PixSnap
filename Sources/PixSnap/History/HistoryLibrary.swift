import AVFoundation
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
    /// Favorites set while a new capture was still being written, applied once it's recorded.
    @ObservationIgnored private var pendingFavorites: [UUID: Bool] = [:]
    @ObservationIgnored private var pendingIDs: Set<UUID> = []
    /// Captures deleted while still being written: dropped once the write finishes.
    @ObservationIgnored private var pendingDeletions: Set<UUID> = []

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

    /// Saves `capture` when history is on, and returns its entry right away so the capture on screen
    /// can refer to it. Encoding a full Retina screen takes a few hundred milliseconds, so it
    /// happens in the background.
    @discardableResult
    func add(_ capture: Capture, sourceApp: NSRunningApplication?) -> HistoryEntry? {
        guard settings.savesHistory, let database else { return nil }
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
        pendingIDs.insert(entry.id)
        Task {
            defer { pendingIDs.remove(entry.id) }
            let written = await Task.detached(priority: .utility) {
                HistoryFiles.write(image.image, id: entry.id, originals: originals, thumbnails: thumbnails)
            }.value
            guard written else { return }
            if pendingDeletions.remove(entry.id) != nil {
                HistoryFiles.remove(id: entry.id, originals: originals, thumbnails: thumbnails)
                return
            }
            do {
                var recorded = entry
                if let favorite = pendingFavorites.removeValue(forKey: entry.id) { recorded.isFavorite = favorite }
                try database.insert(recorded)
            } catch {
                NSLog("PixSnap could not record a capture in history: \(error)")
                HistoryFiles.remove(id: entry.id, originals: originals, thumbnails: thumbnails)
                return
            }
            cleanUp()
            revision += 1
            await recognizeText(of: entry.id, in: image.image)
        }
        return entry
    }

    // MARK: Recordings

    /// Keeps a screen recording in history: the MP4 moves in next to the screenshots, and a still
    /// poster and a small looping thumbnail (for the clothesline) are made in the background. Returns
    /// its entry right away, or nil when history is off (the file then stays where it is).
    @discardableResult
    func addRecording(_ video: URL, duration: Double, pixelSize: CGSize, scale: CGFloat, sourceApp: NSRunningApplication?) -> HistoryEntry? {
        guard settings.savesHistory, let database else { return nil }
        let entry = HistoryEntry(createdAt: Date(), pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height), scale: scale,
                                 sourceAppName: sourceApp?.localizedName, sourceBundleID: sourceApp?.bundleIdentifier,
                                 recordingDuration: duration)
        let stored = HistoryFiles.videoURL(id: entry.id, in: originals)
        do {
            try FileManager.default.moveItem(at: video, to: stored)
        } catch {
            NSLog("PixSnap could not keep a recording in history: \(error)")
            return nil
        }
        let thumbnails = thumbnails, originals = originals
        pendingIDs.insert(entry.id)
        Task {
            defer { pendingIDs.remove(entry.id) }
            do {
                try await HistoryFiles.writeRecordingThumbnails(stored, duration: duration, id: entry.id, thumbnails: thumbnails)
            } catch {
                NSLog("PixSnap could not make a recording's thumbnails: \(error)")
            }
            if pendingDeletions.remove(entry.id) != nil {
                HistoryFiles.remove(id: entry.id, originals: originals, thumbnails: thumbnails)
                return
            }
            do {
                var recorded = entry
                if let favorite = pendingFavorites.removeValue(forKey: entry.id) { recorded.isFavorite = favorite }
                try database.insert(recorded)
            } catch {
                NSLog("PixSnap could not record a recording in history: \(error)")
                HistoryFiles.remove(id: entry.id, originals: originals, thumbnails: thumbnails)
                return
            }
            cleanUp()
            revision += 1
            if let poster = thumbnail(for: entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                await recognizeText(of: entry.id, in: poster)
            }
        }
        return entry
    }

    // MARK: Text

    /// Finds the text in a capture and stores it for search, when Settings allows.
    private func recognizeText(of id: UUID, in image: CGImage) async {
        guard settings.recognizesText else { return }
        let text = await TextRecognizer.text(in: image)
        do {
            try database?.setRecognizedText(text, id: id)
            revision += 1
        } catch {
            NSLog("PixSnap could not store recognized text: \(error)")
        }
    }

    private var isRecognizingBacklog = false

    /// Works through captures taken before text recognition (or while it was off), newest first,
    /// one at a time in the background.
    func recognizeMissingText() {
        guard settings.recognizesText, !isRecognizingBacklog, let database else { return }
        isRecognizingBacklog = true
        Task {
            defer { isRecognizingBacklog = false }
            while settings.recognizesText, let ids = try? database.idsAwaitingRecognition(limit: 10), !ids.isEmpty {
                for id in ids {
                    guard settings.recognizesText, let entry = try? database.entry(id: id) else { continue }
                    // A recording is searched by its poster; a capture whose files are gone gets "".
                    let image = entry.isRecording ? thumbnail(for: entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                                                  : loadCapture(entry)?.image
                    if let image {
                        await recognizeText(of: id, in: image)
                    } else {
                        try? database.setRecognizedText("", id: id)
                    }
                }
            }
        }
    }

    /// Captures whose text or app name has every word of `text`, newest first.
    func search(_ text: String, limit: Int) -> [HistoryEntry] {
        (try? database?.search(text, limit: limit)) ?? []
    }

    /// The text found in a capture, recognizing it now if that hasn't happened yet.
    func recognizedText(for entry: HistoryEntry) async -> String {
        if let stored = (try? database?.entry(id: entry.id))??.ocrText { return stored }
        let image = entry.isRecording ? thumbnail(for: entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil) : loadCapture(entry)?.image
        guard let image else { return "" }
        let text = await TextRecognizer.text(in: image)
        try? database?.setRecognizedText(text, id: entry.id)
        return text
    }

    /// A recording's MP4.
    func videoURL(for entry: HistoryEntry) -> URL? {
        let url = HistoryFiles.videoURL(id: entry.id, in: originals)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A recording's small looping thumbnail: its frames and how long each shows.
    func movingThumbnail(for entry: HistoryEntry) -> (frames: [CGImage], delay: Double)? {
        guard entry.isRecording,
              let source = CGImageSourceCreateWithURL(thumbnails.appendingPathComponent("\(entry.id.uuidString).gif") as CFURL, nil) else { return nil }
        let frames = (0 ..< CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let delay = (properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.12
        return frames.count > 1 ? (frames, delay) : nil
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

    /// An image sharp enough to show at `pixelSize` (its longest side): the stored thumbnail when
    /// that's enough, otherwise scaled down from the original.
    func image(for entry: HistoryEntry, pixelSize: CGFloat) -> CGImage? {
        if pixelSize <= CGFloat(HistoryFiles.thumbnailPixelSize) || HistoryFiles.originalURL(id: entry.id, in: originals) == nil {
            return thumbnail(for: entry)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let url = HistoryFiles.originalURL(id: entry.id, in: originals),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(pixelSize.rounded(.up)),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
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

    /// The app a capture was taken from, if history knows it.
    func sourceAppName(for id: UUID) -> String? {
        (try? database?.entry(id: id))??.sourceAppName
    }

    // MARK: Favorites

    /// Favorites are never cleaned up automatically and can't be thrown into the basket.
    func isFavorite(_ id: UUID) -> Bool {
        pendingFavorites[id] ?? (try? database?.entry(id: id))??.isFavorite ?? false
    }

    func setFavorite(_ isFavorite: Bool, id: UUID) {
        if pendingIDs.contains(id) {
            pendingFavorites[id] = isFavorite
            return
        }
        do {
            try database?.setFavorite(isFavorite, id: id)
        } catch {
            NSLog("PixSnap could not update a favorite: \(error)")
            return
        }
        revision += 1
    }

    var favoriteCount: Int { (try? database?.favoriteCount()) ?? 0 }

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

    /// Deletes captures for good, skipping the basket: the record and both image files. Files
    /// saved elsewhere with 保存 aren't touched.
    func deletePermanently(_ ids: [UUID]) {
        let writing = ids.filter { pendingIDs.contains($0) }
        pendingDeletions.formUnion(writing)
        writing.forEach { pendingFavorites[$0] = nil }
        remove(ids.filter { !pendingIDs.contains($0) })
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
        for name in ["\(id.uuidString).heic", "\(id.uuidString).png", "\(id.uuidString).mp4"] {
            try? FileManager.default.removeItem(at: originals.appendingPathComponent(name))
        }
        for name in ["\(id.uuidString).jpg", "\(id.uuidString).gif"] {
            try? FileManager.default.removeItem(at: thumbnails.appendingPathComponent(name))
        }
    }

    static func videoURL(id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(id.uuidString).mp4")
    }

    /// A recording's poster (its first frame, as big as a large photo on the line needs) and its
    /// looping thumbnail (8 frames a second, the first 10 seconds, up to 480 pixels wide).
    @MainActor
    static func writeRecordingThumbnails(_ video: URL, duration: Double, id: UUID, thumbnails: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.appliesPreferredTrackTransform = true
        let (poster, _) = try await generator.image(at: .zero)
        let posterURL = thumbnails.appendingPathComponent("\(id.uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(posterURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, poster, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try await GIFExporter.export(video, duration: duration, to: thumbnails.appendingPathComponent("\(id.uuidString).gif"),
                                     fps: 8, maxWidth: 480, maxDuration: 10)
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
