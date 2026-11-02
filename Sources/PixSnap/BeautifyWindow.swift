import AppKit
import PixSnapCore
import PixSnapRender

/// Measures a screenshot for 智能美化: its text (read on this Mac), colors and source app.
enum ContentAnalyzer {
    static func signals(for image: CGImage, sourceApp: String?) async -> ContentSignals {
        let lines = await TextRecognizer.lines(in: image)
        let measured = await Task.detached(priority: .userInitiated) { Beautifier.measure(image) }.value
        let coverage = min(1, lines.reduce(0) { $0 + Double($1.box.width * $1.box.height) })
        return ContentSignals(lines: lines.map(\.text), lineSpans: lines.map { Double($0.box.minX) ... Double($0.box.maxX) },
                              textCoverage: coverage, brightness: measured.brightness, flatness: measured.flatness,
                              concentration: measured.concentration, accent: measured.accent,
                              aspectRatio: Double(image.width) / Double(max(image.height, 1)), sourceApp: sourceApp)
    }
}

/// Styles saved with "存为我的方案", by name, in UserDefaults. They show as tiles in 美化 and can be
/// what "截完自动美化" uses.
@MainActor
enum BeautifyPresets {
    struct Preset: Codable, Identifiable {
        var id = UUID()
        var style: BeautifyStyle
    }

    private static let key = "beautifyPresets"

    static var all: [Preset] {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) } }
    }

    static func add(_ style: BeautifyStyle) {
        all.append(Preset(style: style))
    }

    static func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        if AppSettings.shared.autoBeautify == id.uuidString { AppSettings.shared.autoBeautify = AppSettings.autoBeautifySmart }
    }

    /// The style "截完自动美化" uses for `capture`: a saved one, or the one that suits what it shows.
    static func automaticStyle(for capture: Capture, sourceApp: String?) async -> BeautifyStyle? {
        let choice = AppSettings.shared.autoBeautify
        if choice == AppSettings.autoBeautifyOff { return nil }
        if let preset = all.first(where: { $0.id.uuidString == choice }) { return preset.style }
        let signals = await ContentAnalyzer.signals(for: capture.image, sourceApp: sourceApp)
        return BeautifyStyle.recommended(for: ContentClassifier.classify(signals), signals)
    }
}

/// 美化: the screenshot finished in the style that suits what it shows ("识别为：代码"), with the
/// other styles and the saved ones ("我的") to pick from underneath, and controls to adjust the
/// room around it, its corners, shadow and frame (a window, a hairline or a phone). The result
/// can be copied, saved, or floated as a new capture (kept in history); the original stays as
/// it was. "存为我的方案" keeps the adjusted style for next time.
@MainActor
final class BeautifyWindow: NSPanel {
    /// The finished screenshot, to float and keep in history.
    var onKeep: ((Capture) -> Void)?
    var onClosed: ((BeautifyWindow) -> Void)?

    private let capture: Capture
    private let sourceApp: String?
    private var styles: [BeautifyStyle] = []
    /// The saved preset behind each tile, where there is one.
    private var presetIDs: [UUID?] = []
    private var selected = 0
    /// The selected style as adjusted with the controls; what's previewed and finished.
    private var current: BeautifyStyle?
    private var isDark = false
    private var small: (image: CGImage, scale: CGFloat)?
    private var renderWork: Task<Void, Never>?

    private let paddingSlider = NSSlider(value: 40, minValue: BeautifyStyle.manualPaddingRange.lowerBound,
                                         maxValue: BeautifyStyle.manualPaddingRange.upperBound, target: nil, action: nil)
    private let paddingValue = NSTextField(labelWithString: "")
    private let radiusSlider = NSSlider(value: 12, minValue: BeautifyStyle.cornerRadiusRange.lowerBound,
                                        maxValue: BeautifyStyle.cornerRadiusRange.upperBound, target: nil, action: nil)
    private let radiusValue = NSTextField(labelWithString: "")
    private let shadowControl = NSSegmentedControl(labels: BeautifyStyle.Shadow.allCases.map(\.title), trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let framePopup = NSPopUpButton()
    private let preview = NSImageView()
    private let status = NSTextField(labelWithString: "正在识别内容…")
    private let tiles = NSStackView()
    private var actionButtons: [NSButton] = []

    private static let size = CGSize(width: 780, height: 620)
    private static let previewHeight: CGFloat = 380
    /// Previews and tiles are drawn from a copy at most this many pixels across, so they come quickly.
    private static let previewPixels: CGFloat = 1100

    private static var open: [BeautifyWindow] = []

    static func show(_ capture: Capture, sourceApp: String?, near frame: CGRect, on screen: NSScreen, onKeep: @escaping (Capture) -> Void) {
        let window = BeautifyWindow(capture: capture, sourceApp: sourceApp, near: frame, on: screen)
        window.onKeep = onKeep
        open.append(window)
        window.onClosed = { closed in open.removeAll { $0 === closed } }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.analyze()
    }

    private init(capture: Capture, sourceApp: String?, near frame: CGRect, on screen: NSScreen) {
        self.capture = capture
        self.sourceApp = sourceApp
        let visible = screen.visibleFrame
        let origin = CGPoint(x: min(max(frame.midX - Self.size.width / 2, visible.minX + 10), visible.maxX - Self.size.width - 10),
                             y: min(max(frame.midY - Self.size.height / 2, visible.minY + 10), visible.maxY - Self.size.height - 10))
        super.init(contentRect: CGRect(origin: origin, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: Self.size))
        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true

        preview.imageScaling = .scaleProportionallyDown
        // The image's own size mustn't widen the panel.
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.textColor = .secondaryLabelColor
        tiles.orientation = .horizontal
        tiles.spacing = 8
        tiles.distribution = .fillEqually

        let buttons = NSStackView(views: [
            status,
            NSView(),
            button("复制", symbol: "doc.on.doc", action: #selector(copyResult)),
            button("保存", symbol: "square.and.arrow.down", action: #selector(saveResult)),
            button("放到屏幕上", symbol: "macwindow.on.rectangle", action: #selector(keepResult)),
            button("关闭", symbol: "xmark", action: #selector(closeClicked)),
        ])
        buttons.spacing = 6

        let controls = makeControls()
        let column = NSStackView(views: [preview, tiles, controls, buttons])
        column.orientation = .vertical
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.size.width),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight),
            preview.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            tiles.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            tiles.heightAnchor.constraint(equalToConstant: 96),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            controls.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
        ])
        contentView = content
        actionButtons.forEach { $0.isEnabled = false }
        preview.image = NSImage(cgImage: capture.image, size: capture.pointSize)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        onClosed?(self)
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        actionButtons.append(button)
        return button
    }

    // MARK: Adjusting

    private func makeControls() -> NSView {
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            return label
        }
        for (slider, value) in [(paddingSlider, paddingValue), (radiusSlider, radiusValue)] {
            slider.target = self
            slider.action = #selector(controlChanged)
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        paddingSlider.toolTip = "截图四周留多宽（点）"
        radiusSlider.toolTip = "圆角大小（点）"
        shadowControl.target = self
        shadowControl.action = #selector(controlChanged)
        shadowControl.toolTip = "阴影"
        framePopup.target = self
        framePopup.action = #selector(controlChanged)
        framePopup.toolTip = "外框：窗口标题栏、细边框，或者套一个手机外壳（适合聊天截图）"
        let save = NSButton(title: "存为方案…", target: self, action: #selector(savePreset))
        save.bezelStyle = .rounded
        save.toolTip = "把现在调好的样式存起来，下次直接选；也可以在设置里设成截完自动美化"
        actionButtons.append(save)
        let row = NSStackView(views: [label("边距"), paddingSlider, paddingValue, label("圆角"), radiusSlider, radiusValue,
                                      label("阴影"), shadowControl, label("外框"), framePopup, NSView(), save])
        row.spacing = 6
        for view in [paddingValue, radiusValue, shadowControl] { row.setCustomSpacing(14, after: view) }
        row.setCustomSpacing(14, after: framePopup)
        return row
    }

    /// Shows `style` on the controls; with no padding of its own, the room it works out to here.
    private func showOnControls(_ style: BeautifyStyle) {
        let size = capture.pointSize
        paddingSlider.doubleValue = style.paddingPoints(width: size.width, height: size.height)
        radiusSlider.doubleValue = style.cornerRadius
        shadowControl.selectedSegment = BeautifyStyle.Shadow.allCases.firstIndex(of: style.shadow) ?? 0
        framePopup.removeAllItems()
        let frames = BeautifyStyle.Frame.choices(dark: isDark)
        framePopup.addItems(withTitles: frames.map(\.title))
        framePopup.selectItem(at: frames.firstIndex { $0.isKind(of: style.frame) } ?? 0)
        showValues()
    }

    private func showValues() {
        paddingValue.stringValue = "\(Int(paddingSlider.doubleValue.rounded()))"
        radiusValue.stringValue = "\(Int(radiusSlider.doubleValue.rounded()))"
    }

    @objc private func controlChanged() {
        guard var style = current else { return }
        style.fixedPadding = paddingSlider.doubleValue.rounded()
        style.cornerRadius = radiusSlider.doubleValue.rounded()
        style.shadow = BeautifyStyle.Shadow.allCases[max(0, shadowControl.selectedSegment)]
        let frames = BeautifyStyle.Frame.choices(dark: isDark)
        let frame = frames[max(0, framePopup.indexOfSelectedItem)]
        // A phone's screen has big corners; going into one rounds them to match.
        if case .phone = frame, !style.frame.isKind(of: frame), style.cornerRadius < 30 {
            style.cornerRadius = 36
            radiusSlider.doubleValue = 36
        }
        style.frame = frame
        current = style
        showValues()
        renderPreview()
    }

    /// The preview redrawn from the small copy, a moment after the controls stop moving.
    private func renderPreview() {
        guard let style = current, let small else { return }
        renderWork?.cancel()
        renderWork = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { Beautifier.render(small.image, scale: small.scale, style: style) }.value
            guard !Task.isCancelled, let image else { return }
            preview.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
    }

    @objc private func savePreset() {
        guard var style = current else { return }
        let alert = NSAlert()
        alert.messageText = "存为我的方案"
        alert.informativeText = "给这个样式起个名字。存好后在美化里直接选，也可以在设置 › 截图里设成截完自动美化。"
        let field = NSTextField(string: "我的方案 \(BeautifyPresets.all.count + 1)")
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "存好")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: self) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                style.name = name.isEmpty ? "我的方案" : name
                self?.save(style)
            }
        }
    }

    private func save(_ style: BeautifyStyle) {
        BeautifyPresets.add(style)
        status.stringValue = "已存为“\(style.name)”"
        rebuildTiles(selecting: styles.count)
    }

    // MARK: Styles

    private func analyze() {
        let capture = capture
        Task {
            let signals = await ContentAnalyzer.signals(for: capture.image, sourceApp: sourceApp)
            let kind = ContentClassifier.classify(signals)
            isDark = signals.isDark
            suggested = BeautifyStyle.choices(for: kind, signals)
            status.stringValue = "识别为：\(kind.title)"
            small = Self.smallCopy(of: capture)
            rebuildTiles(selecting: 0)
            actionButtons.forEach { $0.isEnabled = true }
        }
    }

    /// The styles suggested for this screenshot, before the saved ones.
    private var suggested: [BeautifyStyle] = []

    /// The suggested styles, then the saved ones, as tiles; selects the one at `index`.
    private func rebuildTiles(selecting index: Int) {
        guard let small else { return }
        let presets = BeautifyPresets.all
        styles = suggested + presets.map(\.style)
        presetIDs = suggested.map { _ in nil } + presets.map(\.id)
        let styles = styles
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                styles.map { Beautifier.render(small.image, scale: small.scale, style: $0) }
            }.value
            tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
            tileButtons = []
            for (index, image) in rendered.enumerated() {
                tiles.addArrangedSubview(tile(index: index, image: image))
            }
            previews = rendered
            select(min(index, styles.count - 1))
        }
    }

    private var previews: [CGImage?] = []
    private var tileButtons: [NSButton] = []

    private func tile(index: Int, image: CGImage?) -> NSButton {
        let title = index == 0 ? "推荐 · \(styles[index].name)" : presetIDs[index] != nil ? "我的 · \(styles[index].name)" : styles[index].name
        let thumbnail = image.map { image -> NSImage in
            let fit = min(92 / CGFloat(image.width), 64 / CGFloat(image.height))
            return NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit))
        }
        let button = NSButton(title: title, image: thumbnail ?? NSImage(), target: self, action: #selector(tileClicked))
        button.tag = index
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.imagePosition = .imageAbove
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 2
        button.layer?.borderColor = NSColor.clear.cgColor
        if presetIDs[index] != nil {
            let menu = NSMenu()
            let delete = NSMenuItem(title: "删除这个方案", action: #selector(deletePreset(_:)), keyEquivalent: "")
            delete.target = self
            delete.tag = index
            menu.addItem(delete)
            button.menu = menu
            button.toolTip = "右键可以删除这个方案"
        }
        tileButtons.append(button)
        return button
    }

    @objc private func deletePreset(_ item: NSMenuItem) {
        guard presetIDs.indices.contains(item.tag), let id = presetIDs[item.tag] else { return }
        BeautifyPresets.remove(id)
        status.stringValue = "已删除“\(styles[item.tag].name)”"
        rebuildTiles(selecting: selected == item.tag ? 0 : min(selected, styles.count - 2))
    }

    @objc private func tileClicked(_ sender: NSButton) { select(sender.tag) }

    private func select(_ index: Int) {
        guard styles.indices.contains(index) else { return }
        selected = index
        current = styles[index]
        showOnControls(styles[index])
        for button in tileButtons {
            button.layer?.borderColor = button.tag == index ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            button.layer?.backgroundColor = button.tag == index ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : nil
        }
        if let image = previews[index] {
            preview.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
    }

    /// A copy no wider (or taller) than `previewPixels`, and its pixels per point.
    private static func smallCopy(of capture: Capture) -> (CGImage, CGFloat) {
        let fit = min(1, previewPixels / CGFloat(max(capture.image.width, capture.image.height)))
        guard fit < 1 else { return (capture.image, capture.scale) }
        let width = Int(CGFloat(capture.image.width) * fit), height = Int(CGFloat(capture.image.height) * fit)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (capture.image, capture.scale) }
        context.interpolationQuality = .high
        context.draw(capture.image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (context.makeImage() ?? capture.image, capture.scale * fit)
    }

    // MARK: The result

    /// The original finished in the selected style, at full size.
    private func finished(_ use: @escaping (Capture) -> Void) {
        guard let style = current else { return }
        let capture = capture
        actionButtons.forEach { $0.isEnabled = false }
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                Beautifier.render(capture.image, scale: capture.scale, style: style)
            }.value
            actionButtons.forEach { $0.isEnabled = true }
            guard let image else { return }
            use(Capture(image: image, scale: capture.scale))
        }
    }

    @objc private func copyResult() {
        finished { [weak self] result in
            ImageExporter.copyToPasteboard(result)
            self?.status.stringValue = "已复制"
        }
    }

    @objc private func saveResult() {
        finished { [weak self] result in
            ImageExporter.saveAsking(result) { outcome in
                if case .success(let url) = outcome {
                    self?.status.stringValue = "已保存到“\(url.deletingLastPathComponent().lastPathComponent)”"
                }
            }
        }
    }

    @objc private func keepResult() {
        finished { [weak self] result in
            self?.onKeep?(result)
            self?.close()
        }
    }

    @objc private func closeClicked() { close() }
}
