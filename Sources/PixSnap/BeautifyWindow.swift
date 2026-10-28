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

/// 美化: the screenshot finished in the style that suits what it shows ("识别为：代码"), with the
/// other styles to pick from underneath. The result can be copied, saved, or floated as a new
/// capture (kept in history); the original stays as it was.
@MainActor
final class BeautifyWindow: NSPanel {
    /// The finished screenshot, to float and keep in history.
    var onKeep: ((Capture) -> Void)?
    var onClosed: ((BeautifyWindow) -> Void)?

    private let capture: Capture
    private let sourceApp: String?
    private var styles: [BeautifyStyle] = []
    private var selected = 0
    private let preview = NSImageView()
    private let status = NSTextField(labelWithString: "正在识别内容…")
    private let tiles = NSStackView()
    private var actionButtons: [NSButton] = []

    private static let size = CGSize(width: 780, height: 600)
    private static let previewHeight: CGFloat = 400
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

        let column = NSStackView(views: [preview, tiles, buttons])
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

    // MARK: Styles

    private func analyze() {
        let capture = capture
        Task {
            let signals = await ContentAnalyzer.signals(for: capture.image, sourceApp: sourceApp)
            let kind = ContentClassifier.classify(signals)
            styles = BeautifyStyle.choices(for: kind, signals)
            status.stringValue = "识别为：\(kind.title)"
            let (small, smallScale) = Self.smallCopy(of: capture)
            let styles = styles
            let rendered = await Task.detached(priority: .userInitiated) {
                styles.map { Beautifier.render(small, scale: smallScale, style: $0) }
            }.value
            for (index, image) in rendered.enumerated() {
                tiles.addArrangedSubview(tile(index: index, image: image))
            }
            previews = rendered
            select(0)
            actionButtons.forEach { $0.isEnabled = true }
        }
    }

    private var previews: [CGImage?] = []
    private var tileButtons: [NSButton] = []

    private func tile(index: Int, image: CGImage?) -> NSButton {
        let title = index == 0 ? "推荐 · \(styles[index].name)" : styles[index].name
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
        tileButtons.append(button)
        return button
    }

    @objc private func tileClicked(_ sender: NSButton) { select(sender.tag) }

    private func select(_ index: Int) {
        selected = index
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
        guard styles.indices.contains(selected) else { return }
        let style = styles[selected], capture = capture
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
