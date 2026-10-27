import AppKit
import Observation
import PixSnapCore
import ServiceManagement

/// User preferences, stored in UserDefaults. Launch at login is owned by the system (SMAppService),
/// so it's read back from there instead of being stored.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var captureShortcut: Shortcut {
        didSet { save(captureShortcut, forKey: Keys.captureShortcut) }
    }

    var copiesAfterCapture: Bool {
        didSet { defaults.set(copiesAfterCapture, forKey: Keys.copiesAfterCapture) }
    }

    var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: Keys.saveFolderPath) }
    }

    private(set) var launchAtLoginStatus: SMAppService.Status

    static let defaultSaveFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PixSnap", isDirectory: true)

    private let defaults: UserDefaults

    private enum Keys {
        static let captureShortcut = "captureShortcut"
        static let copiesAfterCapture = "copiesAfterCapture"
        static let saveFolderPath = "saveFolderPath"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        captureShortcut = defaults.data(forKey: Keys.captureShortcut)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .defaultCapture
        copiesAfterCapture = defaults.bool(forKey: Keys.copiesAfterCapture)
        saveFolder = defaults.string(forKey: Keys.saveFolderPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultSaveFolder
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool { launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval }

    /// Turning it on may leave the status at `.requiresApproval` until the user allows PixSnap
    /// in System Settings › General › Login Items.
    func setLaunchesAtLogin(_ enabled: Bool) throws {
        defer { refreshLaunchAtLoginStatus() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private func save(_ shortcut: Shortcut, forKey key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
    }
}
