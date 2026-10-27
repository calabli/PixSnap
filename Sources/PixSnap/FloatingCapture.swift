import AppKit
import PixSnapCore

/// A finished capture floating on screen where it was taken. The bar underneath has quick annotation
/// tools that draw right on the image, plus pin, edit mode, copy, save and close. With no tool
/// selected, dragging the image moves it; double-click opens edit mode; Esc drops the tool, then closes.
///
/// Pinned (图钉): the bar goes away and only the image stays on top of everything, still draggable.
/// Hovering shows a pin in its corner that unpins it; right-click has the other actions.
@MainActor
final class FloatingCaptureWindow: NSPanel {
    var onEdit: ((FloatingCaptureWindow) -> Void)?
    var onClosed: ((FloatingCaptureWindow) -> Void)?

    let capture: Capture
    private let canvas: CanvasView
    private let bar = ActionBar()
    private let feedback = FeedbackBadge()
    private let unpinButton = NSButton()
    private var imageRect: CGRect
    private(set) var isPinned = false

    /// Annotations so far, handed to edit mode and back.
    var history: EditHistory<AnnotationDocument> { canvas.history }

    /// The image's current on-screen rect in global coordinates (it moves when the window is dragged).
    var imageFrame: CGRect { imageRect.offsetBy(dx: frame.minX, dy: frame.minY) }

    private static let gap: CGFloat = 6

    /// `imageFrame` is where the (cropped) result should appear, in global AppKit coordinates.
    init(capture: Capture, history: EditHistory<AnnotationDocument>?, imageFrame: CGRect, screen: NSScreen) {
        self.capture = capture
        canvas = CanvasView(capture: capture, history: history)
        let layout = Self.layout(imageFrame: imageFrame, barSize: bar.fittingSize, visible: screen.visibleFrame)
        imageRect = layout.image

        super.init(contentRect: layout.window, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        canvas.frame = layout.image
        canvas.showsOnlyOutput = true
        canvas.dragsWindowWhenIdle = true
        canvas.tool = .select
        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        canvas.onDoubleClick = { [weak self] in self?.edit() }
        canvas.onHistoryChange = { [weak self] in self?.refreshUndo() }
        canvas.onToolShortcut = { [weak self] tool in
            if ActionBar.quickTools.contains(tool) { self?.setTool(tool) }
        }
        canvas.onEscape = { [weak self] in
            guard let self else { return }
            if canvas.tool == .select { close() } else { setTool(.select) }
        }

        bar.frame = layout.bar
        bar.onTool = { [weak self] tool in self?.setTool(tool) }
        bar.onUndo = { [weak self] in self?.canvas.undo() }
        bar.onPin = { [weak self] in self?.setPinned(true) }
        bar.onEdit = { [weak self] in self?.edit() }
        bar.onCopy = { [weak self] in self?.copyImage() }
        bar.onSave = { [weak self] in self?.saveImage() }
        bar.onClose = { [weak self] in self?.close() }

        unpinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "取消钉住")
        unpinButton.toolTip = "取消钉住，显示操作栏"
        unpinButton.bezelStyle = .circular
        unpinButton.target = self
        unpinButton.action = #selector(unpin)
        unpinButton.isHidden = true

        let content = HoverView(frame: CGRect(origin: .zero, size: layout.window.size))
        content.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            unpinButton.isHidden = !(isPinned && hovering)
        }
        content.addSubview(canvas)
        content.addSubview(bar)
        feedback.frame = layout.image
        content.addSubview(feedback)
        content.addSubview(unpinButton)
        contentView = content
        refreshUndo()
    }

    /// Pinning drops the bar and shrinks the window to the image; unpinning lays the bar out again.
    /// The image stays exactly where it is on screen either way.
    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        canvas.endTextEditing()
        if pinned { setTool(.select) }
        let imageOnScreen = imageFrame
        isPinned = pinned

        if pinned {
            setFrame(imageOnScreen, display: false)
            canvas.frame = CGRect(origin: .zero, size: imageOnScreen.size)
        } else {
            let visible = (screen ?? NSScreen.main)?.visibleFrame ?? imageOnScreen
            let layout = Self.layout(imageFrame: imageOnScreen, barSize: bar.fittingSize, visible: visible)
            setFrame(layout.window, display: false)
            canvas.frame = layout.image
            bar.frame = layout.bar
        }
        bar.isHidden = pinned
        imageRect = canvas.frame
        feedback.frame = canvas.frame
        unpinButton.isHidden = true
        let side: CGFloat = 24
        unpinButton.frame = CGRect(x: canvas.frame.maxX - side - 6, y: canvas.frame.maxY - side - 6, width: side, height: side)
        canvas.menu = pinned ? pinnedMenu() : nil
        display()
    }

    @objc private func unpin() {
        setPinned(false)
    }

    /// Right-click menu while pinned, since the bar is hidden.
    private func pinnedMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("取消钉住", #selector(unpin)),
            ("编辑模式", #selector(editFromMenu)),
            ("复制", #selector(copyFromMenu)),
            ("保存", #selector(saveFromMenu)),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "关闭", action: #selector(closeFromMenu), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func editFromMenu() { edit() }
    @objc private func copyFromMenu() { copyImage() }
    @objc private func saveFromMenu() { saveImage() }
    @objc private func closeFromMenu() { close() }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func close() {
        canvas.endTextEditing()
        super.close()
        onClosed?(self)
    }

    private func setTool(_ tool: EditorTool) {
        canvas.tool = tool
        bar.show(tool)
        makeKey()
        makeFirstResponder(canvas)
    }

    private func refreshUndo() {
        bar.setUndoEnabled(canvas.history.canUndo)
    }

    private func edit() {
        canvas.endTextEditing()
        onEdit?(self)
    }

    private func renderedCapture() -> Capture? {
        canvas.renderedImage().map { Capture(image: $0, scale: capture.scale) }
    }

    private func copyImage() {
        guard let result = renderedCapture() else { return }
        ImageExporter.copyToPasteboard(result)
        feedback.show("已复制")
    }

    private func saveImage() {
        guard let result = renderedCapture() else { return }
        do {
            _ = try ImageExporter.save(result)
            feedback.show("已保存到“图片/PixSnap”")
        } catch {
            feedback.show("保存失败")
            NSLog("PixSnap save failed: \(error)")
        }
    }

    /// The bar goes under the image, right-aligned. When the image reaches the bottom of the screen
    /// it goes above instead, and when there's no room either way it sits inside the image's bottom edge.
    private static func layout(imageFrame: CGRect, barSize: CGSize, visible: CGRect)
        -> (window: CGRect, image: CGRect, bar: CGRect) {
        let width = max(imageFrame.width, barSize.width)
        let imageX = width - imageFrame.width
        let barX = width - barSize.width
        let outsideHeight = barSize.height + gap

        if imageFrame.minY - outsideHeight >= visible.minY {
            let window = CGRect(x: imageFrame.maxX - width, y: imageFrame.minY - outsideHeight,
                                width: width, height: imageFrame.height + outsideHeight)
            return (window,
                    CGRect(x: imageX, y: outsideHeight, width: imageFrame.width, height: imageFrame.height),
                    CGRect(x: barX, y: 0, width: barSize.width, height: barSize.height))
        }
        if imageFrame.maxY + outsideHeight <= visible.maxY {
            let window = CGRect(x: imageFrame.maxX - width, y: imageFrame.minY,
                                width: width, height: imageFrame.height + outsideHeight)
            return (window,
                    CGRect(x: imageX, y: 0, width: imageFrame.width, height: imageFrame.height),
                    CGRect(x: barX, y: imageFrame.height + gap, width: barSize.width, height: barSize.height))
        }
        let window = CGRect(x: imageFrame.maxX - width, y: imageFrame.minY, width: width, height: imageFrame.height)
        return (window,
                CGRect(x: imageX, y: 0, width: imageFrame.width, height: imageFrame.height),
                CGRect(x: max(0, barX - 8), y: 8, width: barSize.width, height: barSize.height))
    }
}

/// The row under a floating capture: quick tools and undo, then edit mode, copy, save and close.
@MainActor
private final class ActionBar: NSVisualEffectView {
    static let quickTools: [EditorTool] = [.rectangle, .arrow, .text, .mosaic, .counter]

    /// `.select` means no tool: dragging moves the image.
    var onTool: ((EditorTool) -> Void)?
    var onUndo: (() -> Void)?
    var onPin: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private let toolControl: NSSegmentedControl
    private var undoButton: NSButton!

    init() {
        toolControl = NSSegmentedControl(
            images: Self.quickTools.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! },
            trackingMode: .selectAny, target: nil, action: nil
        )
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        toolControl.target = self
        toolControl.action = #selector(toolClicked)
        for (index, tool) in Self.quickTools.enumerated() {
            toolControl.setToolTip("\(tool.title)（\(tool.key.uppercased())）", forSegment: index)
            toolControl.setWidth(28, forSegment: index)
        }

        undoButton = button(nil, symbol: "arrow.uturn.backward", tip: "撤销", action: #selector(undo))
        let views: [NSView] = [
            toolControl,
            undoButton,
            divider(),
            button("钉住", symbol: "pin", tip: "钉在屏幕上：隐藏操作栏，只留图片，可拖动", action: #selector(pin)),
            button("编辑模式", symbol: "slider.horizontal.3", tip: "更多编辑：颜色、粗细、裁剪等（双击图片）", action: #selector(edit)),
            button("复制", symbol: "doc.on.doc", tip: "复制到剪贴板", action: #selector(copyImage)),
            button("保存", symbol: "square.and.arrow.down", tip: "保存到“图片/PixSnap”", action: #selector(save)),
            button("关闭", symbol: "xmark", tip: "关闭（Esc）", action: #selector(closeCapture)),
        ]
        let stack = NSStackView(views: views)
        stack.spacing = 4
        stack.setCustomSpacing(8, after: toolControl)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Highlights `tool` (or nothing for `.select`).
    func show(_ tool: EditorTool) {
        for (index, quickTool) in Self.quickTools.enumerated() {
            toolControl.setSelected(quickTool == tool, forSegment: index)
        }
    }

    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
    }

    private func button(_ title: String?, symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? tip)!
        let button = title.map { NSButton(title: $0, image: image, target: self, action: action) }
            ?? NSButton(image: image, target: self, action: action)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 12)
        button.toolTip = tip
        return button
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }

    /// Selecting a tool turns the others off; clicking the active tool again turns it off.
    @objc private func toolClicked() {
        let index = toolControl.selectedSegment
        guard Self.quickTools.indices.contains(index) else { return }
        let tool = toolControl.isSelected(forSegment: index) ? Self.quickTools[index] : .select
        show(tool)
        onTool?(tool)
    }

    @objc private func undo() { onUndo?() }
    @objc private func pin() { onPin?() }
    @objc private func edit() { onEdit?() }
    @objc private func copyImage() { onCopy?() }
    @objc private func save() { onSave?() }
    @objc private func closeCapture() { onClose?() }
}

/// Reports when the mouse enters or leaves the window.
@MainActor
private final class HoverView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// A short message ("已复制") that fades in over the image and out again.
@MainActor
final class FeedbackBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private let pill = NSView()
    private var hideTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        alphaValue = 0
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        pill.layer?.cornerRadius = 8
        pill.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lets clicks reach the view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String) {
        label.stringValue = text
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.animator().alphaValue = 0 }, completionHandler: nil)
        }
    }
}
