import AppKit
import CryptoKit
import PixSnapCore

/// 自动更新: reads `latest.json` from the newest GitHub release (a plain download, not the API, so
/// there's no rate limit), and when it's a newer version that runs on this Mac, says what's new.
/// "下载并安装" downloads the installer, checks it against the SHA-256 in `latest.json`, opens it in
/// the system's Installer and quits, so the new version can take PixSnap's place.
///
/// Checks a little after launch and then once a day while "自动检查更新" is on, showing up only for a
/// new version. "检查更新…" in the menu opens the window right away, spinning while it checks, then
/// shows the new version, or that this one is the latest, or that the check failed (with 重试).
/// A version can be skipped.
@MainActor
final class Updater {
    static let shared = Updater()

    private static let feed = URL(string: "https://github.com/calabli/PixSnap/releases/latest/download/latest.json")!
    private static let skippedKey = "skippedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let interval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?
    private var window: UpdateWindow?
    private var checking: Task<Void, Never>?

    /// This copy's version; `--pretend-version 0.3.0` stands in for testing.
    var currentVersion: String {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--pretend-version"), arguments.indices.contains(flag + 1) { return arguments[flag + 1] }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `--update-feed <url>` reads another `latest.json` (a file:// one, say) for testing.
    private var feed: URL {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--update-feed"), arguments.indices.contains(flag + 1) {
            let value = arguments[flag + 1]
            return value.contains("://") ? URL(string: value) ?? Self.feed : URL(fileURLWithPath: value)
        }
        return Self.feed
    }

    /// Checks soon after launch if it's been a day, then keeps checking daily.
    func start() {
        timer?.invalidate()
        guard AppSettings.shared.checksForUpdates else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        let first = max(15, Self.interval - Date().timeIntervalSince(last))
        timer = Timer.scheduledTimer(withTimeInterval: first, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check(userInitiated: false)
                self?.timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.check(userInitiated: false) }
                }
            }
        }
    }

    /// Looks for a newer version. When asked from the menu, the window comes up at once and also
    /// says when there's nothing new or the check failed, and a skipped version is offered again.
    func check(userInitiated: Bool) {
        if let window, window.isVisible, window.isBusy {
            present(window)
            return
        }
        guard checking == nil else { return }
        let started = Date()
        if userInitiated {
            let window = self.window ?? makeWindow()
            window.showChecking(current: currentVersion)
            present(window)
        }
        checking = Task {
            defer { checking = nil }
            let outcome: Result<UpdateInfo, Error>
            do {
                outcome = .success(try await fetch())
            } catch {
                outcome = .failure(error)
            }
            // Long enough to see that something happened.
            if userInitiated, Date().timeIntervalSince(started) < 0.8 {
                try? await Task.sleep(for: .seconds(0.8 - Date().timeIntervalSince(started)))
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let info):
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                let system = ProcessInfo.processInfo.operatingSystemVersion
                let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                if info.isUpdate(over: currentVersion, system: systemVersion), userInitiated || skipped != info.version {
                    show(info)
                } else if userInitiated, let window {
                    let newer = AppVersion(info.version).map { $0 > AppVersion(currentVersion) ?? $0 } ?? false
                    if newer {
                        window.showResult(.warning, "PixSnap \(info.version) 需要 macOS \(info.minimumSystemVersion) 或更新版本",
                                          "这台 Mac 的系统是 \(systemVersion)，先升级系统才能更新。")
                    } else {
                        window.showResult(.upToDate, "PixSnap 已经是最新版本", "你现在用的是 \(currentVersion)。")
                    }
                }
            case .failure(let error):
                NSLog("PixSnap update check failed: \(error)")
                if userInitiated, let window {
                    window.showResult(.failed, "没能检查更新", "连不上 GitHub，检查一下网络，过一会儿再试。（\(error.localizedDescription)）")
                }
            }
        }
    }

    private func makeWindow() -> UpdateWindow {
        let window = UpdateWindow()
        window.onRetry = { [weak self] in self?.check(userInitiated: true) }
        window.onCancel = { [weak self] in
            self?.checking?.cancel()
            self?.checking = nil
        }
        self.window = window
        return window
    }

    private func present(_ window: UpdateWindow) {
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func fetch() async throws -> UpdateInfo {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("PixSnap/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    private func show(_ info: UpdateInfo) {
        let window = self.window ?? makeWindow()
        window.onSkip = { UserDefaults.standard.set(info.version, forKey: Self.skippedKey) }
        window.onInstall = { [weak self, weak window] in
            guard let window else { return }
            self?.install(info, in: window)
        }
        window.showUpdate(info, current: currentVersion)
        present(window)
        // Development: goes straight on to downloading (`--install-update`).
        if CommandLine.arguments.contains("--install-update") { install(info, in: window) }
    }

    // MARK: Installing

    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.pixsnap.PixSnap/Updates", isDirectory: true)

    private func install(_ info: UpdateInfo, in window: UpdateWindow) {
        window.setDownloading(0)
        Task {
            do {
                let package = try await download(info) { fraction in window.setDownloading(fraction) }
                window.setOpeningInstaller()
                NSWorkspace.shared.open(package)
                // Out of the way, so the installer can replace this copy.
                try? await Task.sleep(for: .seconds(1.5))
                NSApp.terminate(nil)
            } catch {
                NSLog("PixSnap update download failed: \(error)")
                window.setFailed(error is ChecksumMismatch ? "下载的安装包校验不对，没有打开。请再试一次。" : "下载失败：\(error.localizedDescription)")
            }
        }
    }

    private struct ChecksumMismatch: Error {}

    /// Downloads the installer into Caches, reporting progress, and checks its SHA-256.
    private func download(_ info: UpdateInfo, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let destination = Self.folder.appendingPathComponent(info.url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)

        let (bytes, response) = try await URLSession.shared.bytes(from: info.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        let expected = max(Int(response.expectedContentLength), info.size, 1)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data(capacity: 256 * 1024)
        var received = 0, lastReported = 0
        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count >= 256 * 1024 else { continue }
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            received += buffer.count
            buffer.removeAll(keepingCapacity: true)
            if received - lastReported >= 512 * 1024 {
                lastReported = received
                progress(min(1, Double(received) / Double(expected)))
            }
        }
        hasher.update(data: buffer)
        try handle.write(contentsOf: buffer)
        progress(1)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == info.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: destination)
            throw ChecksumMismatch()
        }
        return destination
    }
}

/// 软件更新: one window that goes from "正在检查更新…" (spinning) to the new version's notes with
/// 跳过这个版本 / 以后再说 / 下载并安装 and the download's progress, or to "已经是最新版本" or a
/// failed check with 重试, resizing smoothly between them.
@MainActor
final class UpdateWindow: NSPanel {
    var onSkip: (() -> Void)?
    var onInstall: (() -> Void)?
    var onRetry: (() -> Void)?
    /// Closed while still checking.
    var onCancel: (() -> Void)?

    enum Result {
        case upToDate, warning, failed
    }

    /// Checking, or downloading: the window isn't just showing an answer.
    private(set) var isBusy = false
    private var isChecking = false

    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let install = NSButton(title: "下载并安装", target: nil, action: nil)
    private let later = NSButton(title: "以后再说", target: nil, action: nil)
    private let skip = NSButton(title: "跳过这个版本", target: nil, action: nil)

    private static let width: CGFloat = 520

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 150), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "软件更新"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        // On the Space being looked at, even over a full-screen app.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        install.keyEquivalent = "\r"
        install.target = self
        install.action = #selector(installClicked)
        later.target = self
        later.action = #selector(laterClicked)
        later.keyEquivalent = "\u{1b}"
        skip.target = self
        skip.action = #selector(skipClicked)
    }

    override func close() {
        if isChecking { onCancel?() }
        isChecking = false
        isBusy = false
        super.close()
    }

    // MARK: States

    /// The app icon with a heading and a line under it, and `badge` (a symbol) on the icon's corner.
    private func header(_ heading: String, _ detail: String, badge: (String, NSColor)? = nil, accessory: NSView? = nil) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(icon)
        var constraints = [
            holder.widthAnchor.constraint(equalToConstant: 60), holder.heightAnchor.constraint(equalToConstant: 60),
            icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56),
            icon.leadingAnchor.constraint(equalTo: holder.leadingAnchor), icon.topAnchor.constraint(equalTo: holder.topAnchor),
        ]
        if let (symbol, color) = badge,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 20, weight: .bold)) {
            let mark = NSImageView(image: image)
            mark.contentTintColor = color
            mark.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(mark)
            constraints += [mark.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: 2),
                            mark.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: 2)]
        }
        NSLayoutConstraint.activate(constraints)
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: detail)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = Self.width - 140
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [holder, text] + (accessory.map { [NSView(), $0] } ?? []))
        row.spacing = 14
        row.alignment = .centerY
        return row
    }

    private func buttons(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = 8
        return row
    }

    /// Lays out `rows` as the window's content and resizes to fit, keeping the top edge still.
    private func showRows(_ rows: [NSView], fullWidth: [NSView]) {
        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        var constraints = [
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.width),
        ]
        constraints += fullWidth.map { $0.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40) }
        NSLayoutConstraint.activate(constraints)
        let height = content.fittingSize.height
        let wasVisible = isVisible
        let top = frame.maxY
        contentView = content
        let size = frameRect(forContentRect: CGRect(x: 0, y: 0, width: Self.width, height: height)).size
        setFrame(CGRect(x: frame.minX, y: wasVisible ? top - size.height : frame.minY, width: size.width, height: size.height),
                 display: true, animate: wasVisible)
    }

    func showChecking(current: String) {
        isChecking = true
        isBusy = true
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let cancel = NSButton(title: "取消", target: self, action: #selector(laterClicked))
        cancel.keyEquivalent = "\u{1b}"
        let actions = buttons([NSView(), cancel])
        showRows([header("正在检查更新…", "你现在用的是 \(current)。", accessory: spinner), actions], fullWidth: [actions])
    }

    func showResult(_ result: Result, _ heading: String, _ detail: String) {
        isChecking = false
        isBusy = false
        let badge: (String, NSColor) = switch result {
        case .upToDate: ("checkmark.circle.fill", .systemGreen)
        case .warning: ("exclamationmark.circle.fill", .systemOrange)
        case .failed: ("xmark.circle.fill", .systemRed)
        }
        let done = NSButton(title: "好", target: self, action: #selector(laterClicked))
        done.keyEquivalent = "\r"
        var views: [NSView] = [NSView()]
        if result == .failed { views.append(NSButton(title: "重试", target: self, action: #selector(retryClicked))) }
        views.append(done)
        let actions = buttons(views)
        showRows([header(heading, detail, badge: badge), actions], fullWidth: [actions])
    }

    func showUpdate(_ info: UpdateInfo, current: String) {
        isChecking = false
        isBusy = false
        let notes = NSTextView()
        notes.isEditable = false
        notes.drawsBackground = false
        notes.textContainerInset = NSSize(width: 10, height: 10)
        notes.textStorage?.setAttributedString(Self.render(info.notes))
        let scroll = NSScrollView()
        scroll.documentView = notes
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        notes.autoresizingMask = [.width]
        notes.isVerticallyResizable = true
        notes.textContainer?.widthTracksTextView = true
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        status.textColor = .secondaryLabelColor
        status.isHidden = true
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.isHidden = true
        install.title = "下载并安装"
        install.isEnabled = true
        skip.isEnabled = true
        later.isEnabled = true

        let actions = buttons([skip, NSView(), later, install])
        showRows([header("PixSnap \(info.version) 可以更新了", "你现在用的是 \(current)。更新后截图历史和设置都会保留。"),
                  scroll, progress, status, actions], fullWidth: [scroll, progress, actions])
        // From the first line.
        notes.scroll(.zero)
    }

    // MARK: Installing

    func setDownloading(_ fraction: Double) {
        isBusy = true
        install.isEnabled = false
        skip.isEnabled = false
        progress.isHidden = false
        progress.doubleValue = fraction
        status.isHidden = false
        status.stringValue = "正在下载… \(Int((fraction * 100).rounded()))%"
    }

    func setOpeningInstaller() {
        later.isEnabled = false
        status.stringValue = "正在打开安装器，PixSnap 会先退出；装好后从“应用程序”里重新打开它"
    }

    func setFailed(_ message: String) {
        isBusy = false
        progress.isHidden = true
        status.isHidden = false
        status.stringValue = message
        install.isEnabled = true
        skip.isEnabled = true
        install.title = "重试"
    }

    /// The release notes: "## " lines as headings, "- " lines as bullets, **bold** kept.
    private static func render(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.headIndent = 14
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var font = body
            if line.hasPrefix("#") {
                line = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                font = .systemFont(ofSize: 14, weight: .semibold)
            } else if line.hasPrefix("- ") {
                line = "• " + line.dropFirst(2)
            }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let parsed = (try? NSMutableAttributedString(AttributedString(markdown: line, options: options), including: \.appKit))
                ?? NSMutableAttributedString(string: line)
            let whole = NSRange(location: 0, length: parsed.length)
            parsed.addAttributes([.foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: whole)
            // Bold where the Markdown said so, at this line's size.
            parsed.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
                let intent = (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) } ?? []
                parsed.addAttribute(.font, value: intent.contains(.stronglyEmphasized) ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font,
                                    range: range)
            }
            result.append(parsed)
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }

    @objc private func installClicked() { onInstall?() }
    @objc private func laterClicked() { close() }
    @objc private func retryClicked() { onRetry?() }

    @objc private func skipClicked() {
        onSkip?()
        close()
    }
}
