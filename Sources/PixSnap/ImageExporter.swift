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

    /// Saves into ~/Pictures/PixSnap and returns the new file's URL.
    static func save(_ capture: Capture) throws -> URL {
        try write(capture, into: saveFolder)
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
