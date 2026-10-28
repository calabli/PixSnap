import AppKit
import PixSnapCore
import VisionKit

/// A finished capture floating on screen where it was taken. Clicking the image shows the bar
/// underneath (and clicking again hides it): quick annotation tools that draw right on the image,
/// zoom, favorite (when it's in history), pin, edit mode, copy, 美化, save, delete (from history, for
/// good) and close. ⌘+ / ⌘− / ⌘0 and
/// pinching zoom too. 选取文字 turns on Live Text: the text in the image is highlighted and can be
/// selected like a document's (drag, double-click a word), ⌘C copying the selection — or, with
/// nothing selected, all of it. With no tool
/// selected, dragging the image moves it; double-click opens edit mode; Esc drops the tool, then closes.
/// To take it to another app (with its annotations), drag the 拖出 handle in the bar, or ⌘-drag the
/// image, which also works while pinned.
///
/// Pinned (图钉): the bar goes away and only the image stays on top of everything, still draggable.
/// Hovering shows a pin in its corner that unpins it; right-click has the other actions.
@MainActor
final class FloatingCaptureWindow: NSPanel {
    var onEdit: ((FloatingCaptureWindow) -> Void)?
    /// 美化 with the image as it looks now.
    var onBeautify: ((FloatingCaptureWindow, Capture) -> Void)?
    var onTranslate: ((FloatingCaptureWindow, Capture) -> Void)?
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
    /// Live Text over the image while selecting text.
    private let textOverlay = ImageAnalysisOverlayView()
    private var selectsText = false
    private static let analyzer = ImageAnalyzer()
    /// The bar shows only after the image is clicked.
    private var barShown = false

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
        bar.showsDelete = historyID != nil
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
        canvas.onIdleClick = { [weak self] in
            guard let self, !isPinned else { return }
            setBarShown(!barShown)
        }
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
        bar.onZoom = { [weak self] step in self?.zoom(by: step) }
        bar.onDragOut = { [weak self] view, event in self?.dragOut(from: view, event: event) }
        bar.onEdit = { [weak self] in self?.edit() }
        bar.onCopy = { [weak self] in self?.copyImage() }
        bar.onBigBang = { [weak self] in self?.bigBang() }
        bar.onBeautify = { [weak self] in self?.beautify() }
        bar.onTranslate = { [weak self] in self?.translate() }
        bar.onCopyText = { [weak self] in
            guard let self else { return }
            setSelectsText(!selectsText)
        }
        bar.onSave = { [weak self] in self?.saveImage() }
        bar.onClose = { [weak self] in self?.close() }
        bar.onDelete = { [weak self] in self?.deleteForGood() }

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
        textOverlay.isHidden = true
        textOverlay.delegate = self
        // The bar's button already turns it on and off.
        textOverlay.isSupplementaryInterfaceHidden = true
        content.addSubview(textOverlay)
        content.addSubview(bar)
        feedback.frame = layout.image
        content.addSubview(feedback)
        content.addSubview(unpinButton)
        contentView = content
        refreshUndo()
        refreshFavorite()
        bar.isHidden = true
        bar.setZoom(zoom)
    }

    // MARK: The bar

    /// Shows the bar without a click (`--pin … --bar`).
    func showBar() { setBarShown(true) }

    /// Turns on text selection without a click (`--pin … --select-text`).
    func selectText() { setSelectsText(true) }

    @objc private func selectTextFromMenu() { setSelectsText(!selectsText) }

    /// Fades the bar in (rising a little) or out.
    private func setBarShown(_ shown: Bool) {
        guard shown != barShown else { return }
        barShown = shown
        if !shown, canvas.tool != .select { setTool(.select) }
        if shown {
            bar.alphaValue = 0
            bar.isHidden = false
            bar.layer?.add(Motion.spring("transform.translation.y", from: 6, to: 0, duration: 0.3), forKey: "rise")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shown ? 0.18 : 0.12
            bar.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.barShown else { return }
                self.bar.isHidden = true
                self.invalidateShadow()
            }
        })
        invalidateShadow()
    }

    // MARK: Zoom

    /// The image's size on screen compared with its real size: 1 is 100%.
    private var zoom: CGFloat {
        imageRect.width / max(canvas.history.current.outputRect.width, 1)
    }

    private static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    /// `step` -1 zooms out a step, 1 in a step, 0 back to 100%.
    private func zoom(by step: Int) {
        let current = zoom
        let next: CGFloat
        switch step {
        case ..<0: next = Self.zoomSteps.last { $0 < current - 0.005 } ?? Self.zoomSteps[0]
        case 1...: next = Self.zoomSteps.first { $0 > current + 0.005 } ?? Self.zoomSteps.last!
        default: next = 1
        }
        setZoom(next)
    }

    /// Resizes the image to `zoom` of its real size, its top-left corner staying put.
    private func setZoom(_ newZoom: CGFloat) {
        canvas.endTextEditing()
        let real = canvas.history.current.outputRect.size
        let clamped = min(max(newZoom, Self.zoomSteps.first!), Self.zoomSteps.last!)
        let size = CGSize(width: (real.width * clamped).rounded(), height: (real.height * clamped).rounded())
        guard size.width >= 16, size.height >= 16 else { return }
        let current = imageFrame
        lay(out: CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height))
        bar.setZoom(zoom)
        feedback.show("\(Int((zoom * 100).rounded()))%")
    }

    /// Pinching on a trackpad zooms smoothly; ⌘+ / ⌘− / ⌘0 step.
    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c" where selectsText: copySelectedText()
        case "=", "+": zoom(by: 1)
        case "-": zoom(by: -1)
        case "0": zoom(by: 0)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
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

    /// Removes the capture from history, files and all (not into the basket), and fades away.
    private func deleteForGood() {
        guard let historyID else { return }
        HistoryLibrary.shared.deletePermanently([historyID])
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    /// From the pinned right-click menu: asks first, since there's no going back.
    @objc private func deleteFromMenu() {
        let alert = NSAlert()
        alert.messageText = "永久删除这张截图？"
        alert.informativeText = "会从截图历史里删除，不进洗衣篮，无法恢复。已经用“保存”存到别处的文件不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { deleteForGood() }
    }

    /// Pinning drops the bar and shrinks the window to the image; unpinning lays the bar out again.
    /// The image stays exactly where it is on screen either way.
    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        canvas.endTextEditing()
        if pinned { setTool(.select) }
        isPinned = pinned
        // Unpinning brings the bar back, since that's what the pin button promises.
        barShown = !pinned
        bar.alphaValue = 1
        bar.isHidden = pinned
        unpinButton.isHidden = true
        canvas.menu = pinned ? pinnedMenu() : nil
        lay(out: imageFrame)
    }

    /// Puts the image at `imageOnScreen` (global coordinates), with the bar under or over it, or,
    /// pinned, the window shrunk to just the image.
    private func lay(out imageOnScreen: CGRect) {
        if isPinned {
            setFrame(imageOnScreen, display: false)
            canvas.frame = CGRect(origin: .zero, size: imageOnScreen.size)
        } else {
            let visible = (screen ?? NSScreen.main)?.visibleFrame ?? imageOnScreen
            let layout = Self.layout(imageFrame: imageOnScreen, barSize: bar.fittingSize, visible: visible)
            setFrame(layout.window, display: false)
            canvas.frame = layout.image
            bar.frame = layout.bar
        }
        imageRect = canvas.frame
        feedback.frame = canvas.frame
        textOverlay.frame = canvas.frame
        let side: CGFloat = 24
        unpinButton.frame = CGRect(x: canvas.frame.maxX - side - 6, y: canvas.frame.maxY - side - 6, width: side, height: side)
        display()
        invalidateShadow()
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
            ("选取文字", #selector(selectTextFromMenu)),
            ("大爆炸", #selector(bigBangFromMenu)),
            ("美化", #selector(beautifyFromMenu)),
            ("翻译", #selector(translateFromMenu)),
            ("保存", #selector(saveFromMenu)),
        ]
        if historyID != nil { items.insert((isFavorite ? "取消收藏" : "收藏", #selector(favoriteFromMenu)), at: 1) }
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if historyID != nil {
            let delete = NSMenuItem(title: "永久删除…", action: #selector(deleteFromMenu), keyEquivalent: "")
            delete.target = self
            menu.addItem(delete)
        }
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
        if selectsText { return setSelectsText(false) }
        close()
    }

    override func close() {
        canvas.endTextEditing()
        super.close()
        onClosed?(self)
    }

    private func setTool(_ tool: EditorTool) {
        // Drawing and selecting text don't mix.
        if tool != .select { setSelectsText(false) }
        canvas.tool = tool
        bar.show(tool)
        // A tool picked by its key shows the bar, so it's clear which one is on.
        if tool != .select, !isPinned { setBarShown(true) }
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

    // MARK: Selecting text

    /// 大爆炸: the text bursts out into words to pick.
    private func bigBang() {
        guard let result = renderedCapture(), let screen = screen ?? NSScreen.main else { return }
        setSelectsText(false)
        BigBangWindow.show(image: result.image, imageFrame: imageFrame, on: screen)
    }

    @objc private func bigBangFromMenu() { bigBang() }

    /// 美化: finished in the style that suits what it shows, in a panel to pick another.
    private func beautify() {
        guard let result = renderedCapture() else { return }
        setSelectsText(false)
        onBeautify?(self, result)
    }

    @objc private func beautifyFromMenu() { beautify() }

    /// 截图翻译: the text translated and written over the original, in a panel.
    private func translate() {
        guard let result = renderedCapture() else { return }
        setSelectsText(false)
        onTranslate?(self, result)
    }

    @objc private func translateFromMenu() { translate() }

    /// Opens 截图翻译 without a click (`--pin … --translate`).
    func translateNow() { translate() }

    /// Opens 美化 without a click (`--pin … --beautify`).
    func beautifyNow() { beautify() }

    /// Bursts without a click (`--pin … --bigbang`).
    func bigBangNow() { bigBang() }

    /// Live Text on (the image as it looks now is read for text, which is then highlighted and
    /// selectable) or off.
    private func setSelectsText(_ on: Bool) {
        guard on != selectsText else { return }
        selectsText = on
        bar.setSelectsText(on)
        guard on else {
            textOverlay.isHidden = true
            textOverlay.preferredInteractionTypes = []
            textOverlay.analysis = nil
            return
        }
        if canvas.tool != .select { setTool(.select) }
        guard ImageAnalyzer.isSupported, let result = renderedCapture() else {
            selectsText = false
            bar.setSelectsText(false)
            return feedback.show("这台 Mac 不支持识别文字")
        }
        feedback.show("正在识别文字…")
        Task {
            let analysis = try? await Self.analyzer.analyze(result.image, orientation: .up, configuration: ImageAnalyzer.Configuration([.text]))
            guard selectsText else { return }
            guard let analysis, analysis.hasResults(for: .text) else {
                setSelectsText(false)
                return feedback.show("没有识别到文字")
            }
            textOverlay.frame = canvas.frame
            textOverlay.analysis = analysis
            textOverlay.preferredInteractionTypes = .textSelection
            textOverlay.selectableItemsHighlighted = true
            textOverlay.isHidden = false
            makeKey()
            feedback.show("拖动选择文字，⌘C 复制")
        }
    }

    /// The selected text, or all of it when nothing is selected, onto the clipboard.
    private func copySelectedText() {
        let selected = textOverlay.selectedText
        let text = selected.isEmpty ? (textOverlay.analysis?.transcript ?? "") : selected
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback.show(selected.isEmpty ? "已复制全部文字" : "已复制")
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
    static let quickTools: [EditorTool] = [.rectangle, .arrow, .pen, .highlight, .text, .mosaic, .counter]

    /// `.select` means no tool: dragging moves the image.
    var onTool: ((EditorTool) -> Void)?
    var onUndo: (() -> Void)?
    var onPin: (() -> Void)?
    var onFavorite: (() -> Void)?
    /// -1 zoom out, 1 zoom in, 0 back to 100%.
    var onZoom: ((Int) -> Void)?
    /// The 拖出 handle was dragged: the handle and the mouse event that started it.
    var onDragOut: ((NSView, NSEvent) -> Void)?
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyText: (() -> Void)?
    var onBigBang: (() -> Void)?
    var onBeautify: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    /// The delete button was clicked twice: delete for good.
    var onDelete: (() -> Void)?

    private let toolControl: NSSegmentedControl
    private var undoButton: NSButton!
    private var favoriteButton: NSButton!
    private var deleteButton: NSButton!
    private var confirmingDelete = false

    /// Only captures kept in history can be deleted from it.
    var showsDelete = true {
        didSet { deleteButton.isHidden = !showsDelete }
    }
    private var zoomLabel: NSButton!

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
        zoomLabel = NSButton(title: "100%", target: self, action: #selector(zoomReset))
        zoomLabel.bezelStyle = .recessed
        zoomLabel.showsBorderOnlyWhileMouseInside = true
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.toolTip = "恢复原始大小（⌘0）"
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let views: [NSView] = [
            toolControl,
            undoButton,
            divider(),
            button(nil, symbol: "minus.magnifyingglass", tip: "缩小（⌘−，也可以双指捏合）", action: #selector(zoomOut)),
            zoomLabel,
            button(nil, symbol: "plus.magnifyingglass", tip: "放大（⌘+）", action: #selector(zoomIn)),
            divider(),
            favoriteButton,
            button("钉住", symbol: "pin", tip: "钉在屏幕上：隐藏操作栏，只留图片，可拖动", action: #selector(pin)),
            button("编辑模式", symbol: "slider.horizontal.3", tip: "更多编辑：颜色、粗细、裁剪等（双击图片）", action: #selector(edit)),
            button("复制", symbol: "doc.on.doc", tip: "复制到剪贴板", action: #selector(copyImage)),
            selectTextButtonView(),
            button(nil, symbol: "sparkles", tip: "大爆炸：把图里的文字炸成一个个词，点选后复制或搜索", action: #selector(bigBang)),
            button(nil, symbol: "translate", tip: "截图翻译：把图里的文字翻译后写回原来的位置，在本机完成", action: #selector(translate)),
            button("美化", symbol: "wand.and.stars", tip: "智能美化：识别截图内容（代码、文档、照片、界面…），配上合适的背景、圆角和阴影", action: #selector(beautify)),
            dragHandle(),
            button("保存", symbol: "square.and.arrow.down", tip: "保存为 PNG，选择保存位置", action: #selector(save)),
            deleteButtonView(),
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

    func setZoom(_ zoom: CGFloat) {
        zoomLabel.title = "\(Int((zoom * 100).rounded()))%"
    }

    func setFavorite(_ favorite: Bool) {
        favoriteButton.image = NSImage(systemSymbolName: favorite ? "star.fill" : "star", accessibilityDescription: favorite ? "取消收藏" : "收藏")
        favoriteButton.contentTintColor = favorite ? .systemYellow : nil
        favoriteButton.toolTip = favorite ? "取消收藏" : "收藏：不会被自动清理，晾衣架上换成木夹子"
    }

    /// An icon; its name and what it does show when the pointer rests on it.
    private func button(_ title: String?, symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? tip)!
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.toolTip = title.map { tip.contains($0) ? tip : "\($0)：\(tip)" } ?? tip
        return button
    }

    private var selectTextButton: NSButton!
    private static var deleteTip: String?

    private func selectTextButtonView() -> NSButton {
        selectTextButton = button(nil, symbol: "text.viewfinder", tip: "选取文字：像文档一样选择图里的文字并复制（再点一下退出）", action: #selector(copyText))
        return selectTextButton
    }

    func setSelectsText(_ on: Bool) {
        selectTextButton.contentTintColor = on ? .controlAccentColor : nil
        selectTextButton.state = on ? .on : .off
    }

    private func deleteButtonView() -> NSButton {
        deleteButton = button("删除", symbol: "trash", tip: "从截图历史里永久删除，不进洗衣篮（点两下确认）", action: #selector(deleteClicked))
        Self.deleteTip = deleteButton.toolTip
        return deleteButton
    }

    /// The first click asks; a second click within a few seconds deletes.
    @objc private func deleteClicked() {
        if confirmingDelete {
            onDelete?()
            return
        }
        confirmingDelete = true
        deleteButton.contentTintColor = .systemRed
        deleteButton.toolTip = "再点一下永久删除"
        deleteButton.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "确认删除")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, confirmingDelete else { return }
            confirmingDelete = false
            deleteButton.contentTintColor = nil
            deleteButton.toolTip = Self.deleteTip
            deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
        }
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
    @objc private func zoomIn() { onZoom?(1) }
    @objc private func zoomOut() { onZoom?(-1) }
    @objc private func zoomReset() { onZoom?(0) }
    @objc private func edit() { onEdit?() }
    @objc private func copyImage() { onCopy?() }
    @objc private func copyText() { onCopyText?() }
    @objc private func bigBang() { onBigBang?() }
    @objc private func beautify() { onBeautify?() }
    @objc private func translate() { onTranslate?() }
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
        // A borderless button draws the same icon as its neighbors; it doesn't take clicks.
        label = NSButton(image: NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "拖出")!, target: nil, action: nil)
        label.bezelStyle = .recessed
        label.isBordered = false
        label.imagePosition = .imageOnly
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
        toolTip = "拖出：按住拖到微信、邮件、访达等应用（也可以按住 ⌘ 拖图片）"
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

extension FloatingCaptureWindow: ImageAnalysisOverlayViewDelegate {
    /// The image fills the overlay exactly.
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}
