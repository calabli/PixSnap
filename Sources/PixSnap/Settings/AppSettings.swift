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

    /// Each capture mode's global shortcut.
    var shortcuts: [CaptureAction: Shortcut] {
        didSet { saveShortcuts() }
    }

    /// Region capture's shortcut, the one most places mention.
    var captureShortcut: Shortcut { shortcut(for: .region) }

    func shortcut(for action: CaptureAction) -> Shortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// Seconds of countdown before a delayed capture.
    var captureDelay: Int {
        didSet { defaults.set(captureDelay, forKey: Keys.captureDelay) }
    }

    static let captureDelayChoices = [3, 5, 10]

    /// Whether the text in captures is recognized (on this Mac) so history can be searched.
    var recognizesText: Bool {
        didSet { defaults.set(recognizesText, forKey: Keys.recognizesText) }
    }

    /// Frames per second for screen recordings.
    var recordingFPS: Int {
        didSet { defaults.set(recordingFPS, forKey: Keys.recordingFPS) }
    }

    static let recordingFPSChoices = [30, 60]

    /// Whether recordings show the mouse pointer (on by default).
    var recordsCursor: Bool {
        didSet { defaults.set(recordsCursor, forKey: Keys.recordsCursor) }
    }

    /// Whether recordings take in the sound the Mac plays.
    var recordsSystemAudio: Bool {
        didSet { defaults.set(recordsSystemAudio, forKey: Keys.recordsSystemAudio) }
    }

    /// Whether recordings take in the microphone (macOS 15 and later).
    var recordsMicrophone: Bool {
        didSet { defaults.set(recordsMicrophone, forKey: Keys.recordsMicrophone) }
    }

    /// Whether clicks show as a ring in recordings.
    var highlightsClicks: Bool {
        didSet { defaults.set(highlightsClicks, forKey: Keys.highlightsClicks) }
    }

    /// Whether shortcuts pressed while recording show at the bottom of the region.
    var showsKeystrokes: Bool {
        didSet { defaults.set(showsKeystrokes, forKey: Keys.showsKeystrokes) }
    }

    /// 讲解模式: a recording meant to explain something. It opens 精修 when done (zooms, pointer and
    /// keys are added there rather than drawn live), after a 3-second countdown.
    var recordsTutorial: Bool {
        didSet { defaults.set(recordsTutorial, forKey: Keys.recordsTutorial) }
    }

    /// The microphone to record, by its unique ID; nil for the Mac's default.
    var microphoneID: String? {
        didSet { defaults.set(microphoneID, forKey: Keys.microphoneID) }
    }

    /// Whether notification banners are left out of recordings (on by default).
    var hidesNotificationsInRecordings: Bool {
        didSet { defaults.set(hidesNotificationsInRecordings, forKey: Keys.hidesNotificationsInRecordings) }
    }

    /// Whether a round camera bubble sits in the corner of recordings.
    var showsCameraBubble: Bool {
        didSet { defaults.set(showsCameraBubble, forKey: Keys.showsCameraBubble) }
    }

    /// In 讲解模式, whether the step-by-step guide opens beside 精修 when done.
    var opensGuideAfterTutorial: Bool {
        didSet { defaults.set(opensGuideAfterTutorial, forKey: Keys.opensGuideAfterTutorial) }
    }

    /// Shadow and background for window captures.
    var windowCaptureStyle: WindowCaptureStyle {
        didSet { if let data = try? JSONEncoder().encode(windowCaptureStyle) { defaults.set(data, forKey: Keys.windowCaptureStyle) } }
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

    /// How big the pull-down handle is.
    var notchHandleSize: NotchHandleSize {
        didSet { defaults.set(notchHandleSize.rawValue, forKey: Keys.notchHandleSize) }
    }

    /// On the notch, or beside it (when another app uses the notch).
    var notchHandlePosition: NotchHandlePosition {
        didSet { defaults.set(notchHandlePosition.rawValue, forKey: Keys.notchHandlePosition) }
    }

    /// Whether the handle stays invisible until the mouse is over it.
    var hidesNotchHandle: Bool {
        didSet { defaults.set(hidesNotchHandle, forKey: Keys.hidesNotchHandle) }
    }

    /// Whether PixSnap looks for a newer version after launch and once a day (on by default).
    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Keys.checksForUpdates) }
    }

    /// "截完自动美化": off, the style that suits each screenshot, or a saved preset's id.
    var autoBeautify: String {
        didSet { defaults.set(autoBeautify, forKey: Keys.autoBeautify) }
    }

    static let autoBeautifyOff = "off"
    static let autoBeautifySmart = "smart"

    /// How the clothesline ropes look.
    var ropeStyle: RopeStyle {
        didSet { if let data = try? JSONEncoder().encode(ropeStyle) { defaults.set(data, forKey: Keys.ropeStyle) } }
    }

    private(set) var launchAtLoginStatus: SMAppService.Status

    static let defaultSaveFolder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PixSnap", isDirectory: true)

    private let defaults: UserDefaults

    private enum Keys {
        /// The region shortcut from before there were several.
        static let captureShortcut = "captureShortcut"
        static let captureShortcuts = "captureShortcuts"
        static let captureDelay = "captureDelay"
        static let windowCaptureStyle = "windowCaptureStyle"
        static let recordingFPS = "recordingFPS"
        static let recognizesText = "recognizesText"
        static let recordsCursor = "recordsCursor"
        static let recordsSystemAudio = "recordsSystemAudio"
        static let recordsMicrophone = "recordsMicrophone"
        static let highlightsClicks = "highlightsClicks"
        static let showsKeystrokes = "showsKeystrokes"
        static let recordsTutorial = "recordsTutorial"
        static let microphoneID = "microphoneID"
        static let hidesNotificationsInRecordings = "hidesNotificationsInRecordings"
        static let showsCameraBubble = "showsCameraBubble"
        static let opensGuideAfterTutorial = "opensGuideAfterTutorial"
        static let copiesAfterCapture = "copiesAfterCapture"
        static let saveFolderPath = "saveFolderPath"
        static let asksWhereToSave = "asksWhereToSave"
        static let savesHistory = "savesHistory"
        /// 0 means forever.
        static let historyRetentionDays = "historyRetentionDays"
        static let pullsHistoryFromNotch = "pullsHistoryFromNotch"
        static let ropeStyle = "ropeStyle"
        static let notchHandleSize = "notchHandleSize"
        static let checksForUpdates = "checksForUpdates"
        static let autoBeautify = "autoBeautify"
        static let hidesNotchHandle = "hidesNotchHandle"
        static let notchHandlePosition = "notchHandlePosition"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var shortcuts: [CaptureAction: Shortcut] = [:]
        if let data = defaults.data(forKey: Keys.captureShortcuts),
           let stored = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            for (key, shortcut) in stored { if let action = CaptureAction(rawValue: key) { shortcuts[action] = shortcut } }
        } else if let data = defaults.data(forKey: Keys.captureShortcut),
                  let region = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcuts[.region] = region
        }
        self.shortcuts = shortcuts
        let delay = defaults.integer(forKey: Keys.captureDelay)
        captureDelay = Self.captureDelayChoices.contains(delay) ? delay : 3
        recognizesText = defaults.object(forKey: Keys.recognizesText) as? Bool ?? true
        let fps = defaults.integer(forKey: Keys.recordingFPS)
        recordingFPS = Self.recordingFPSChoices.contains(fps) ? fps : 30
        recordsCursor = defaults.object(forKey: Keys.recordsCursor) as? Bool ?? true
        recordsSystemAudio = defaults.bool(forKey: Keys.recordsSystemAudio)
        recordsMicrophone = defaults.bool(forKey: Keys.recordsMicrophone)
        highlightsClicks = defaults.bool(forKey: Keys.highlightsClicks)
        showsKeystrokes = defaults.bool(forKey: Keys.showsKeystrokes)
        recordsTutorial = defaults.bool(forKey: Keys.recordsTutorial)
        microphoneID = defaults.string(forKey: Keys.microphoneID)
        hidesNotificationsInRecordings = defaults.object(forKey: Keys.hidesNotificationsInRecordings) as? Bool ?? true
        showsCameraBubble = defaults.bool(forKey: Keys.showsCameraBubble)
        opensGuideAfterTutorial = defaults.bool(forKey: Keys.opensGuideAfterTutorial)
        windowCaptureStyle = defaults.data(forKey: Keys.windowCaptureStyle)
            .flatMap { try? JSONDecoder().decode(WindowCaptureStyle.self, from: $0) } ?? .default
        copiesAfterCapture = defaults.bool(forKey: Keys.copiesAfterCapture)
        saveFolder = defaults.string(forKey: Keys.saveFolderPath)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultSaveFolder
        asksWhereToSave = defaults.object(forKey: Keys.asksWhereToSave) as? Bool ?? true
        savesHistory = defaults.object(forKey: Keys.savesHistory) as? Bool ?? true
        let days = defaults.object(forKey: Keys.historyRetentionDays) as? Int ?? 30
        historyRetentionDays = days > 0 ? days : nil
        pullsHistoryFromNotch = defaults.object(forKey: Keys.pullsHistoryFromNotch) as? Bool ?? true
        notchHandleSize = defaults.string(forKey: Keys.notchHandleSize).flatMap(NotchHandleSize.init(rawValue:)) ?? .medium
        hidesNotchHandle = defaults.bool(forKey: Keys.hidesNotchHandle)
        notchHandlePosition = defaults.string(forKey: Keys.notchHandlePosition).flatMap(NotchHandlePosition.init(rawValue:)) ?? .notch
        checksForUpdates = defaults.object(forKey: Keys.checksForUpdates) as? Bool ?? true
        autoBeautify = defaults.string(forKey: Keys.autoBeautify) ?? Self.autoBeautifyOff
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

    private func saveShortcuts() {
        let stored = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Keys.captureShortcuts) }
    }
}
