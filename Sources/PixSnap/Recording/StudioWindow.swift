import AVFoundation
import AVKit
import AppKit
import PixSnapCore
import PixSnapRender
import UniformTypeIdentifiers

/// 精修: a recording played with its finish applied live, zooming in where it was clicked
/// (`ZoomPlan`, from the timeline saved beside it) on a background with room, rounded corners and a
/// shadow (`RecordingFinisher`). The track under the picture shows the zooms, clicks and keys:
/// drag across it to cut a stretch out or speed it up, click a zoom to switch it off. The controls
/// change it as it plays; 导出 writes it for a preset. The recording itself stays as it was.
@MainActor
final class StudioWindow: NSWindow {
    private static var open: [StudioWindow] = []

    /// Opens 精修 for the recording at `video` (its timeline, if any, is beside it); with
    /// `exportTo`, exports there straight away (`--studio-export`).
    static func show(video: URL, exportTo: URL? = nil, preset: ExportPreset? = nil, edit: VideoEdit = VideoEdit()) {
        if let existing = open.first(where: { $0.video == video }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = StudioWindow(video: video)
        open.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.exportOnLoad = exportTo
        if let preset { window.preset = preset }
        window.edit = edit
        window.load()
    }

    private var exportOnLoad: URL?

    private let video: URL
    private let asset: AVURLAsset
    private let timeline: RecordingTimeline?
    private var style: RecordingFinisher.Style
    private var videoSize = CGSize(width: 1920, height: 1080)
    private var pixelsPerPoint: CGFloat = 2
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let info = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let exportButton = NSButton(title: "导出视频…", target: nil, action: nil)
    private let guideButton = NSButton(title: "图文教程", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var composing: Task<Void, Never>?

    private let track = StudioTrackView()
    private let cutButton = NSButton(title: "剪掉", target: nil, action: nil)
    private let speedButton = NSButton(title: "加速 4×", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复原样", target: nil, action: nil)
    private let selectionLabel = NSTextField(labelWithString: "")
    private let presetPopup = NSPopUpButton()
    private var timeObserver: Any?
    /// The recording's length, and what's been cut or sped up on it.
    private var duration = 0.0
    private var edit = VideoEdit()
    /// Clicks (by their time on the recording) whose zoom was switched off.
    private var disabledClicks: Set<Double> = []
    private var selection: ClosedRange<Double>?
    /// What's playing: the recording as edited.
    private var playing: AVAsset?
    private var preset: ExportPreset = ExportPreset(rawValue: UserDefaults.standard.string(forKey: "studioPreset") ?? "") ?? .original {
        didSet { presetPopup.selectItem(at: ExportPreset.allCases.firstIndex(of: preset) ?? 0) }
    }

    private let zoomBox = NSButton(checkboxWithTitle: "点击时自动放大", target: nil, action: nil)
    private let scaleSlider = NSSlider(value: 2, minValue: 1.5, maxValue: 3, target: nil, action: nil)
    private let holdSlider = NSSlider(value: 1.5, minValue: 0.5, maxValue: 4, target: nil, action: nil)
    private let backgroundPopup = NSPopUpButton()
    private let paddingSlider = NSSlider(value: 48, minValue: 0, maxValue: 120, target: nil, action: nil)
    private let radiusSlider = NSSlider(value: 14, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let clickBox = NSButton(checkboxWithTitle: "点击效果", target: nil, action: nil)
    private let haloBox = NSButton(checkboxWithTitle: "鼠标光晕", target: nil, action: nil)
    private let keysBox = NSButton(checkboxWithTitle: "显示按键（写出 Command 等）", target: nil, action: nil)
    private var valueLabels: [NSSlider: NSTextField] = [:]

    private static let backgrounds: [(String, (RGB, RGB)?)] = [
        ("蓝紫", (RGB(0.56, 0.72, 1), RGB(0.43, 0.42, 0.94))),
        ("暖色", (RGB(1, 0.81, 0.54), RGB(1, 0.54, 0.48))),
        ("薄荷", (RGB(0.61, 0.91, 0.77), RGB(0.25, 0.73, 0.63))),
        ("石墨", (RGB(0.36, 0.36, 0.38), RGB(0.17, 0.17, 0.18))),
        ("无背景", nil),
    ]
    private static let styleKey = "studioStyle"

    private init(video: URL) {
        self.video = video
        asset = AVURLAsset(url: video)
        timeline = (try? Data(contentsOf: TimelineRecorder.url(forVideo: video))).flatMap { try? JSONDecoder().decode(RecordingTimeline.self, from: $0) }
        style = Self.savedStyle()
        super.init(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "精修"
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentMinSize = CGSize(width: 900, height: 560)
        contentView = makeContent()
        showStyle()
    }

    override func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        composing?.cancel()
        super.close()
        Self.open.removeAll { $0 === self }
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor

        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        func row(_ name: String, _ slider: NSSlider, unit: String) -> NSView {
            slider.target = self
            slider.action = #selector(controlChanged)
            slider.isContinuous = false
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.placeholderString = unit
            valueLabels[slider] = value
            let label = NSTextField(labelWithString: name)
            let stack = NSStackView(views: [label, slider, value])
            stack.spacing = 8
            label.widthAnchor.constraint(equalToConstant: 34).isActive = true
            value.widthAnchor.constraint(equalToConstant: 38).isActive = true
            return stack
        }
        for box in [zoomBox, clickBox, haloBox, keysBox] {
            box.target = self
            box.action = #selector(controlChanged)
        }
        backgroundPopup.addItems(withTitles: Self.backgrounds.map(\.0))
        backgroundPopup.target = self
        backgroundPopup.action = #selector(controlChanged)
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.preferredMaxLayoutWidth = 240

        let backgroundRow = NSStackView(views: [NSTextField(labelWithString: "背景"), backgroundPopup])
        backgroundRow.spacing = 8
        let inspector = NSStackView(views: [
            heading("放大"), zoomBox, row("倍数", scaleSlider, unit: "×"), row("停留", holdSlider, unit: "秒"), info,
            heading("鼠标和按键"), clickBox, haloBox, keysBox,
            heading("背景"), backgroundRow, row("边距", paddingSlider, unit: "点"), row("圆角", radiusSlider, unit: "点"),
        ])
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 10
        inspector.setCustomSpacing(22, after: info)
        inspector.setCustomSpacing(22, after: keysBox)
        inspector.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        inspector.translatesAutoresizingMaskIntoConstraints = false

        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.keyEquivalent = "\r"
        exportButton.isEnabled = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guideButton.target = self
        guideButton.action = #selector(guideClicked)
        guideButton.bezelStyle = .rounded
        let steps = timeline.map { StepGuide.steps(from: $0).count } ?? 0
        guideButton.title = steps > 0 ? "图文教程（\(steps) 步）" : "图文教程"
        guideButton.isEnabled = steps > 0
        guideButton.toolTip = steps > 0 ? "每次点击一步，自动配图和标题，导出长图或 Markdown" : "这段录屏没有记录到点击，做不了图文教程"
        presetPopup.addItems(withTitles: ExportPreset.allCases.map(\.title))
        presetPopup.selectItem(at: ExportPreset.allCases.firstIndex(of: preset) ?? 0)
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        presetPopup.toolTip = "导出成什么样：原尺寸最清楚；发微信会压到 25 MB 以内；GIF 不带声音"
        let bottom = NSStackView(views: [spinner, status, NSView(), guideButton, presetPopup, exportButton])
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        bottom.translatesAutoresizingMaskIntoConstraints = false

        track.translatesAutoresizingMaskIntoConstraints = false
        track.onSeek = { [weak self] t in self?.seek(to: t) }
        track.onSelect = { [weak self] range in self?.selected(range) }
        track.onToggleZoom = { [weak self] clicks in self?.toggleZoom(clicks) }
        for (button, action) in [(cutButton, #selector(cutClicked)), (speedButton, #selector(speedClicked)), (restoreButton, #selector(restoreClicked))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        cutButton.keyEquivalent = "\u{8}"
        cutButton.toolTip = "把选中的这段去掉（⌫）"
        speedButton.toolTip = "选中的这段快放 4 倍，不出声——等加载、等进度条时用"
        restoreButton.toolTip = "选中的这段恢复成原来的样子"
        selectionLabel.font = .systemFont(ofSize: 11)
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let editBar = NSStackView(views: [selectionLabel, NSView(), cutButton, speedButton, restoreButton])
        editBar.spacing = 6
        editBar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        editBar.translatesAutoresizingMaskIntoConstraints = false
        editBar.wantsLayer = true
        editBar.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        selected(nil)

        let content = NSView()
        content.addSubview(playerView)
        content.addSubview(track)
        content.addSubview(editBar)
        content.addSubview(inspector)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: track.topAnchor),
            playerView.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            track.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            track.heightAnchor.constraint(equalToConstant: 142),
            track.bottomAnchor.constraint(equalTo: editBar.topAnchor),
            editBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editBar.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            editBar.heightAnchor.constraint(equalToConstant: 34),
            editBar.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: content.topAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 280),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 48),
        ])
        return content
    }

    // MARK: Style

    private func showStyle() {
        zoomBox.state = style.zooms ? .on : .off
        scaleSlider.doubleValue = style.zoomScale
        holdSlider.doubleValue = style.hold
        paddingSlider.doubleValue = style.padding
        radiusSlider.doubleValue = style.cornerRadius
        let index = Self.backgrounds.firstIndex { entry in
            switch (entry.1, style.background) {
            case (nil, nil): true
            case let (a?, b?): a.0 == b.0 && a.1 == b.1
            default: false
            }
        } ?? 0
        backgroundPopup.selectItem(at: index)
        let hasTimeline = timeline != nil
        clickBox.state = style.clickEffects ? .on : .off
        haloBox.state = style.pointerHalo ? .on : .off
        keysBox.state = style.showsKeys ? .on : .off
        for box in [clickBox, haloBox, keysBox] { box.isEnabled = hasTimeline }
        zoomBox.isEnabled = hasTimeline
        scaleSlider.isEnabled = hasTimeline && style.zooms
        holdSlider.isEnabled = hasTimeline && style.zooms
        paddingSlider.isEnabled = style.background != nil
        radiusSlider.isEnabled = style.background != nil
        valueLabels[scaleSlider]?.stringValue = String(format: "%.1f×", style.zoomScale)
        valueLabels[holdSlider]?.stringValue = String(format: "%.1f 秒", style.hold)
        valueLabels[paddingSlider]?.stringValue = "\(Int(style.padding))"
        valueLabels[radiusSlider]?.stringValue = "\(Int(style.cornerRadius))"
        if let timeline {
            let plan = ZoomPlan(clicks: timeline.clicks, scale: style.zoomScale, hold: style.hold)
            track.zooms = style.zooms ? plan.segments.map { ($0, !$0.focus.allSatisfy { disabledClicks.contains($0.t) }) } : []
            let off = track.zooms.filter { !$0.on }.count
            info.stringValue = timeline.clicks.isEmpty ? "录制时没有点击，不会放大。"
                : "记录到 \(timeline.clicks.count) 次点击\(style.zooms ? "，合成 \(plan.segments.count) 段放大\(off > 0 ? "（关掉了 \(off) 段）" : "")。点下面橙色的一段可以关掉它" : "")。"
        } else {
            info.stringValue = "这段录屏没有记录点击（更新到这一版之前录的），只能加背景。"
        }
    }

    @objc private func controlChanged() {
        style.zooms = zoomBox.state == .on
        style.clickEffects = clickBox.state == .on
        style.pointerHalo = haloBox.state == .on
        style.showsKeys = keysBox.state == .on
        style.zoomScale = (scaleSlider.doubleValue * 10).rounded() / 10
        style.hold = (holdSlider.doubleValue * 2).rounded() / 2
        style.padding = paddingSlider.doubleValue.rounded()
        style.cornerRadius = radiusSlider.doubleValue.rounded()
        style.background = Self.backgrounds[max(0, backgroundPopup.indexOfSelectedItem)].1
        Self.save(style)
        showStyle()
        compose()
    }

    /// The style last used, so the next recording starts the same.
    private static func savedStyle() -> RecordingFinisher.Style {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: styleKey) else { return RecordingFinisher.Style() }
        var style = RecordingFinisher.Style()
        style.zooms = saved["zooms"] as? Bool ?? style.zooms
        style.zoomScale = saved["zoomScale"] as? Double ?? style.zoomScale
        style.hold = saved["hold"] as? Double ?? style.hold
        style.padding = saved["padding"] as? Double ?? style.padding
        style.cornerRadius = saved["cornerRadius"] as? Double ?? style.cornerRadius
        style.clickEffects = saved["clickEffects"] as? Bool ?? style.clickEffects
        style.pointerHalo = saved["pointerHalo"] as? Bool ?? style.pointerHalo
        style.showsKeys = saved["showsKeys"] as? Bool ?? style.showsKeys
        if let index = saved["background"] as? Int, backgrounds.indices.contains(index) { style.background = backgrounds[index].1 }
        return style
    }

    private static func save(_ style: RecordingFinisher.Style) {
        let index = backgrounds.firstIndex { entry in
            switch (entry.1, style.background) {
            case (nil, nil): true
            case let (a?, b?): a.0 == b.0 && a.1 == b.1
            default: false
            }
        } ?? 0
        UserDefaults.standard.set(["zooms": style.zooms, "zoomScale": style.zoomScale, "hold": style.hold, "padding": style.padding,
                                   "cornerRadius": style.cornerRadius, "background": index, "clickEffects": style.clickEffects,
                                   "pointerHalo": style.pointerHalo, "showsKeys": style.showsKeys], forKey: styleKey)
    }

    // MARK: Playing

    private func load() {
        status.stringValue = "正在读取录屏…"
        track.timeline = timeline
        Task {
            if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await videoTrack.load(.naturalSize) {
                videoSize = size
                if let timeline, timeline.width > 0 { pixelsPerPoint = max(1, size.width / timeline.width) }
            }
            duration = (try? await asset.load(.duration).seconds) ?? 0
            track.duration = max(duration, 0.1)
            track.edit = edit
            selected(nil)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
                MainActor.assumeIsolated { self.showPlayhead(time.seconds) }
            }
            rebuild(at: 0)
            player.play()
        }
    }

    /// What's played and exported: the timeline on the edited time, and the zoom plan from the
    /// clicks whose zoom is on.
    private func editedTimeline() -> (timeline: RecordingTimeline?, plan: ZoomPlan) {
        guard let timeline else { return (nil, ZoomPlan(segments: [])) }
        var zoomed = timeline
        zoomed.clicks.removeAll { disabledClicks.contains($0.t) }
        return (timeline.edited(by: edit, duration: duration), style.plan(for: zoomed.edited(by: edit, duration: duration)))
    }

    /// Plays the recording as edited from recording time `t`.
    private func rebuild(at t: Double) {
        composing?.cancel()
        let edit = edit, duration = duration, asset = asset, wasPlaying = player.rate > 0
        composing = Task {
            guard let edited = try? await StudioMedia.edited(asset, edit: edit, duration: duration), !Task.isCancelled else { return }
            playing = edited
            player.replaceCurrentItem(with: AVPlayerItem(asset: edited))
            await applyFinish()
            await player.seek(to: CMTime(seconds: playTime(for: t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        }
    }

    /// The finish for the current style, applied to what's playing.
    private func compose() {
        composing?.cancel()
        composing = Task { await applyFinish() }
    }

    private func applyFinish() async {
        guard let playing else { return }
        let (timeline, plan) = editedTimeline()
        let style = style, scale = pixelsPerPoint, size = videoSize
        guard let composition = try? await StudioMedia.composition(for: playing, style: style, plan: plan, scale: scale, videoSize: size, timeline: timeline),
              !Task.isCancelled else { return }
        player.currentItem?.videoComposition = composition
        exportButton.isEnabled = true
        if status.stringValue.hasPrefix("正在读取") {
            status.stringValue = "边播放边看效果；在下面的轨道上拖选一段可以剪掉或加速。"
        }
        if let url = exportOnLoad {
            exportOnLoad = nil
            export(to: url)
        }
    }

    // MARK: Track

    /// Where recording time `t` plays: the end of a cut it falls in.
    private func playTime(for t: Double) -> Double {
        if let time = edit.editedTime(t, duration: duration) { return time }
        let cut = edit.changes.first { $0.isCut && $0.start <= t && t <= $0.end }
        return cut.flatMap { edit.editedTime($0.end + 0.001, duration: duration) } ?? 0
    }

    private func showPlayhead(_ playerTime: Double) {
        guard playerTime.isFinite else { return }
        track.playhead = edit.originalTime(playerTime, duration: duration)
    }

    private func seek(to t: Double) {
        player.seek(to: CMTime(seconds: playTime(for: t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        track.playhead = t
    }

    private func selected(_ range: ClosedRange<Double>?) {
        selection = range
        for button in [cutButton, speedButton, restoreButton] { button.isEnabled = range != nil }
        if let range {
            selectionLabel.stringValue = String(format: "选中 %@ – %@（%.1f 秒）", Self.clock(range.lowerBound), Self.clock(range.upperBound),
                                                range.upperBound - range.lowerBound)
        } else {
            let saved = duration - edit.editedDuration(of: duration)
            selectionLabel.stringValue = edit.changes.isEmpty ? "在轨道上拖选一段，可以剪掉或加速；点一下跳到那里。"
                : String(format: "成片 %@，比原来短 %.1f 秒。", Self.clock(edit.editedDuration(of: duration)), saved)
        }
    }

    private static func clock(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    private func change(_ speed: Double?) {
        guard let range = selection else { return }
        if let speed {
            edit.apply(.init(start: range.lowerBound, end: range.upperBound, speed: speed))
        } else {
            edit.clear(from: range.lowerBound, to: range.upperBound)
        }
        track.edit = edit
        track.clearSelection()
        rebuild(at: range.lowerBound)
    }

    @objc private func cutClicked() { change(0) }
    @objc private func speedClicked() { change(4) }
    @objc private func restoreClicked() { change(nil) }

    private func toggleZoom(_ clicks: [Double]) {
        if clicks.allSatisfy({ disabledClicks.contains($0) }) {
            disabledClicks.subtract(clicks)
        } else {
            disabledClicks.formUnion(clicks)
        }
        showStyle()
        compose()
    }

    @objc private func guideClicked() {
        GuideWindow.show(video: video)
    }

    // MARK: Exporting

    @objc private func presetChanged() {
        preset = ExportPreset.allCases[max(0, presetPopup.indexOfSelectedItem)]
        UserDefaults.standard.set(preset.rawValue, forKey: "studioPreset")
    }

    @objc private func exportClicked() {
        let panel = NSSavePanel()
        panel.title = "导出精修后的录屏"
        panel.allowedContentTypes = [preset == .gif ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.shared.saveFolder
        let base = video.deletingPathExtension().lastPathComponent.hasPrefix("PixSnap") ? video.deletingPathExtension().lastPathComponent : "PixSnap 录屏"
        panel.nameFieldStringValue = "\(base) 精修.\(preset.fileExtension)"
        panel.beginSheetModal(for: self) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.export(to: url)
            }
        }
    }

    private func export(to url: URL) {
        let preset = url.pathExtension.lowercased() == "gif" ? .gif : preset
        exportButton.isEnabled = false
        spinner.startAnimation(nil)
        status.stringValue = "正在导出…"
        let (timeline, plan) = editedTimeline()
        let style = style, scale = pixelsPerPoint, size = videoSize, asset = asset, edit = edit, duration = duration
        Task {
            do {
                let edited = try await StudioMedia.edited(asset, edit: edit, duration: duration)
                let length = edit.editedDuration(of: duration)
                let full = RecordingFinisher.outputSize(video: size, scale: scale, style: style)
                let settings = preset.settings(size: full, duration: length)
                let composition = try await StudioMedia.composition(for: edited, style: style, plan: plan, scale: scale, videoSize: size,
                                                                    timeline: timeline, outputSize: settings.size)
                let target = preset == .gif ? FileManager.default.temporaryDirectory.appendingPathComponent("PixSnap-\(UUID().uuidString).mp4") : url
                try await StudioMedia.write(edited, composition: composition, bitRate: settings.bitRate, to: target) { fraction in
                    Task { @MainActor in self.status.stringValue = String(format: "正在导出… %d%%", Int(fraction * 100)) }
                }
                if preset == .gif {
                    status.stringValue = "正在做 GIF…"
                    defer { try? FileManager.default.removeItem(at: target) }
                    try? FileManager.default.removeItem(at: url)
                    try await GIFExporter.export(target, duration: length, to: url)
                }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                status.stringValue = "已导出到“\(url.deletingLastPathComponent().lastPathComponent)”，\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSLog("PixSnap could not export a finished recording: \(error)")
                status.stringValue = "导出失败：\(error.localizedDescription)"
            }
            spinner.stopAnimation(nil)
            exportButton.isEnabled = true
        }
    }
}
