import AppKit
import CryptoKit
import PixSnapCore

/// 自动更新: reads `latest.json` from the newest GitHub release (a plain download, not the API, so
/// there's no rate limit), and when it's a newer version that runs on this Mac, says what's new.
/// "下载并安装" downloads the installer, checks it against the SHA-256 in `latest.json`, opens it in
/// the system's Installer and quits, so the new version can take PixSnap's place.
///
/// Checks a little after launch and then once a day while "自动检查更新" is on; "检查更新…" in the
/// menu checks right away and also says when there's nothing new. A version can be skipped.
@MainActor
final class Updater {
    static let shared = Updater()

    private static let feed = URL(string: "https://github.com/calabli/PixSnap/releases/latest/download/latest.json")!
    private static let skippedKey = "skippedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let interval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?
    private var window: UpdateWindow?
    private var isChecking = false

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

    /// Looks for a newer version. When asked from the menu, also says when there's none, or when
    /// it couldn't find out, and offers a skipped version again.
    func check(userInitiated: Bool) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                let info = try await fetch()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                let system = ProcessInfo.processInfo.operatingSystemVersion
                let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
                let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
                if info.isUpdate(over: currentVersion, system: systemVersion), userInitiated || skipped != info.version {
                    show(info)
                } else if userInitiated {
                    let newer = AppVersion(info.version).map { $0 > AppVersion(currentVersion) ?? $0 } ?? false
                    tell(newer ? "PixSnap \(info.version) 需要 macOS \(info.minimumSystemVersion) 或更新版本"
                               : "PixSnap 已经是最新版本",
                         newer ? "这台 Mac 的系统是 \(systemVersion)，先升级系统才能更新。" : "你现在用的是 \(currentVersion)。")
                }
            } catch {
                NSLog("PixSnap update check failed: \(error)")
                if userInitiated { tell("没能检查更新", "连不上 GitHub，过一会儿再试。（\(error.localizedDescription)）") }
            }
        }
    }

    private func fetch() async throws -> UpdateInfo {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("PixSnap/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(UpdateInfo.self, from: data)
    }

    private func show(_ info: UpdateInfo) {
        let window = UpdateWindow(info: info, current: currentVersion)
        window.onSkip = { UserDefaults.standard.set(info.version, forKey: Self.skippedKey) }
        window.onInstall = { [weak self, weak window] in
            guard let window else { return }
            self?.install(info, in: window)
        }
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        // Development: goes straight on to downloading (`--install-update`).
        if CommandLine.arguments.contains("--install-update") { install(info, in: window) }
    }

    private func tell(_ message: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
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

/// "PixSnap 0.4.0 可以更新了": what's new, and 跳过这个版本 / 以后再说 / 下载并安装, then the
/// download's progress.
@MainActor
final class UpdateWindow: NSPanel {
    var onSkip: (() -> Void)?
    var onInstall: (() -> Void)?

    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let install = NSButton(title: "下载并安装", target: nil, action: nil)
    private let later = NSButton(title: "以后再说", target: nil, action: nil)
    private let skip = NSButton(title: "跳过这个版本", target: nil, action: nil)

    init(info: UpdateInfo, current: String) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "软件更新"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        // On the Space being looked at, even over a full-screen app.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: "PixSnap \(info.version) 可以更新了")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "你现在用的是 \(current)。更新后截图历史和设置都会保留。")
        subtitle.textColor = .secondaryLabelColor

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

        status.textColor = .secondaryLabelColor
        status.isHidden = true
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.isHidden = true

        install.keyEquivalent = "\r"
        install.target = self
        install.action = #selector(installClicked)
        later.target = self
        later.action = #selector(laterClicked)
        later.keyEquivalent = "\u{1b}"
        skip.target = self
        skip.action = #selector(skipClicked)
        let buttons = NSStackView(views: [skip, NSView(), later, install])
        buttons.spacing = 8

        let text = NSStackView(views: [heading, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let top = NSStackView(views: [icon, text])
        top.spacing = 14
        top.alignment = .centerY

        let column = NSStackView(views: [top, scroll, progress, status, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            progress.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
        ])
        contentView = content
        setContentSize(CGSize(width: 520, height: content.fittingSize.height))
    }

    func setDownloading(_ fraction: Double) {
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

    @objc private func skipClicked() {
        onSkip?()
        close()
    }
}
