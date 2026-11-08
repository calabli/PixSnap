import AVFoundation
import AVKit
import AppKit
import PixSnapCore
import PixSnapRender
import UniformTypeIdentifiers

/// 精修: a recording played with its finish applied live, zooming in where it was clicked
/// (`ZoomPlan`, from the timeline saved beside it) on a background with room, rounded corners and a
/// shadow (`RecordingFinisher`). The controls change it as it plays; 导出视频 writes it as an MP4.
/// The recording itself stays as it was.
@MainActor
final class StudioWindow: NSWindow {
    private static var open: [StudioWindow] = []

    /// Opens 精修 for the recording at `video` (its timeline, if any, is beside it); with
    /// `exportTo`, exports there straight away (`--studio-export`).
    static func show(video: URL, exportTo: URL? = nil) {
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
    private let spinner = NSProgressIndicator()
    private var composing: Task<Void, Never>?

    private let zoomBox = NSButton(checkboxWithTitle: "点击时自动放大", target: nil, action: nil)
    private let scaleSlider = NSSlider(value: 2, minValue: 1.5, maxValue: 3, target: nil, action: nil)
    private let holdSlider = NSSlider(value: 1.5, minValue: 0.5, maxValue: 4, target: nil, action: nil)
    private let backgroundPopup = NSPopUpButton()
    private let paddingSlider = NSSlider(value: 48, minValue: 0, maxValue: 120, target: nil, action: nil)
    private let radiusSlider = NSSlider(value: 14, minValue: 0, maxValue: 30, target: nil, action: nil)
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
        zoomBox.target = self
        zoomBox.action = #selector(controlChanged)
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
            heading("背景"), backgroundRow, row("边距", paddingSlider, unit: "点"), row("圆角", radiusSlider, unit: "点"),
        ])
        inspector.orientation = .vertical
        inspector.alignment = .leading
        inspector.spacing = 10
        inspector.setCustomSpacing(22, after: info)
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
        let bottom = NSStackView(views: [spinner, status, NSView(), exportButton])
        bottom.spacing = 8
        bottom.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        bottom.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(playerView)
        content.addSubview(inspector)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            playerView.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
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
            let plan = style.plan(for: timeline)
            info.stringValue = timeline.clicks.isEmpty ? "录制时没有点击，不会放大。"
                : "记录到 \(timeline.clicks.count) 次点击\(style.zooms ? "，合成 \(plan.segments.count) 段放大" : "")。"
        } else {
            info.stringValue = "这段录屏没有记录点击（更新到这一版之前录的），只能加背景。"
        }
    }

    @objc private func controlChanged() {
        style.zooms = zoomBox.state == .on
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
                                   "cornerRadius": style.cornerRadius, "background": index], forKey: styleKey)
    }

    // MARK: Playing

    private func load() {
        status.stringValue = "正在读取录屏…"
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize) {
                videoSize = size
                if let timeline, timeline.width > 0 { pixelsPerPoint = max(1, size.width / timeline.width) }
            }
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            compose()
            player.play()
        }
    }

    /// The finish for the current style, applied to what's playing.
    private func compose() {
        composing?.cancel()
        let style = style, plan = style.plan(for: timeline), scale = pixelsPerPoint, size = videoSize, asset = asset
        composing = Task {
            guard let composition = try? await Self.composition(for: asset, style: style, plan: plan, scale: scale, videoSize: size),
                  !Task.isCancelled else { return }
            player.currentItem?.videoComposition = composition
            exportButton.isEnabled = true
            status.stringValue = "边播放边看效果；调整右边的设置会马上更新。"
            if let url = exportOnLoad {
                exportOnLoad = nil
                export(to: url)
            }
        }
    }

    private static func composition(for asset: AVAsset, style: RecordingFinisher.Style, plan: ZoomPlan, scale: CGFloat,
                                    videoSize: CGSize) async throws -> AVVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = RecordingFinisher.frame(request.sourceImage, at: request.compositionTime.seconds, plan: plan, scale: scale, style: style)
            request.finish(with: frame, context: nil)
        }
        composition.renderSize = RecordingFinisher.outputSize(video: videoSize, scale: scale, style: style)
        return composition
    }

    // MARK: Exporting

    @objc private func exportClicked() {
        let panel = NSSavePanel()
        panel.title = "导出精修后的录屏"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.shared.saveFolder
        panel.nameFieldStringValue = video.deletingPathExtension().lastPathComponent.hasPrefix("PixSnap")
            ? video.deletingPathExtension().lastPathComponent + " 精修.mp4"
            : "PixSnap 录屏 精修.mp4"
        panel.beginSheetModal(for: self) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.export(to: url)
            }
        }
    }

    private func export(to url: URL) {
        exportButton.isEnabled = false
        spinner.startAnimation(nil)
        status.stringValue = "正在导出…"
        let style = style, plan = style.plan(for: timeline), scale = pixelsPerPoint, size = videoSize, asset = asset
        Task {
            do {
                let composition = try await Self.composition(for: asset, style: style, plan: plan, scale: scale, videoSize: size)
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                    throw CocoaError(.featureUnsupported)
                }
                session.videoComposition = composition
                try? FileManager.default.removeItem(at: url)
                try await session.export(to: url, as: .mp4)
                status.stringValue = "已导出到“\(url.deletingLastPathComponent().lastPathComponent)”"
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
