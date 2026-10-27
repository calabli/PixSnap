import AppKit
import PixSnapCore
import PixSnapRender

/// Edit mode: the full annotation editor, with a toolbar on top and the canvas fitted below.
/// Leaving it ("退出编辑", Esc, ⌘W or the close button) hands the annotations back so the
/// capture floats on screen again.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    var onClose: ((EditorWindowController) -> Void)?
    /// Called with the annotations when edit mode ends.
    var onExit: ((EditHistory<AnnotationDocument>) -> Void)?

    private let capture: Capture
    private let window: ClosableWindow
    private let feedback = FeedbackBadge()
    private let canvas: CanvasView
    private let toolControl: NSSegmentedControl
    private let widthControl: NSSegmentedControl
    private var swatches: [ColorSwatch] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!

    private static let toolbarHeight: CGFloat = 52
    private static let minimumWidth: CGFloat = 760

    init(capture: Capture, history: EditHistory<AnnotationDocument>?, screen: NSScreen?) {
        self.capture = capture
        canvas = CanvasView(capture: capture, history: history)
        toolControl = NSSegmentedControl(
            images: EditorTool.allCases.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
            trackingMode: .selectOne, target: nil, action: nil
        )
        widthControl = NSSegmentedControl(
            labels: StrokeWidth.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
        )

        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxCanvas = CGSize(width: visible.width * 0.85 - 48, height: visible.height * 0.85 - Self.toolbarHeight - 48)
        let fit = min(maxCanvas.width / capture.pointSize.width, maxCanvas.height / capture.pointSize.height, 1)
        let contentSize = CGSize(
            width: max(capture.pointSize.width * fit + 48, Self.minimumWidth),
            height: capture.pointSize.height * fit + Self.toolbarHeight + 48
        )
        window = ClosableWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()

        window.title = "标注截图 — \(capture.image.width) × \(capture.image.height)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Open on the current Space, even over a full-screen app, instead of switching to the desktop.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentMinSize = CGSize(width: Self.minimumWidth, height: 320)
        window.contentView = makeContent()
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))

        canvas.onHistoryChange = { [weak self] in self?.refreshUndoButtons() }
        canvas.onToolShortcut = { [weak self] tool in self?.select(tool) }
        canvas.onEscape = { [weak self] in self?.closeEditor() }
        select(.arrow)
        refreshUndoButtons()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) {
        canvas.endTextEditing()
        onExit?(canvas.history)
        onClose?(self)
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let content = NSView()

        for (index, tool) in EditorTool.allCases.enumerated() {
            toolControl.setToolTip("\(tool.title)（\(tool.key.uppercased())）", forSegment: index)
        }
        toolControl.target = self
        toolControl.action = #selector(toolChanged)

        swatches = AnnotationColor.palette.map { color in
            let swatch = ColorSwatch(color: color)
            swatch.target = self
            swatch.action = #selector(colorChanged(_:))
            return swatch
        }
        swatches.first?.isChosen = true
        let swatchStack = NSStackView(views: swatches)
        swatchStack.spacing = 6

        widthControl.selectedSegment = StrokeWidth.medium.rawValue
        widthControl.target = self
        widthControl.action = #selector(widthChanged)

        undoButton = iconButton("arrow.uturn.backward", tip: "撤销（⌘Z）", action: #selector(undo))
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = .command
        redoButton = iconButton("arrow.uturn.forward", tip: "重做（⇧⌘Z）", action: #selector(redo))
        redoButton.keyEquivalent = "z"
        redoButton.keyEquivalentModifierMask = [.command, .shift]

        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyImage))
        copyButton.toolTip = "复制到剪贴板（⌘C）"
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = .command
        copyButton.bezelStyle = .push
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveImage))
        saveButton.toolTip = "保存为 PNG，选择保存位置（⌘S）"
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        saveButton.bezelStyle = .push
        let exitButton = NSButton(title: "退出编辑", target: self, action: #selector(closeEditor))
        exitButton.toolTip = "退出编辑模式，截图继续浮在屏幕上（Esc 或回车）"
        exitButton.bezelStyle = .push
        exitButton.keyEquivalent = "\r" // Default button: drawn in the accent color.

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let toolbar = NSStackView(views: [toolControl, swatchStack, widthControl, spacer, undoButton, redoButton, copyButton, saveButton, exitButton])
        toolbar.spacing = 14
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        toolbar.setCustomSpacing(4, after: undoButton)
        toolbar.setCustomSpacing(20, after: redoButton)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let stage = CanvasStage(canvas: canvas)
        stage.translatesAutoresizingMaskIntoConstraints = false

        feedback.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(stage)
        content.addSubview(feedback)
        NSLayoutConstraint.activate([
            feedback.topAnchor.constraint(equalTo: stage.topAnchor),
            feedback.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            feedback.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            stage.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        return button
    }

    // MARK: Actions

    private func select(_ tool: EditorTool) {
        toolControl.selectedSegment = tool.rawValue
        canvas.tool = tool
    }

    @objc private func toolChanged() {
        guard let tool = EditorTool(rawValue: toolControl.selectedSegment) else { return }
        canvas.tool = tool
        window.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: ColorSwatch) {
        swatches.forEach { $0.isChosen = $0 === sender }
        canvas.color = sender.color
        canvas.applyStyleToSelection()
        window.makeFirstResponder(canvas)
    }

    @objc private func widthChanged() {
        guard let width = StrokeWidth(rawValue: widthControl.selectedSegment) else { return }
        canvas.strokeWidth = width
        canvas.applyStyleToSelection()
        window.makeFirstResponder(canvas)
    }

    @objc private func closeEditor() {
        window.performClose(nil)
    }

    @objc private func undo() { canvas.undo() }
    @objc private func redo() { canvas.redo() }

    private func refreshUndoButtons() {
        undoButton.isEnabled = canvas.history.canUndo
        redoButton.isEnabled = canvas.history.canRedo
    }

    @objc private func copyImage() {
        guard let result = renderedCapture() else { return }
        ImageExporter.copyToPasteboard(result)
        feedback.show("已复制")
    }

    @objc private func saveImage() {
        guard let result = renderedCapture() else { return }
        ImageExporter.saveAsking(result) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let url):
                feedback.show("已保存到“\(url.deletingLastPathComponent().lastPathComponent)”")
            case .failure(let error):
                NSAlert(error: error).beginSheetModal(for: window)
            case nil:
                break
            }
        }
    }

    private func renderedCapture() -> Capture? {
        canvas.renderedImage().map { Capture(image: $0, scale: capture.scale) }
    }
}

/// Lets ⌘W and Esc close the window even though PixSnap has no main menu.
final class ClosableWindow: NSWindow {
    /// Esc while a toolbar control has focus.
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Centers the canvas in the space below the toolbar and scales it down to fit.
@MainActor
final class CanvasStage: NSView {
    private let canvas: CanvasView
    private let padding: CGFloat = 24

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let canvasSize = canvas.history.current.canvasSize
        let available = bounds.insetBy(dx: padding, dy: padding)
        guard canvasSize.width > 0, canvasSize.height > 0, available.width > 0, available.height > 0 else { return }
        let fit = min(available.width / canvasSize.width, available.height / canvasSize.height, 1)
        let size = CGSize(width: (canvasSize.width * fit).rounded(), height: (canvasSize.height * fit).rounded())
        canvas.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        canvas.needsDisplay = true
    }
}

/// A round color button in the toolbar.
@MainActor
final class ColorSwatch: NSButton {
    let color: AnnotationColor
    var isChosen = false { didSet { needsDisplay = true } }

    init(color: AnnotationColor) {
        self.color = color
        super.init(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        color.nsColor.setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        if isChosen {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}
