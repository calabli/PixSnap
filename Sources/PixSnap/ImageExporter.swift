import AppKit
import PixSnapCore
import UniformTypeIdentifiers

@MainActor
enum ImageExporter {
    /// Chosen in Settings; ~/Pictures/PixSnap by default.
    static var saveFolder: URL { AppSettings.shared.saveFolder }

    /// PNG with its DPI set from the screen scale, so a Retina capture opens at its on-screen size.
    static func pngData(for capture: Capture) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72 * capture.scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, capture.image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func copyToPasteboard(_ capture: Capture) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        if let png = pngData(for: capture) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = NSImage(cgImage: capture.image, size: capture.pointSize).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// Saves into the folder chosen in Settings and returns the new file's URL.
    static func save(_ capture: Capture) throws -> URL {
        try write(capture, into: saveFolder)
    }

    /// Saves the way Settings asks: straight into the save folder, or, by default, through a
    /// "save to" panel that opens in that folder and remembers the folder picked for next time.
    /// `completion` gets the file written, or nil if the panel was cancelled.
    static func saveAsking(_ capture: Capture, completion: @escaping (Result<URL, Error>?) -> Void) {
        guard AppSettings.shared.asksWhereToSave else {
            completion(Result { try save(capture) })
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.prompt = "保存"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = saveFolder
        panel.nameFieldStringValue = CaptureFileNamer.uniqueURL(in: saveFolder, for: capture.date).lastPathComponent
        panel.level = .modalPanel
        // PixSnap has no Dock icon; without this the panel opens behind the app in front.
        NSApp.activate()
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return completion(nil) }
                completion(Result {
                    guard let png = pngData(for: capture) else { throw CocoaError(.fileWriteUnknown) }
                    try png.write(to: url, options: .atomic)
                    AppSettings.shared.saveFolder = url.deletingLastPathComponent()
                    return url
                })
            }
        }
    }

    /// Writes a file into Caches for dragging into other apps.
    static func temporaryFile(for capture: Capture) throws -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.pixsnap.PixSnap/Drag", isDirectory: true)
        return try write(capture, into: folder)
    }

    private static func write(_ capture: Capture, into folder: URL) throws -> URL {
        guard let png = pngData(for: capture) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = CaptureFileNamer.uniqueURL(in: folder, for: capture.date)
        try png.write(to: url, options: .atomic)
        return url
    }
}
