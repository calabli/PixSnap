import AppKit
import NaturalLanguage
import PixSnapCore
import PixSnapRender
import SwiftUI
import Translation

/// 截图翻译: the screenshot's text read and translated on this Mac (Apple's own translation; the
/// first time a language is used, macOS asks to download it), each paragraph's translation
/// written over the original in its colors. The result can be copied, saved, or floated as a
/// new capture (kept in history); the original stays as it was.
@MainActor
final class TranslateWindow: NSPanel {
    var onKeep: ((Capture) -> Void)?
    var onClosed: ((TranslateWindow) -> Void)?

    private let capture: Capture
    private var paragraphs: [TranslationLayout.Paragraph] = []
    private var translations: [String] = []
    private var translated: CGImage?
    private var source: String?
    private var target = TranslationTarget.simplifiedChinese

    private let preview = NSImageView()
    private let status = NSTextField(labelWithString: "正在识别文字…")
    private let shown = NSSegmentedControl(labels: ["译文", "原文"], trackingMode: .selectOne, target: nil, action: nil)
    private let targetMenu = NSPopUpButton()
    private var actionButtons: [NSButton] = []
    /// Hosts SwiftUI's translation task, which also asks to download languages.
    private let runner = NSView()

    private static let size = CGSize(width: 780, height: 600)
    private static let previewHeight: CGFloat = 440
    private static let targetKey = "translationTarget"

    private static var open: [TranslateWindow] = []

    static func show(_ capture: Capture, near frame: CGRect, on screen: NSScreen, onKeep: @escaping (Capture) -> Void) {
        let window = TranslateWindow(capture: capture, near: frame, on: screen)
        window.onKeep = onKeep
        open.append(window)
        window.onClosed = { closed in open.removeAll { $0 === closed } }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.recognize()
    }

    private init(capture: Capture, near frame: CGRect, on screen: NSScreen) {
        self.capture = capture
        let visible = screen.visibleFrame
        let origin = CGPoint(x: min(max(frame.midX - Self.size.width / 2, visible.minX + 10), visible.maxX - Self.size.width - 10),
                             y: min(max(frame.midY - Self.size.height / 2, visible.minY + 10), visible.maxY - Self.size.height - 10))
        // Titled, so macOS has somewhere to show its language download sheet.
        super.init(contentRect: CGRect(origin: origin, size: Self.size), styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "截图翻译"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: Self.size))
        content.material = .popover
        content.state = .active

        preview.imageScaling = .scaleProportionallyDown
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        shown.selectedSegment = 0
        shown.target = self
        shown.action = #selector(shownChanged)
        shown.isEnabled = false
        shown.toolTip = "看译文还是原文"
        for language in TranslationTarget.allCases {
            targetMenu.addItem(withTitle: language.title)
            targetMenu.lastItem?.representedObject = language.rawValue
        }
        targetMenu.target = self
        targetMenu.action = #selector(targetChanged)
        targetMenu.toolTip = "译成哪种语言"
        let into = NSTextField(labelWithString: "译成")
        into.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [shown, into, targetMenu, status])
        controls.spacing = 8
        controls.setCustomSpacing(16, after: shown)
        controls.setCustomSpacing(16, after: targetMenu)
        let buttons = NSStackView(views: [
            NSView(),
            button("复制图片", symbol: "doc.on.doc", action: #selector(copyImage)),
            button("复制译文", symbol: "text.quote", action: #selector(copyText)),
            button("保存", symbol: "square.and.arrow.down", action: #selector(saveImage)),
            button("放到屏幕上", symbol: "macwindow.on.rectangle", action: #selector(keepImage)),
            button("关闭", symbol: "xmark", action: #selector(closeClicked)),
        ])
        buttons.spacing = 6

        let column = NSStackView(views: [preview, controls, buttons])
        column.orientation = .vertical
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 30, left: 16, bottom: 14, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        runner.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        content.addSubview(runner)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: Self.size.width),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight),
            preview.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            controls.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -32),
        ])
        contentView = content
        setButtons(enabled: false)
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
        if title != "关闭" { actionButtons.append(button) }
        return button
    }

    private func setButtons(enabled: Bool) {
        actionButtons.forEach { $0.isEnabled = enabled }
        shown.isEnabled = enabled
    }

    // MARK: Translating

    private func recognize() {
        let image = capture.image
        Task {
            let lines = await TextRecognizer.lines(in: image)
            paragraphs = TranslationLayout.paragraphs(lines, aspectRatio: Double(image.width) / Double(max(image.height, 1)))
            guard !paragraphs.isEmpty else {
                status.stringValue = "图里没有找到文字"
                targetMenu.isEnabled = false
                return
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(paragraphs.map(\.text).joined(separator: "\n"))
            source = recognizer.dominantLanguage?.rawValue
            let preferred = UserDefaults.standard.string(forKey: Self.targetKey).flatMap(TranslationTarget.init(rawValue:))
            target = TranslationTarget.suggested(forSource: source, preferred: preferred)
            targetMenu.selectItem(at: TranslationTarget.allCases.firstIndex(of: target) ?? 0)
            translate()
        }
    }

    @objc private func targetChanged() {
        guard let raw = targetMenu.selectedItem?.representedObject as? String, let chosen = TranslationTarget(rawValue: raw) else { return }
        target = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: Self.targetKey)
        translate()
    }

    private func translate() {
        guard !paragraphs.isEmpty else { return }
        setButtons(enabled: false)
        if TranslationTarget.matches(target, source) {
            status.stringValue = "图里已经是\(target.title)，换一种语言试试"
            show(original: true)
            return
        }
        status.stringValue = "正在翻译：\(Self.name(of: source)) → \(target.title)…"
        let texts = paragraphs.map(\.text)
        if CommandLine.arguments.contains("--fake-translation") {
            // Lets the layout be seen without downloading languages.
            finish(texts.map { "〔译〕" + $0 })
            return
        }
        guard #available(macOS 15, *) else {
            status.stringValue = "截图翻译需要 macOS 15 或更新版本"
            return
        }
        let configuration = TranslationSession.Configuration(source: source.map { Locale.Language(identifier: $0) },
                                                             target: Locale.Language(identifier: target.rawValue))
        let host = NSHostingView(rootView: TranslationRunner(configuration: configuration, texts: texts) { [weak self] result in
            switch result {
            case .success(let translated): self?.finish(translated)
            case .failure(let error): self?.status.stringValue = "没能翻译：\(error.localizedDescription)"
            }
        })
        host.frame = runner.bounds
        runner.subviews.forEach { $0.removeFromSuperview() }
        runner.addSubview(host)
    }

    private func finish(_ translated: [String]) {
        translations = translated
        // Lines well taller than most are headings.
        let heights = paragraphs.map(\.lineHeight).sorted()
        let usual = heights[heights.count / 2]
        let blocks = zip(paragraphs, translated).map { paragraph, text in
            TranslationOverlay.Block(box: paragraph.box, lineHeight: paragraph.lineHeight, text: text, bold: paragraph.lineHeight > usual * 1.18)
        }
        let image = capture.image, target = target
        Task {
            let rendered = await Task.detached(priority: .userInitiated) { TranslationOverlay.render(image, blocks: blocks) }.value
            guard target == self.target else { return }
            self.translated = rendered
            status.stringValue = "\(Self.name(of: source)) → \(target.title) · \(paragraphs.count) 段"
            shown.selectedSegment = 0
            show(original: false)
            setButtons(enabled: rendered != nil)
        }
    }

    /// A language's name in Chinese, from its code.
    private static func name(of language: String?) -> String {
        guard let language else { return "自动识别" }
        return Locale(identifier: "zh-Hans").localizedString(forIdentifier: language) ?? language
    }

    @objc private func shownChanged() { show(original: shown.selectedSegment == 1) }

    private func show(original: Bool) {
        let image = original ? capture.image : (translated ?? capture.image)
        preview.image = NSImage(cgImage: image, size: capture.pointSize)
    }

    // MARK: The result

    private var result: Capture? { translated.map { Capture(image: $0, scale: capture.scale) } }

    @objc private func copyImage() {
        guard let result else { return }
        ImageExporter.copyToPasteboard(result)
        status.stringValue = "已复制图片"
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translations.joined(separator: "\n"), forType: .string)
        status.stringValue = "已复制译文"
    }

    @objc private func saveImage() {
        guard let result else { return }
        ImageExporter.saveAsking(result) { [weak self] outcome in
            if case .success(let url) = outcome {
                self?.status.stringValue = "已保存到“\(url.deletingLastPathComponent().lastPathComponent)”"
            }
        }
    }

    @objc private func keepImage() {
        guard let result else { return }
        onKeep?(result)
        close()
    }

    @objc private func closeClicked() { close() }
}

/// Runs one batch through Apple's translation. SwiftUI's task is what gives a session that may
/// ask to download a language first.
@available(macOS 15, *)
private struct TranslationRunner: View {
    let configuration: TranslationSession.Configuration
    let texts: [String]
    let done: @MainActor (Result<[String], Error>) -> Void

    var body: some View {
        Color.clear.translationTask(configuration) { session in
            let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
            do {
                let responses = try await session.translations(from: requests)
                var translated = texts
                for response in responses {
                    if let id = response.clientIdentifier.flatMap(Int.init), translated.indices.contains(id) { translated[id] = response.targetText }
                }
                done(.success(translated))
            } catch {
                done(.failure(error))
            }
        }
    }
}
