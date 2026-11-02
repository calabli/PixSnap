import AppKit
import PixSnapCore

/// 时光胶片: all of history on a strip of film across the bottom of the screen, oldest at the left
/// and newest at the right (where it opens), each day starting with its date printed on the film
/// edge. Scroll sideways (or with the wheel) to go back in time; type to keep only captures with
/// those words. Click a frame to float it, drag it into another app, space to preview it (← → step,
/// Return floats), right-click for more. Esc, a click outside or the shortcut again puts it away.
@MainActor
final class FilmStripWindow: NSPanel, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSSearchFieldDelegate {
    var onPick: ((HistoryEntry) -> Void)?

    private static var shown: FilmStripWindow?

    /// Opens the strip on the screen under the cursor, or puts it away if it's out.
    static func toggle(onPick: @escaping (HistoryEntry) -> Void) {
        if let shown {
            shown.dismiss()
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { ScreenGeometry.screen($0.frame, containsMouse: mouse) }) ?? NSScreen.main else { return }
        let window = FilmStripWindow(screen: screen)
        window.onPick = onPick
        shown = window
        window.present()
    }

    static let frameHeight: CGFloat = 150
    /// The film above and below the pictures, with the sprocket holes (and, below, the edge print).
    static let edge: CGFloat = 30
    static let stripHeight = frameHeight + edge * 2
    private static let headerHeight: CGFloat = 46
    private static let height = stripHeight + headerHeight + 18

    private var items: [FilmStrip.Item] = []
    private var query = ""
    private let collection = NSCollectionView()
    private let scroll = SidewaysScrollView()
    private let search = NSSearchField()
    private let summary = NSTextField(labelWithString: "")
    private var outsideClicks: Any?
    private var searchWork: DispatchWorkItem?
    private let thumbnails = NSCache<NSUUID, NSImage>()
    private lazy var preview: PhotoPreviewWindow = {
        let preview = PhotoPreviewWindow(screenFrame: screenFrame, level: NSWindow.Level(rawValue: level.rawValue + 1))
        preview.onPick = { [weak self] entry in self?.pick(entry) }
        preview.onClose = { [weak self] in self?.preview.dismiss() }
        return preview
    }()
    private let screenFrame: CGRect
    /// The frame under the mouse, for space and the right-click menu.
    fileprivate var hovered: HistoryEntry?

    private init(screen: NSScreen) {
        screenFrame = screen.frame
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX + 16, y: visible.minY + 16, width: visible.width - 32, height: Self.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        content.material = .hudWindow
        content.appearance = NSAppearance(named: .darkAqua)
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "时光胶片")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: 12)
        search.placeholderString = "搜索截图里的文字或应用"
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")!, target: self,
                             action: #selector(closeClicked))
        close.isBordered = false
        close.toolTip = "收起（Esc）"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, summary, spacer, search, close])
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
        ])

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = false
        collection.backgroundColors = [NSColor(white: 0.07, alpha: 1)]
        collection.register(FilmFrameItem.self, forItemWithIdentifier: FilmFrameItem.identifier)
        collection.register(FilmDayItem.self, forItemWithIdentifier: FilmDayItem.identifier)
        scroll.documentView = collection
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.frame = CGRect(x: 0, y: 6, width: frame.width, height: Self.stripHeight + 6)
        scroll.autoresizingMask = [.width]
        content.addSubview(scroll)
        contentView = content
        reload(scrollingToEnd: true)
    }

    override var canBecomeKey: Bool { true }

    private func present() {
        let final = frame
        setFrame(final.offsetBy(dx: 0, dy: -40), display: false)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(collection)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.2, 0.4, 1)
            animator().setFrame(final, display: true)
            animator().alphaValue = 1
        }
        // A click anywhere else puts it away (and goes through to what's there).
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.preview.entry == nil else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        guard Self.shown === self else { return }
        Self.shown = nil
        outsideClicks.map(NSEvent.removeMonitor)
        outsideClicks = nil
        preview.dismiss(animated: false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: 0, dy: -30), display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }

    @objc private func closeClicked() { dismiss() }

    // MARK: Contents

    private func reload(scrollingToEnd: Bool) {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let entries = searching ? HistoryLibrary.shared.search(query, limit: 3000) : HistoryLibrary.shared.recent(limit: 3000)
        items = FilmStrip.items(entries, now: Date())
        let days = items.filter { if case .day = $0 { true } else { false } }.count
        if entries.isEmpty {
            summary.stringValue = searching ? "没有找到包含“\(query)”的截图" : "还没有截图"
        } else {
            summary.stringValue = searching ? "找到 \(entries.count) 张 · \(days) 天" : "共 \(entries.count) 张 · \(days) 天"
        }
        collection.reloadData()
        guard scrollingToEnd, !items.isEmpty else { return }
        collection.layoutSubtreeIfNeeded()
        collection.scrollToItems(at: [IndexPath(item: items.count - 1, section: 0)], scrollPosition: .right)
    }

    func controlTextDidChange(_ notification: Notification) {
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, search.stringValue != query else { return }
            query = search.stringValue
            reload(scrollingToEnd: true)
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        switch items[indexPath.item] {
        case let .day(title, count):
            let item = collectionView.makeItem(withIdentifier: FilmDayItem.identifier, for: indexPath)
            (item.view as? FilmDayView)?.show(title: title, count: count)
            return item
        case let .frame(entry):
            let item = collectionView.makeItem(withIdentifier: FilmFrameItem.identifier, for: indexPath)
            if let view = item.view as? FilmFrameView {
                view.strip = self
                view.show(entry, picture: thumbnail(for: entry))
            }
            return item
        }
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        switch items[indexPath.item] {
        case .day: CGSize(width: FilmDayView.width, height: Self.stripHeight)
        case let .frame(entry):
            CGSize(width: FilmStrip.pictureWidth(pixelWidth: entry.pixelWidth, pixelHeight: entry.pixelHeight, height: Self.frameHeight)
                + FilmFrameView.gap * 2, height: Self.stripHeight)
        }
    }

    private func thumbnail(for entry: HistoryEntry) -> NSImage? {
        let key = entry.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = HistoryLibrary.shared.thumbnail(for: entry) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    // MARK: Using a frame

    fileprivate func pick(_ entry: HistoryEntry) {
        dismiss()
        onPick?(entry)
    }

    fileprivate func dragOut(_ entry: HistoryEntry, from view: NSView, frame: CGRect, image: NSImage, event: NSEvent) {
        if entry.isRecording {
            guard let video = HistoryLibrary.shared.videoURL(for: entry) else { return }
            CaptureDrag.begin(file: video, image: image, from: frame, in: view, event: event, ended: { _ in })
        } else {
            guard let capture = HistoryLibrary.shared.loadCapture(entry) else { return }
            CaptureDrag.begin(capture, image: image, from: frame, in: view, event: event, ended: { _ in })
        }
    }

    fileprivate func menu(for entry: HistoryEntry) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            let item = MenuAction(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("浮动到屏幕上", "macwindow.on.rectangle") { [weak self] in self?.pick(entry) }
        add("预览", "eye") { [weak self] in self?.showPreview(of: entry) }
        if !entry.isRecording {
            add("复制图片", "doc.on.doc") {
                if let capture = HistoryLibrary.shared.loadCapture(entry) { ImageExporter.copyToPasteboard(capture) }
            }
        }
        return menu
    }

    private func showPreview(of entry: HistoryEntry, direction: Int = 0) {
        let rect = frameView(for: entry).flatMap { view in view.window?.convertToScreen(view.convert(view.pictureFrame, to: nil)) }
        preview.show(entry, from: rect, direction: direction)
    }

    private func frameView(for entry: HistoryEntry) -> FilmFrameView? {
        guard let index = items.firstIndex(of: .frame(entry)) else { return nil }
        return collection.item(at: IndexPath(item: index, section: 0))?.view as? FilmFrameView
    }

    /// The previewed capture's neighbor on the strip, scrolled into view.
    private func step(by offset: Int) {
        guard let current = preview.entry else { return }
        let frames = items.compactMap { if case let .frame(entry) = $0 { entry } else { nil } }
        guard let index = frames.firstIndex(of: current), frames.indices.contains(index + offset) else { return }
        let next = frames[index + offset]
        if let position = items.firstIndex(of: .frame(next)) {
            collection.scrollToItems(at: [IndexPath(item: position, section: 0)], scrollPosition: .centeredHorizontally)
        }
        showPreview(of: next, direction: offset)
    }

    // MARK: Keyboard

    override func cancelOperation(_ sender: Any?) {
        if preview.entry != nil { preview.dismiss() } else { dismiss() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // space
            if preview.entry != nil {
                preview.dismiss()
            } else if let entry = hovered ?? items.last.flatMap({ if case let .frame(entry) = $0 { entry } else { nil } }) {
                showPreview(of: entry)
            }
        case 123, 124: // ← →
            if preview.entry != nil {
                step(by: event.keyCode == 123 ? -1 : 1)
            } else {
                scroll.scrollBy(event.keyCode == 123 ? -scroll.bounds.width * 0.6 : scroll.bounds.width * 0.6)
            }
        case 36, 76: // Return
            if let entry = preview.entry { pick(entry) }
        default:
            // Typing goes to the search box.
            if let characters = event.characters, !characters.isEmpty, event.modifierFlags.intersection([.command, .control]).isEmpty,
               characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                makeFirstResponder(search)
                search.currentEditor()?.insertText(characters)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// A menu item that runs a closure.
private final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func runAction() { run() }
}

/// Scrolls sideways with a mouse wheel too, and eases to a new place for the arrow keys.
private final class SidewaysScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return super.scrollWheel(with: event) }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 24
        moveTo(contentView.bounds.minX - step, animated: false)
    }

    func scrollBy(_ distance: CGFloat) {
        moveTo(contentView.bounds.minX + distance, animated: true)
    }

    private func moveTo(_ x: CGFloat, animated: Bool) {
        let limit = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        let origin = CGPoint(x: min(max(x, 0), limit), y: contentView.bounds.minY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                contentView.animator().setBoundsOrigin(origin)
            }
        } else {
            contentView.setBoundsOrigin(origin)
        }
        reflectScrolledClipView(contentView)
    }
}

// MARK: Film

/// Film: dark, with a row of rounded sprocket holes along the top and bottom edges, spaced from
/// the strip's start so they line up from one piece to the next.
private class FilmView: NSView {
    static let pitch: CGFloat = 18

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.07, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.22, alpha: 1).setFill()
        let phase = FilmStrip.sprocketPhase(atX: frame.minX, pitch: Self.pitch)
        var x = phase - Self.pitch
        while x < bounds.width {
            // Holes close to the outer edges, leaving room inside them for the edge print.
            for y in [4, bounds.height - 4 - 10] {
                NSBezierPath(roundedRect: CGRect(x: x + 4, y: y, width: 9, height: 10), xRadius: 2, yRadius: 2).fill()
            }
            x += Self.pitch
        }
    }
}

/// A day's marker: its date printed sideways on the film in the orange of film-edge markings.
private final class FilmDayView: FilmView {
    static let width: CGFloat = 44
    private var title = ""
    private var count = 0

    func show(title: String, count: Int) {
        self.title = title
        self.count = count
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let orange = NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 0.95)
        let text = "\(title) · \(count) 张" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: orange]
        let size = text.size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX - size.height / 2, yBy: bounds.midY + size.width / 2)
        transform.rotate(byDegrees: -90)
        transform.concat()
        text.draw(at: .zero, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        // A thin line between days.
        orange.withAlphaComponent(0.5).setFill()
        CGRect(x: 0, y: FilmStripWindow.edge, width: 1, height: FilmStripWindow.frameHeight).fill()
    }
}

private final class FilmDayItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmDay")
    override func loadView() { view = FilmDayView() }
}

/// One capture on the film: its picture, and under it on the edge the time and app it came from.
/// A recording has ▶ and its length. It lifts a little under the mouse.
private final class FilmFrameView: FilmView {
    static let gap: CGFloat = 6
    weak var strip: FilmStripWindow?
    private var entry: HistoryEntry?
    private var picture: NSImage?
    private var isHovered = false { didSet { needsDisplay = true } }
    private var pressedAt: CGPoint?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func show(_ entry: HistoryEntry, picture: NSImage?) {
        self.entry = entry
        self.picture = picture
        isHovered = false
        toolTip = [entry.sourceAppName, Self.timeFormatter.string(from: entry.createdAt)].compactMap { $0 }.joined(separator: " · ")
        needsDisplay = true
    }

    /// Where the picture is, in this view.
    var pictureFrame: CGRect {
        CGRect(x: Self.gap, y: FilmStripWindow.edge, width: bounds.width - Self.gap * 2, height: FilmStripWindow.frameHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let entry else { return }
        let frame = isHovered ? pictureFrame.insetBy(dx: -2, dy: -3) : pictureFrame
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).addClip()
        NSColor(white: 0.16, alpha: 1).setFill()
        frame.fill()
        if let picture {
            // Filled, cropped to the frame's shape.
            let size = picture.size
            let scale = max(frame.width / max(size.width, 1), frame.height / max(size.height, 1))
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)
            picture.draw(in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
                         from: .zero, operation: .sourceOver, fraction: isHovered ? 1 : 0.92, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        if isHovered {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            ring.lineWidth = 2
            ring.stroke()
        }
        if let duration = entry.recordingDuration {
            let seconds = Int(duration.rounded())
            let badge = String(format: "▶ %d:%02d", seconds / 60, seconds % 60) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                                                             .foregroundColor: NSColor.white]
            let size = badge.size(withAttributes: attributes)
            let pill = CGRect(x: frame.minX + 6, y: frame.maxY - size.height - 10, width: size.width + 10, height: size.height + 4)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            badge.draw(at: CGPoint(x: pill.minX + 5, y: pill.minY + 2), withAttributes: attributes)
        }
        if entry.isFavorite {
            ("★" as NSString).draw(at: CGPoint(x: frame.maxX - 16, y: frame.minY + 4),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemYellow])
        }
        // The edge print: time, and the app if it fits.
        let edge = [Self.timeFormatter.string(from: entry.createdAt), entry.sourceAppName].compactMap { $0 }.joined(separator: " ") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 0.8),
        ]
        edge.draw(with: CGRect(x: Self.gap + 2, y: bounds.height - FilmStripWindow.edge + 3, width: bounds.width - Self.gap * 2 - 4, height: 13),
                  options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        strip?.hovered = entry
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if strip?.hovered == entry { strip?.hovered = nil }
    }

    override func resetCursorRects() { addCursorRect(pictureFrame, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressedAt = convert(event.locationInWindow, from: nil) }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, let entry else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        pressedAt = nil
        let image = picture ?? NSImage(size: pictureFrame.size)
        strip?.dragOut(entry, from: self, frame: pictureFrame, image: image, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        guard pressedAt != nil, let entry else { return }
        strip?.pick(entry)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        entry.flatMap { strip?.menu(for: $0) }
    }
}

private final class FilmFrameItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FilmFrame")
    override func loadView() { view = FilmFrameView() }
}
