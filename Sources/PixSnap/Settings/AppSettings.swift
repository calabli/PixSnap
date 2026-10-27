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

    /// Whether Save asks where to put the file (on by default), or saves straight into `saveFolder`.
    var asksWhereToSave: Bool {
        didSet { defaults.set(asksWhereToSave, forKey: Keys.asksWhereToSave) }
    }

    /// Whether every capture is kept in history (on by default).
    var savesHistory: Bool {
        didSet { defaults.set(savesHistory, forKey: Keys.savesHistory) }
    }

    /// Days to keep captures in history; nil keeps them forever. Favorites are always kept.
    var historyRetentionDays: Int? {
        didSet { defaults.set(historyRetentionDays ?? 0, forKey: Keys.historyRetentionDays) }
    }

    static let historyRetentionChoices: [Int?] = [7, 30, 90, nil]

    /// Whether pulling down from the notch (or the bar at the top of other screens) opens the clothesline.
    var pullsHistoryFromNotch: Bool {
        didSet { defaults.set(pullsHistoryFromNotch, forKey: Keys.pullsHistoryFromNotch) }
    }

    /// How the clothesline ropes look.
    var ropeStyle: RopeStyle {
        didSet { if let data = try? JSONEncoder().encode(ropeStyle) { defaults.set(data, forKey: Keys.ropeStyle) } }
    }

    private(set) var launchAtLoginStatus: SMAppService.Status

    static let defaultSaveFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PixSnap", isDirectory: true)

    private let defaults: UserDefaults

    private enum Keys {
        static let captureShortcut = "captureShortcut"
        static let copiesAfterCapture = "copiesAfterCapture"
        static let saveFolderPath = "saveFolderPath"
        static let asksWhereToSave = "asksWhereToSave"
        static let savesHistory = "savesHistory"
        /// 0 means forever.
        static let historyRetentionDays = "historyRetentionDays"
        static let pullsHistoryFromNotch = "pullsHistoryFromNotch"
        static let ropeStyle = "ropeStyle"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        captureShortcut = defaults.data(forKey: Keys.captureShortcut)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .defaultCapture
        copiesAfterCapture = defaults.bool(forKey: Keys.copiesAfterCapture)
        saveFolder = defaults.string(forKey: Keys.saveFolderPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultSaveFolder
        asksWhereToSave = defaults.object(forKey: Keys.asksWhereToSave) as? Bool ?? true
        savesHistory = defaults.object(forKey: Keys.savesHistory) as? Bool ?? true
        let days = defaults.object(forKey: Keys.historyRetentionDays) as? Int ?? 30
        historyRetentionDays = days > 0 ? days : nil
        pullsHistoryFromNotch = defaults.object(forKey: Keys.pullsHistoryFromNotch) as? Bool ?? true
        ropeStyle = defaults.data(forKey: Keys.ropeStyle)
            .flatMap { try? JSONDecoder().decode(RopeStyle.self, from: $0) } ?? .default
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
