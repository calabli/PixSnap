import AppKit
import PixSnapCore

/// A finished capture floating on screen where it was taken. The bar underneath has quick annotation
/// tools that draw right on the image, plus favorite (when it's in history), pin, edit mode, copy,
/// save and close. With no tool
/// selected, dragging the image moves it; double-click opens edit mode; Esc drops the tool, then closes.
/// To take it to another app (with its annotations), drag the 拖出 handle in the bar, or ⌘-drag the
/// image, which also works while pinned.
///
/// Pinned (图钉): the bar goes away and only the image stays on top of everything, still draggable.
/// Hovering shows a pin in its corner that unpins it; right-click has the other actions.
@MainActor
final class FloatingCaptureWindow: NSPanel {
    var onEdit: ((FloatingCaptureWindow) -> Void)?
    var onClosed: ((FloatingCaptureWindow) -> Void)?

    let capture: Capture
    /// Its entry in history, if it has one; favorites need it.
    let historyID: UUID?
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
    init(capture: Capture, history: EditHistory<AnnotationDocument>?, imageFrame: CGRect, screen: NSScreen, historyID: UUID? = nil) {
        self.capture = capture
        self.historyID = historyID
        bar.showsFavorite = historyID != nil
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
        bar.onFavorite = { [weak self] in self?.toggleFavorite() }
        bar.onDragOut = { [weak self] view, event in self?.dragOut(from: view, event: event) }
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
            // It may have been changed on the clothesline meanwhile.
            if hovering { refreshFavorite() }
        }
        content.addSubview(canvas)
        content.addSubview(bar)
        feedback.frame = layout.image
        content.addSubview(feedback)
        content.addSubview(unpinButton)
        contentView = content
        refreshUndo()
        refreshFavorite()
    }

    private var isFavorite: Bool {
        historyID.map { HistoryLibrary.shared.isFavorite($0) } ?? false
    }

    private func refreshFavorite() {
        bar.setFavorite(isFavorite)
    }

    private func toggleFavorite() {
        guard let historyID else { return }
        let favorite = !isFavorite
        HistoryLibrary.shared.setFavorite(favorite, id: historyID)
        bar.setFavorite(favorite)
        feedback.show(favorite ? "已收藏，不会被自动清理" : "已取消收藏")
    }

    @objc private func favoriteFromMenu() { toggleFavorite() }

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
        var items: [(String, Selector)] = [
            ("取消钉住", #selector(unpin)),
            ("编辑模式", #selector(editFromMenu)),
            ("复制", #selector(copyFromMenu)),
            ("保存", #selector(saveFromMenu)),
        ]
        if historyID != nil { items.insert((isFavorite ? "取消收藏" : "收藏", #selector(favoriteFromMenu)), at: 1) }
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

    // MARK: Dragging out

    /// The ⌘-press waiting to see whether it becomes a drag.
    private var commandPress: NSEvent?

    /// ⌘-drag on the image takes it out instead of moving the window or drawing.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.command) && canvas.frame.contains(event.locationInWindow):
            commandPress = event
            return
        case .leftMouseDragged where commandPress != nil:
            guard let press = commandPress,
                  hypot(event.locationInWindow.x - press.locationInWindow.x, event.locationInWindow.y - press.locationInWindow.y) >= 4,
                  let content = contentView else { return }
            commandPress = nil
            dragOut(from: content, event: press)
            return
        case .leftMouseUp where commandPress != nil:
            commandPress = nil
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// A PNG of the capture as it looks now, annotations and all.
    private func dragOut(from view: NSView, event: NSEvent) {
        guard let result = renderedCapture(), let content = contentView else { return }
        let image = NSImage(cgImage: result.image, size: result.pointSize)
        CaptureDrag.begin(result, image: image, from: view.convert(canvas.frame, from: content), in: view, event: event) { [weak self] taken in
            if taken { self?.feedback.show("已拖出") }
        }
    }

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
        ImageExporter.saveAsking(result) { [weak self] outcome in
            switch outcome {
            case .success(let url):
                self?.feedback.show("已保存到“\(url.deletingLastPathComponent().lastPathComponent)”")
            case .failure(let error):
                self?.feedback.show("保存失败")
                NSLog("PixSnap save failed: \(error)")
            case nil:
                break
            }
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
    var onFavorite: (() -> Void)?
    /// The 拖出 handle was dragged: the handle and the mouse event that started it.
    var onDragOut: ((NSView, NSEvent) -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private let toolControl: NSSegmentedControl
    private var undoButton: NSButton!
    private var favoriteButton: NSButton!

    /// Only captures kept in history can be favorites.
    var showsFavorite = true {
        didSet { favoriteButton.isHidden = !showsFavorite }
    }

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
        favoriteButton = button(nil, symbol: "star", tip: "收藏：不会被自动清理，晾衣架上换成木夹子", action: #selector(favorite))
        let views: [NSView] = [
            toolControl,
            undoButton,
            divider(),
            favoriteButton,
            button("钉住", symbol: "pin", tip: "钉在屏幕上：隐藏操作栏，只留图片，可拖动", action: #selector(pin)),
            button("编辑模式", symbol: "slider.horizontal.3", tip: "更多编辑：颜色、粗细、裁剪等（双击图片）", action: #selector(edit)),
            button("复制", symbol: "doc.on.doc", tip: "复制到剪贴板", action: #selector(copyImage)),
            dragHandle(),
            button("保存", symbol: "square.and.arrow.down", tip: "保存为 PNG，选择保存位置", action: #selector(save)),
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

    func setFavorite(_ favorite: Bool) {
        favoriteButton.image = NSImage(systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: favorite ? "取消收藏" : "收藏")
        favoriteButton.contentTintColor = favorite ? .systemYellow : nil
        favoriteButton.toolTip = favorite ? "取消收藏" : "收藏：不会被自动清理，晾衣架上换成木夹子"
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

    /// Drag it into a chat, mail, Finder or any app that takes images.
    private func dragHandle() -> NSView {
        let handle = DragHandle()
        handle.onDrag = { [weak self, weak handle] event in
            guard let handle else { return }
            self?.onDragOut?(handle, event)
        }
        return handle
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
    @objc private func favorite() { onFavorite?() }
    @objc private func edit() { onEdit?() }
    @objc private func copyImage() { onCopy?() }
    @objc private func save() { onSave?() }
    @objc private func closeCapture() { onClose?() }
}

/// "拖出": looks like the bar's other buttons, but it's dragged rather than clicked.
@MainActor
private final class DragHandle: NSView {
    var onDrag: ((NSEvent) -> Void)?
    private var pressedAt: CGPoint?
    private let label: NSButton

    init() {
        // A borderless button draws the same icon-and-title as its neighbors; it doesn't take clicks.
        label = NSButton(title: "拖出", image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "拖出")!, target: nil, action: nil)
        label.bezelStyle = .recessed
        label.isBordered = false
        label.imagePosition = .imageLeading
        label.imageHugsTitle = true
        label.font = .systemFont(ofSize: 12)
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        wantsLayer = true
        layer?.cornerRadius = 5
        toolTip = "按住拖到微信、邮件、访达等应用（也可以按住 ⌘ 拖图片）"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 else { return }
        pressedAt = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        pressedAt = nil
    }
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
