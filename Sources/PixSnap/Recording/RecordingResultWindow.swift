import AVFoundation
import AVKit
import AppKit
import PixSnapCore
import UniformTypeIdentifiers

/// A recording, floating where it was made (or opened from history): it plays on a loop (muted),
/// with its length, and a bar to trim its start and end, save it as MP4 or GIF, drag it into
/// another app, delete it from history for good (two clicks), or close it.
/// Recordings are kept in history like screenshots; with history off, an unsaved one is cleaned
/// out of Caches after a day.
@MainActor
final class RecordingResultWindow: NSPanel {
    var onClosed: ((RecordingResultWindow) -> Void)?

    private var video: URL
    /// Its entry in history, if it has one; deleting needs it.
    private let historyID: UUID?
    private var deleteButton: NSButton?
    private var confirmingDelete = false
    private var duration: Double
    private let pixelSize: CGSize
    private let recordedAt = Date()
    private var player: AVQueuePlayer
    private var looper: AVPlayerLooper
    private let playerView = AVPlayerView()
    private let status = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []

    private static let barHeight: CGFloat = 40
    private static let largest = CGSize(width: 520, height: 400)

    init(video: URL, duration: Double, pixelSize: CGSize, near region: CGRect, on screen: NSScreen, historyID: UUID?) {
        self.video = video
        self.historyID = historyID
        self.duration = duration
        self.pixelSize = pixelSize
        (player, looper) = Self.loop(video)

        // The video, scaled to fit, with the bar under it; placed over the recorded region.
        let fit = min(1, Self.largest.width / max(region.width, 1), Self.largest.height / max(region.height, 1))
        let videoSize = CGSize(width: max(240, (region.width * fit).rounded()), height: max(120, (region.height * fit).rounded()))
        let size = CGSize(width: max(videoSize.width, historyID == nil ? 540 : 610), height: videoSize.height + Self.barHeight + 6)
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
        playerView.frame = CGRect(x: (size.width - videoSize.width) / 2, y: Self.barHeight + 6, width: videoSize.width, height: videoSize.height)
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        playerView.layer?.cornerRadius = 6
        playerView.layer?.masksToBounds = true
        playerView.player = player
        content.addSubview(playerView)

        let bar = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: size.width, height: Self.barHeight))
        bar.autoresizingMask = [.width]
        bar.material = .popover
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.masksToBounds = true
        showLength()
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let drag = FileDragHandle(file: { [weak self] in self?.video })
        var views: [NSView] = [
            status,
            button("剪辑", symbol: "scissors", tip: "剪掉开头和结尾", action: #selector(trimClicked)),
            button("存为视频", symbol: "film", tip: "保存为 MP4", action: #selector(saveVideo)),
            button("存为 GIF", symbol: "photo.on.rectangle", tip: "转成 GIF 保存（15 帧/秒，最宽 800 像素）", action: #selector(saveGIF)),
            drag,
        ]
        if historyID != nil {
            let delete = button("删除", symbol: "trash", tip: "从截图历史里永久删除，不进洗衣篮（点两下确认）", action: #selector(deleteClicked))
            deleteButton = delete
            views.append(delete)
        }
        views.append(button(nil, symbol: "xmark", tip: "关闭", action: #selector(closeClicked)))
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
    override func cancelOperation(_ sender: Any?) {
        if trimming { return }
        close()
    }

    /// Plays `video` round and round, muted.
    private static func loop(_ video: URL) -> (AVQueuePlayer, AVPlayerLooper) {
        let player = AVQueuePlayer()
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: video))
        player.isMuted = true
        return (player, looper)
    }

    private func showLength() {
        let seconds = Int(duration.rounded())
        status.stringValue = String(format: "录屏 %d:%02d · %d×%d", seconds / 60, seconds % 60, Int(pixelSize.width), Int(pixelSize.height))
    }

    // MARK: Trimming

    private var trimming = false
    /// The smallest the window gets while trimming, so the trim bar has room.
    private static let trimmingSize = CGSize(width: 620, height: 340)

    /// The system's trim bar over the video: drag its yellow ends, then 修剪. The cut is
    /// re-encoded so it starts exactly where chosen, and replaces the recording (in history too).
    @objc private func trimClicked() {
        guard !trimming else { return }
        let player = AVPlayer(playerItem: AVPlayerItem(url: video))
        player.isMuted = true
        playerView.player = player
        self.player.pause()
        guard playerView.canBeginTrimming else {
            playerView.player = self.player
            self.player.play()
            return
        }
        trimming = true
        buttons.forEach { $0.isEnabled = false }
        status.stringValue = "拖动两端的黄色把手，然后点“修剪”"
        let before = frame
        let grown = CGSize(width: max(before.width, Self.trimmingSize.width), height: max(before.height, Self.trimmingSize.height))
        setFrame(CGRect(x: before.midX - grown.width / 2, y: before.maxY - grown.height, width: grown.width, height: grown.height), display: true, animate: true)
        playerView.controlsStyle = .inline
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated { self?.trimmed(result, player: player, restoring: before) }
        }
    }

    private func trimmed(_ result: AVPlayerViewTrimResult, player: AVPlayer, restoring before: CGRect) {
        let item = player.currentItem
        let start = item?.reversePlaybackEndTime ?? .invalid
        let end = item?.forwardPlaybackEndTime ?? .invalid
        playerView.controlsStyle = .none
        setFrame(before, display: true, animate: true)
        trimming = false
        guard result == .okButton else {
            finishTrimming()
            return
        }
        let range = CMTimeRange(start: start.isValid ? start : .zero,
                                end: end.isValid ? end : CMTime(seconds: duration, preferredTimescale: 600))
        cut(to: range)
    }

    /// Back to looping whatever `video` is now, with the buttons working again.
    private func finishTrimming() {
        (player, looper) = Self.loop(video)
        playerView.player = player
        player.play()
        buttons.forEach { $0.isEnabled = true }
        showLength()
    }

    private func cut(to range: CMTimeRange) {
        status.stringValue = "正在剪辑…"
        let historyID = historyID
        let source = video
        Task {
            do {
                let trimmed = try await Self.export(source, range: range)
                let length = range.duration.seconds
                if let historyID {
                    try await HistoryLibrary.shared.replaceRecording(historyID, with: trimmed, duration: length)
                } else {
                    _ = try FileManager.default.replaceItemAt(source, withItemAt: trimmed)
                }
                duration = length
                finishTrimming()
                let seconds = Int(length.rounded())
                status.stringValue = String(format: "已剪辑，现在 %d:%02d", seconds / 60, seconds % 60)
            } catch {
                NSLog("PixSnap could not trim a recording: \(error)")
                finishTrimming()
                status.stringValue = "剪辑失败"
            }
        }
    }

    private static func export(_ video: URL, range: CMTimeRange) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        let output = ScreenRecorder.folder.appendingPathComponent("\(UUID().uuidString).mp4")
        session.timeRange = range
        if #available(macOS 15, *) {
            try await session.export(to: output, as: .mp4)
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
        }
        return output
    }

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

    // MARK: Deleting

    /// The first click asks; a second click within a few seconds deletes.
    @objc private func deleteClicked() {
        guard let deleteButton else { return }
        if confirmingDelete { return deleteForGood() }
        confirmingDelete = true
        // Same width as "删除", so the bar doesn't need laying out again.
        deleteButton.title = "确认"
        deleteButton.contentTintColor = .systemRed
        deleteButton.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "确认删除")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, confirmingDelete else { return }
            confirmingDelete = false
            deleteButton.title = "删除"
            deleteButton.contentTintColor = nil
            deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
        }
    }

    /// Stops playing, then removes the recording from history, video and all (not into the
    /// basket), and fades away.
    private func deleteForGood() {
        guard let historyID else { return }
        player.pause()
        player.removeAllItems()
        HistoryLibrary.shared.deletePermanently([historyID])
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        })
    }
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
