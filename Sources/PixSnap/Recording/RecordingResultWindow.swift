import AVFoundation
import AppKit
import PixSnapCore
import UniformTypeIdentifiers

/// A recording, floating where it was made (or opened from history): it plays on a loop (muted),
/// with its length, and a bar to save it as MP4 or GIF, drag it into another app, or close it.
/// Recordings are kept in history like screenshots; with history off, an unsaved one is cleaned
/// out of Caches after a day.
@MainActor
final class RecordingResultWindow: NSPanel {
    var onClosed: ((RecordingResultWindow) -> Void)?

    private let video: URL
    private let duration: Double
    private let recordedAt = Date()
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let status = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []

    private static let barHeight: CGFloat = 40
    private static let largest = CGSize(width: 520, height: 400)

    init(video: URL, duration: Double, pixelSize: CGSize, near region: CGRect, on screen: NSScreen) {
        self.video = video
        self.duration = duration
        let item = AVPlayerItem(url: video)
        player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true

        // The video, scaled to fit, with the bar under it; placed over the recorded region.
        let fit = min(1, Self.largest.width / max(region.width, 1), Self.largest.height / max(region.height, 1))
        let videoSize = CGSize(width: max(240, (region.width * fit).rounded()), height: max(120, (region.height * fit).rounded()))
        let size = CGSize(width: max(videoSize.width, 470), height: videoSize.height + Self.barHeight + 6)
        let visible = screen.visibleFrame
        let origin = CGPoint(x: min(max(region.midX - size.width / 2, visible.minX + 10), visible.maxX - size.width - 10),
                             y: min(max(region.midY - size.height / 2, visible.minY + 10), visible.maxY - size.height - 10))
        super.init(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        let playerView = NSView(frame: CGRect(x: (size.width - videoSize.width) / 2, y: Self.barHeight + 6,
                                              width: videoSize.width, height: videoSize.height))
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        playerView.layer?.cornerRadius = 6
        playerView.layer?.masksToBounds = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = playerView.bounds
        playerLayer.videoGravity = .resizeAspect
        playerView.layer?.addSublayer(playerLayer)
        content.addSubview(playerView)

        let bar = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: size.width, height: Self.barHeight))
        bar.material = .popover
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.masksToBounds = true
        let seconds = Int(duration.rounded())
        status.stringValue = String(format: "录屏 %d:%02d · %d×%d", seconds / 60, seconds % 60, Int(pixelSize.width), Int(pixelSize.height))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let drag = FileDragHandle(file: { [weak self] in self?.video })
        let views: [NSView] = [
            status,
            button("存为视频", symbol: "film", tip: "保存为 MP4", action: #selector(saveVideo)),
            button("存为 GIF", symbol: "photo.on.rectangle", tip: "转成 GIF 保存（15 帧/秒，最宽 800 像素）", action: #selector(saveGIF)),
            drag,
            button(nil, symbol: "xmark", tip: "关闭", action: #selector(closeClicked)),
        ]
        let stack = NSStackView(views: views)
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        content.addSubview(bar)
        contentView = content
        player.play()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        player.pause()
        super.close()
        onClosed?(self)
    }

    private func button(_ title: String?, symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? tip)!
        let button = title.map { NSButton(title: $0, image: image, target: self, action: action) } ?? NSButton(image: image, target: self, action: action)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.font = .systemFont(ofSize: 12)
        button.toolTip = tip
        buttons.append(button)
        return button
    }

    // MARK: Saving

    /// "PixSnap 录屏 2026-10-28 14.03.12"
    private var baseName: String {
        CaptureFileNamer.baseName(for: recordedAt).replacingOccurrences(of: "PixSnap ", with: "PixSnap 录屏 ")
    }

    @objc private func saveVideo() {
        chooseDestination(type: .mpeg4Movie, extension: "mp4") { [weak self] url in
            guard let self else { return }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: video, to: url)
        }
    }

    @objc private func saveGIF() {
        chooseDestination(type: .gif, extension: "gif") { [weak self] url in
            guard let self else { return }
            status.stringValue = "正在生成 GIF…"
            buttons.forEach { $0.isEnabled = false }
            defer { buttons.forEach { $0.isEnabled = true } }
            try await GIFExporter.export(video, duration: duration, to: url)
        }
    }

    /// Asks where (or saves straight into the save folder, as Settings says), then `write`s there.
    private func chooseDestination(type: UTType, extension ext: String, write: @escaping (URL) async throws -> Void) {
        let settings = AppSettings.shared
        let finish: (URL) -> Void = { [weak self] url in
            Task { @MainActor in
                do {
                    try await write(url)
                    self?.status.stringValue = "已保存到“\(url.deletingLastPathComponent().lastPathComponent)”"
                } catch {
                    NSLog("PixSnap could not save a recording: \(error)")
                    self?.status.stringValue = "保存失败"
                }
            }
        }
        guard settings.asksWhereToSave else {
            try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
            finish(Self.unique(settings.saveFolder.appendingPathComponent("\(baseName).\(ext)")))
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存录屏"
        panel.prompt = "保存"
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        panel.level = .modalPanel
        NSApp.activate()
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                settings.saveFolder = url.deletingLastPathComponent()
                finish(url)
            }
        }
    }

    /// Adds " (2)", " (3)"… when the name is taken.
    private static func unique(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var candidate = url, counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    @objc private func closeClicked() { close() }
}

/// "拖出": drag the recording (an MP4 file) into another app.
@MainActor
private final class FileDragHandle: NSView, NSDraggingSource {
    private let file: () -> URL?
    private var pressedAt: CGPoint?

    init(file: @escaping () -> URL?) {
        self.file = file
        super.init(frame: .zero)
        let label = NSButton(title: "拖出", image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "拖出")!, target: nil, action: nil)
        label.bezelStyle = .recessed
        label.isBordered = false
        label.imagePosition = .imageLeading
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        toolTip = "按住拖到微信、邮件、访达等应用（MP4 文件）"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { pressedAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, let url = file(),
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 else { return }
        pressedAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
