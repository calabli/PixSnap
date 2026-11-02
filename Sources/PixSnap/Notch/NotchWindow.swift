import AppKit
import PixSnapCore

/// The pull-down handle: a black shape exactly over the camera notch (or a small bar at the top center
/// of screens without one), so it reads as the notch itself. Hover: it grows a little and hints.
/// Press and pull down: the clotheslines slide down from the top of the screen with the mouse; let go
/// past the threshold, or just click, and they settle. There's no panel behind them — only ropes
/// across the whole screen and the captures hanging from them. Esc, a click elsewhere (it passes
/// through to what's underneath) or a click on the handle puts them away. Space previews the photo
/// under the mouse in a large view; ← → step through the photos, Return floats the one shown.
///
/// Deleting works like a real line: click a photo's clip and it opens, letting the photo fall into
/// the laundry basket at the bottom of the screen (Delete does the same for the photo under the
/// mouse or in the preview). The basket keeps captures for a while; click it to hang them
/// back, or empty it. ⌘Z hangs the last one thrown back up. F (or the right-click menu) makes a
/// photo a favorite: it gets a wooden clip that won't let go, so favorites can't be thrown away. While the lines are out the window
/// covers the whole screen, transparent except for what's drawn, so photos can fall all the way.
@MainActor
final class NotchWindow: NSPanel {
    var onPick: ((HistoryEntry) -> Void)?
    /// Supplies the days to hang each time the lines are about to come down.
    var loadDays: ((String) -> Lines)?
    /// The handle stays invisible until the mouse is over it.
    var hidesHandle: Bool {
        get { handle.hiddenUntilHover }
        set { handle.hiddenUntilHover = newValue }
    }

    /// What to hang: the days, what to say when there are none, and while searching, how many
    /// captures matched.
    struct Lines {
        let days: [HistoryGrouping.Day]
        let emptyMessage: String
        let found: Int?
    }

    let screenFrame: CGRect
    private let collapsedFrame: CGRect
    private let hoverFrame: CGRect
    /// The window while the lines are out: the whole screen.
    private var openFrame: CGRect
    /// How far down the lines start: below the notch (or the menu bar on other screens) and the
    /// search box.
    private let topInset: CGFloat
    private let search = SearchBox()
    private var query = ""
    /// Every rope there is to hang, newest first, and the first one on screen.
    private var ropes: [ClotheslineLayout.Rope] = []
    private var ropeOffset = 0
    private let pager = PagerView()
    private var scrolled: CGFloat = 0
    private var lastPage = Date.distantPast

    private let content = PassthroughContentView()
    private let handle = HandleView()
    private let clothesline: ClotheslineView
    private let basket = BasketView(frame: .zero)
    private var basketPanel: BasketPanel?

    /// Photos falling toward the basket right now; it stays out until they land.
    private var falling = 0
    /// Thrown while the lines were out, newest last, for ⌘Z.
    private var thrown: [HistoryEntry] = []

    private enum Phase {
        case collapsed, hovering
        /// Pulling down from the handle; `startY` is the mouse's screen y at the press.
        case pulling(startY: CGFloat, distance: CGFloat)
        case open
        case closing
    }

    private var phase = Phase.collapsed
    private var outsideClickMonitor: Any?
    private lazy var preview: PhotoPreviewWindow = {
        let preview = PhotoPreviewWindow(screenFrame: screenFrame, level: NSWindow.Level(rawValue: level.rawValue + 1))
        preview.onPick = { [weak self] entry in self?.pick(entry) }
        preview.onClose = { [weak self] in self?.preview.dismiss() }
        preview.onDragOut = { [weak self] entry, view, frame, image, event in self?.dragOut(entry, from: view, frame: frame, image: image, event: event) }
        return preview
    }()

    /// Let go after pulling this far and the lines stay down.
    private static let openDistance: CGFloat = 90
    private static let springTiming = CAMediaTimingFunction(controlPoints: 0.25, 1.3, 0.4, 1)

    init(handle handleRect: CGRect, screenFrame: CGRect, menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        collapsedFrame = handleRect
        hoverFrame = NotchGeometry.hoverRect(for: handleRect)
        topInset = max(handleRect.height, menuBarHeight) + 6 + SearchBox.band
        openFrame = handleRect
        clothesline = ClotheslineView(frame: CGRect(x: 0, y: 0, width: screenFrame.width, height: ClotheslineView.Plan.empty.height))

        super.init(contentRect: handleRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar, below menus and the selection overlay.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        handle.frame = content.bounds
        handle.autoresizingMask = [.width, .height]
        handle.onMouseEntered = { [weak self] in self?.mouseEnteredHandle() }
        handle.onMouseExited = { [weak self] in self?.mouseExitedHandle() }
        handle.onMouseDown = { [weak self] in self?.pressed() }
        handle.onMouseDragged = { [weak self] in self?.dragged() }
        handle.onMouseUp = { [weak self] in self?.released() }

        clothesline.isHidden = true
        clothesline.onPick = { [weak self] entry in self?.pick(entry) }
        clothesline.onClipClick = { [weak self] entry in self?.release(entry, velocity: CGVector(dx: 0, dy: 40)) }
        clothesline.menuForEntry = { [weak self] entry in self?.menu(for: entry) }
        clothesline.onDragOut = { [weak self] entry, view, frame, image, event in self?.dragOut(entry, from: view, frame: frame, image: image, event: event) }
        basket.isHidden = true
        basket.onClick = { [weak self] in self?.toggleBasketPanel() }
        content.wantsLayer = true
        content.addSubview(clothesline)
        content.addSubview(basket)
        search.isHidden = true
        search.onChange = { [weak self] text in self?.searchChanged(text) }
        search.onLeave = { [weak self] in self?.makeFirstResponder(nil) }
        content.addSubview(search)
        pager.isHidden = true
        pager.onPage = { [weak self] step in self?.page(by: step) }
        content.addSubview(pager)
        content.addSubview(handle)
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        if basketPanel != nil {
            closeBasketPanel()
        } else if preview.entry != nil {
            preview.dismiss()
        } else {
            collapse()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard case .open = phase else { return super.keyDown(with: event) }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "f" {
                search.focus()
            } else if event.charactersIgnoringModifiers == "c", let entry = preview.entry ?? clothesline.hoveredEntry {
                copyText(of: entry)
            } else if event.charactersIgnoringModifiers == "z" {
                hangBackLastThrown()
            } else if event.keyCode == 51, event.modifierFlags.contains(.option), let entry = preview.entry ?? clothesline.hoveredEntry {
                // ⌥⌘⌫, like the Finder's "delete immediately".
                deleteForGood(entry)
            } else {
                super.keyDown(with: event)
            }
            return
        }
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            throwAwayFromKeyboard()
        case 11: // B
            if let entry = preview.entry ?? clothesline.hoveredEntry { bigBang(entry) }
        case 3: // F
            if let entry = preview.entry ?? clothesline.hoveredEntry { toggleFavorite(entry) }
        case 49: // space
            if preview.entry != nil {
                preview.dismiss()
            } else if let entry = clothesline.hoveredEntry ?? clothesline.newestEntry {
                preview.show(entry, from: clothesline.screenRect(of: entry))
            }
        case 123, 124: // ← →
            stepPreview(by: event.keyCode == 123 ? -1 : 1)
        case 125, 121: // ↓, Page Down: older ropes
            if preview.entry == nil { page(by: 1) }
        case 126, 116: // ↑, Page Up: newer
            if preview.entry == nil { page(by: -1) }
        case 36, 76: // Return, Enter
            if let entry = preview.entry { pick(entry) }
        default:
            super.keyDown(with: event)
        }
    }

    /// Previews the newest photo without a key press (`--clothesline --preview`), after the lines settle.
    func previewNewest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, case .open = self.phase, let entry = self.clothesline.newestEntry else { return }
            self.preview.show(entry, from: self.clothesline.screenRect(of: entry))
        }
    }

    /// Shows the previous or next photo on the lines, in reading order.
    private func stepPreview(by offset: Int) {
        let entries = clothesline.entries
        guard let current = preview.entry, let index = entries.firstIndex(of: current) else { return }
        let next = min(max(index + offset, 0), entries.count - 1)
        guard next != index else { return }
        preview.show(entries[next], from: clothesline.screenRect(of: entries[next]), direction: offset)
    }

    private func pick(_ entry: HistoryEntry) {
        collapse()
        onPick?(entry)
    }

    /// Brings the lines down without a gesture (menu bar item).
    /// Whether the lines are out (or coming down).
    var isOpen: Bool {
        switch phase {
        case .open, .pulling: true
        default: false
        }
    }

    func openNow() {
        guard case .collapsed = phase else { return }
        prepareLines()
        open()
    }

    // MARK: Gestures

    private func mouseEnteredHandle() {
        guard case .collapsed = phase else { return }
        phase = .hovering
        handle.showsHint = true
        animate(to: hoverFrame, duration: 0.18)
    }

    private func mouseExitedHandle() {
        guard case .hovering = phase else { return }
        phase = .collapsed
        handle.showsHint = false
        animate(to: collapsedFrame, duration: 0.2)
    }

    private func pressed() {
        switch phase {
        case .collapsed, .hovering:
            prepareLines()
            phase = .pulling(startY: NSEvent.mouseLocation.y, distance: 0)
            handle.showsHint = false
            placeLines(progress: 0)
            clothesline.isHidden = false
        case .open:
            // A click on the handle puts the lines away (on release).
            break
        default:
            break
        }
    }

    private func dragged() {
        guard case .pulling(let startY, _) = phase else { return }
        let distance = startY - NSEvent.mouseLocation.y
        phase = .pulling(startY: startY, distance: distance)
        placeLines(progress: min(1, max(0, distance / max(clothesline.frame.height, 1))))
    }

    private func released() {
        switch phase {
        case .pulling(_, let distance):
            // A plain click opens too; a short pull springs back up.
            if distance >= Self.openDistance || distance < 4 { open() } else { collapse() }
        case .open:
            collapse()
        default:
            break
        }
    }

    // MARK: Opening and closing

    /// Loads the lines and switches the window to its open size, with the handle kept where it is
    /// on screen.
    private func prepareLines() {
        query = ""
        search.reset()
        ropeOffset = 0
        pager.isHidden = true
        let (plan, lines) = planLines()
        let height = plan.height
        openFrame = screenFrame
        let handleOnScreen = frame
        setFrame(openFrame, display: false)
        handle.autoresizingMask = []
        handle.frame = handleOnScreen.offsetBy(dx: -openFrame.minX, dy: -openFrame.minY)

        clothesline.frame = CGRect(x: 0, y: 0, width: openFrame.width, height: height)
        hang(plan, emptyMessage: lines.emptyMessage)
        // The search box sits centered under the notch, above the lines.
        search.frame = CGRect(x: (openFrame.width - SearchBox.size.width) / 2, y: openFrame.height - topInset + (SearchBox.band - SearchBox.size.height) / 2,
                              width: SearchBox.size.width, height: SearchBox.size.height)
        thrown = []
        basket.entries = HistoryLibrary.shared.basket()
    }

    /// Rebuilds the lines in place after captures come back from the basket; `dropping` falls in
    /// with a bounce, or all of them when nil.
    private func reloadLines(dropping entry: HistoryEntry?, animated: Bool = true) {
        let (plan, lines) = planLines()
        clothesline.frame = CGRect(x: 0, y: content.bounds.height - topInset - plan.height, width: content.bounds.width, height: plan.height)
        hang(plan, emptyMessage: lines.emptyMessage)
        search.found = lines.found
        updatePager()
        if animated { clothesline.playDropAnimation(only: entry) }
    }

    /// The lines get the screen below the notch, minus room for the basket at the bottom.
    private func planLines() -> (ClotheslineView.Plan, Lines) {
        let lines = loadDays?(query) ?? Lines(days: [], emptyMessage: "", found: nil)
        let visible = NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame
        let available = visible.maxY - topInset - visible.minY - BasketView.size.height - 40 - PagerView.band
        ropes = ClotheslineView.ropes(lines.days, width: screenFrame.width, availableHeight: available)
        ropeOffset = min(ropeOffset, max(0, ropes.count - ClotheslineView.ropesOnScreen))
        let shown = Array(ropes.dropFirst(ropeOffset).prefix(ClotheslineView.ropesOnScreen))
        return (ClotheslineView.plan(shown, width: screenFrame.width, availableHeight: available), lines)
    }

    // MARK: Older ropes

    /// Pages without scrolling (`--clothesline --older <n>`), after the lines settle.
    func pageNow(by step: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.page(by: step) }
    }

    /// Moves `step` ropes toward older (positive) or newer captures; the new ones slide in.
    private func page(by step: Int) {
        guard case .open = phase else { return }
        let target = min(max(ropeOffset + step, 0), max(0, ropes.count - ClotheslineView.ropesOnScreen))
        guard target != ropeOffset else { return }
        ropeOffset = target
        reloadLines(dropping: nil, animated: false)
        let settled = clothesline.frame.origin
        clothesline.setFrameOrigin(CGPoint(x: settled.x, y: settled.y + (step > 0 ? -50 : 50)))
        clothesline.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = Self.springTiming
            clothesline.animator().setFrameOrigin(settled)
            clothesline.animator().alphaValue = 1
        }
    }

    /// Scrolling down (or swiping up) shows older ropes, a rope per flick.
    override func scrollWheel(with event: NSEvent) {
        guard case .open = phase, preview.entry == nil, basketPanel == nil else { return super.scrollWheel(with: event) }
        // A flick's coasting would run through the whole history.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began { scrolled = 0 }
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 60
        guard abs(scrolled) >= 50, Date().timeIntervalSince(lastPage) > 0.22 else { return }
        page(by: scrolled < 0 ? 1 : -1)
        scrolled = 0
        lastPage = Date()
    }

    /// Under the lines when there are more ropes than fit: how many older captures are left.
    private func updatePager() {
        guard case .open = phase, ropes.count > ClotheslineView.ropesOnScreen else {
            pager.isHidden = true
            return
        }
        let older = ropes.dropFirst(ropeOffset + ClotheslineView.ropesOnScreen).reduce(0) { $0 + $1.entries.count }
        pager.update(older: older, canGoNewer: ropeOffset > 0)
        let size = pager.fittingSize
        pager.frame = CGRect(x: ((content.bounds.width - size.width) / 2).rounded(),
                             y: content.bounds.height - topInset - clothesline.frame.height - PagerView.band + (PagerView.band - size.height) / 2,
                             width: size.width, height: size.height)
        pager.isHidden = false
    }

    // MARK: Search

    /// The lines follow what's typed, a moment after typing stops.
    private func searchChanged(_ text: String) {
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .open = phase, text != query else { return }
            query = text
            ropeOffset = 0
            reloadLines(dropping: nil, animated: false)
            // The photos still fade in, so the change reads as a new set.
            clothesline.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; self.clothesline.animator().alphaValue = 1 }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private var searchWork: DispatchWorkItem?

    /// Searches without typing (`--clothesline --search <text>`), after the lines settle.
    func searchNow(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.search.type(text)
            self?.searchChanged(text)
        }
    }

    private func hang(_ plan: ClotheslineView.Plan, emptyMessage: String) {
        clothesline.show(plan, style: AppSettings.shared.ropeStyle,
                         image: { HistoryLibrary.shared.image(for: $0, pixelSize: $1) },
                         moving: { HistoryLibrary.shared.movingThumbnail(for: $0) }, emptyMessage: emptyMessage)
    }

    /// 0: the lines are tucked above the top of the screen; 1: hanging in place under the notch.
    private func placeLines(progress: CGFloat) {
        let settled = content.bounds.height - topInset - clothesline.frame.height
        let tucked = content.bounds.height
        clothesline.setFrameOrigin(CGPoint(x: 0, y: tucked + (settled - tucked) * progress))
        clothesline.alphaValue = min(1, progress * 1.6)
    }

    private func open() {
        phase = .open
        clothesline.isHidden = false
        let settled = content.bounds.height - topInset - clothesline.frame.height
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = Self.springTiming
            clothesline.animator().setFrameOrigin(CGPoint(x: 0, y: settled))
            clothesline.animator().alphaValue = 1
        }
        clothesline.playDropAnimation()
        makeKey()
        startWatchingOutsideClicks()
        updateBasket()
        search.isHidden = false
        search.alphaValue = 0
        updatePager()
        pager.alphaValue = 0
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.25
            search.animator().alphaValue = 1
            pager.animator().alphaValue = 1
        }
    }

    func collapse() {
        switch phase {
        case .collapsed, .closing: return
        case .hovering:
            phase = .collapsed
            handle.showsHint = false
            animate(to: collapsedFrame, duration: 0.2)
            return
        default:
            break
        }
        phase = .closing
        // A preview being dragged from stays until its drag is over (it's hidden meanwhile).
        if !preview.isDraggingOut { preview.dismiss(animated: false) }
        closeBasketPanel()
        setBasketShown(false)
        stopWatchingOutsideClicks()
        search.isHidden = true
        pager.isHidden = true
        searchWork?.cancel()
        handle.showsHint = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            clothesline.animator().setFrameOrigin(CGPoint(x: 0, y: content.bounds.height))
            clothesline.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishCollapsing() }
        })
    }

    /// Back to just the handle.
    private func finishCollapsing() {
        guard case .closing = phase else { return }
        phase = .collapsed
        clothesline.isHidden = true
        setFrame(collapsedFrame, display: true)
        handle.frame = content.bounds
        handle.autoresizingMask = [.width, .height]
    }

    // MARK: Copying text

    /// The text in a capture onto the clipboard, recognizing it now if needed.
    private func copyText(of entry: HistoryEntry) {
        Task {
            let text = await HistoryLibrary.shared.recognizedText(for: entry)
            if text.isEmpty {
                NSSound.beep()
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            search.flash("已复制 \(text.split(separator: "\n").count) 行文字")
        }
    }

    // MARK: The laundry basket

    /// Out while there's something in it or a photo on its way down.
    private func updateBasket() {
        basket.entries = HistoryLibrary.shared.basket()
        guard case .open = phase else { return }
        setBasketShown(!basket.entries.isEmpty || falling > 0)
    }

    /// Bottom center of the screen, just above the Dock.
    private var basketRestFrame: CGRect {
        let visible = NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame
        let size = BasketView.size
        return CGRect(x: (screenFrame.width - size.width) / 2, y: visible.minY - screenFrame.minY + 12, width: size.width, height: size.height)
    }

    private var basketShown = false

    /// Rises up from below the bottom of the screen on a spring, or sinks back down.
    private func setBasketShown(_ shown: Bool) {
        guard shown != basketShown else { return }
        basketShown = shown
        let rest = basketRestFrame
        let depth = rest.maxY + 20
        basket.frame = rest
        guard let layer = basket.layer else { basket.isHidden = !shown; return }
        // The offset rides on top of the basket's own transform, so it composes with its bounces.
        let current = (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? (shown ? -depth : 0)
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.isAdditive = true
        if shown {
            basket.isHidden = false
            layer.removeAnimation(forKey: "sink")
            let rise = Motion.spring("transform.translation.y", from: current == 0 ? -depth : current, to: 0, duration: 0.5, bounce: 0.25)
            rise.isAdditive = true
            layer.add(rise, forKey: "rise")
        } else {
            slide.fromValue = 0
            slide.toValue = -depth
            slide.duration = 0.25
            slide.timingFunction = CAMediaTimingFunction(name: .easeIn)
            slide.fillMode = .forwards
            slide.isRemovedOnCompletion = false
            Motion.run(on: layer, ["sink": slide]) { [weak self] in
                guard let self, !self.basketShown else { return }
                self.basket.isHidden = true
                layer.removeAnimation(forKey: "sink")
            }
        }
    }

    /// Where falling photos land, in window coordinates.
    private var basketMouth: CGPoint {
        let rest = basketRestFrame
        return CGPoint(x: rest.minX + basket.mouth.x, y: rest.minY + basket.mouth.y)
    }

    /// Opens the clip and lets the photo fall into the basket, unless it's a favorite.
    private func release(_ entry: HistoryEntry, velocity: CGVector) {
        guard !clothesline.isFavorite(entry) else { return clothesline.refuseToLetGo(of: entry) }
        guard let (loose, frame) = clothesline.pullOff(entry) else { return }
        loose.position = CGPoint(x: frame.midX, y: frame.midY)
        content.layer?.addSublayer(loose)
        fall(loose, entry: entry, velocity: velocity)
    }

    /// Throws the newest photo without a key press (`--clothesline --throw`), after the lines settle.
    func throwNewest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, case .open = self.phase, let entry = self.clothesline.newestEntry else { return }
            self.release(entry, velocity: CGVector(dx: 0, dy: 40))
        }
    }

    /// Delete: the photo in the preview, or the one under the mouse.
    private func throwAwayFromKeyboard() {
        if let entry = preview.entry, HistoryLibrary.shared.isFavorite(entry.id) {
            preview.refuseToThrow()
        } else if let entry = preview.entry, let (loose, frame) = preview.takePicture() {
            _ = clothesline.pullOff(entry)
            toss(loose, from: frame, entry: entry)
        } else if let entry = clothesline.hoveredEntry {
            release(entry, velocity: CGVector(dx: 0, dy: 380))
        }
    }

    // MARK: Dragging out

    /// Takes a copy of the capture to another app. The lines go up as it leaves, so the whole
    /// screen is there to drop onto; if nothing takes it, they come back down.
    ///
    /// The window's `ignoresMouseEvents` is never touched: setting it back to false makes AppKit
    /// stop letting clicks through the transparent parts, and this window covers the screen.
    private func dragOut(_ entry: HistoryEntry, from view: NSView, frame: CGRect, image: NSImage, event: NSEvent) {
        let ended: (Bool) -> Void = { [weak self] taken in
            guard let self else { return }
            preview.endDragOut()
            if !taken { openNow() }
        }
        if entry.isRecording {
            guard let video = HistoryLibrary.shared.videoURL(for: entry) else { return }
            CaptureDrag.begin(file: video, image: image, from: frame, in: view, event: event, ended: ended)
        } else {
            guard let capture = HistoryLibrary.shared.loadCapture(entry) else { return }
            CaptureDrag.begin(capture, image: image, from: frame, in: view, event: event, ended: ended)
        }
        collapse()
    }

    // MARK: Favorites

    private func toggleFavorite(_ entry: HistoryEntry) {
        let favorite = !HistoryLibrary.shared.isFavorite(entry.id)
        HistoryLibrary.shared.setFavorite(favorite, id: entry.id)
        clothesline.setFavorite(favorite, for: entry)
        if preview.entry == entry { preview.showFavorite(favorite) }
    }

    /// Right-click on a photo.
    private func menu(for entry: HistoryEntry) -> NSMenu {
        let favorite = clothesline.isFavorite(entry)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, key: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.target = self
            item.representedObject = entry
            menu.addItem(item)
        }
        add(favorite ? "取消收藏" : "收藏", favorite ? "star.slash" : "star", key: "f", #selector(favoriteFromMenu(_:)))
        add("预览", "eye", key: " ", #selector(previewFromMenu(_:)))
        add("浮动到屏幕上", "macwindow.on.rectangle", key: "\r", #selector(floatFromMenu(_:)))
        add("复制文字", "text.viewfinder", key: "", #selector(copyTextFromMenu(_:)))
        add("大爆炸", "sparkles", key: "b", #selector(bigBangFromMenu(_:)))
        menu.addItem(.separator())
        add(favorite ? "已收藏，不能扔" : "扔进洗衣篮", "basket", key: "\u{8}", #selector(throwFromMenu(_:)), enabled: !favorite)
        add("永久删除…", "trash", key: "", #selector(deleteFromMenu(_:)))
        return menu
    }

    @objc private func favoriteFromMenu(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? HistoryEntry else { return }
        toggleFavorite(entry)
    }

    @objc private func previewFromMenu(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? HistoryEntry else { return }
        preview.show(entry, from: clothesline.screenRect(of: entry))
    }

    @objc private func bigBangFromMenu(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? HistoryEntry else { return }
        bigBang(entry)
    }

    /// 大爆炸 on a capture on the line (or in the preview), bursting from where it's shown.
    private func bigBang(_ entry: HistoryEntry) {
        let image = entry.isRecording ? HistoryLibrary.shared.image(for: entry, pixelSize: 1600) : HistoryLibrary.shared.loadCapture(entry)?.image
        guard let image, let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) ?? NSScreen.main,
              let from = (preview.entry == entry ? preview.pictureScreenFrame : nil) ?? clothesline.screenRect(of: entry) else { return }
        BigBangWindow.show(image: image, imageFrame: from, on: screen)
    }

    @objc private func copyTextFromMenu(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? HistoryEntry else { return }
        copyText(of: entry)
    }

    @objc private func floatFromMenu(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? HistoryEntry else { return }
        pick(entry)
    }

    @objc private func deleteFromMenu(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? HistoryEntry else { return }
        deleteForGood(entry)
    }

    /// Deletes a capture for good, after asking: not into the basket, no ⌘Z. The photo dissolves
    /// where it hangs (or where the preview shows it).
    private func deleteForGood(_ entry: HistoryEntry) {
        let favorite = HistoryLibrary.shared.isFavorite(entry.id)
        let alert = NSAlert()
        alert.messageText = favorite ? "永久删除这张收藏的截图？" : "永久删除这张截图？"
        alert.informativeText = "会从截图历史里删除，不进洗衣篮，无法恢复。已经用“保存”存到别处的文件不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        // Above the lines and the preview, which sit over everything.
        alert.window.level = NSWindow.Level(rawValue: level.rawValue + 2)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let taken: (layer: CALayer, frame: CGRect)?
        if preview.entry == entry, let picture = preview.takePicture() {
            _ = clothesline.pullOff(entry)
            taken = picture
        } else {
            taken = clothesline.pullOff(entry)
        }
        HistoryLibrary.shared.deletePermanently([entry.id])
        thrown.removeAll { $0 == entry }
        TrashSound.emptyTrash.play()
        guard let (photo, frame) = taken else { return }
        // A soft "poof": it swells a little as it fades.
        photo.position = CGPoint(x: frame.midX, y: frame.midY)
        content.layer?.addSublayer(photo)
        let scale = (photo.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        Motion.immediately {
            photo.opacity = 0
            photo.setValue(scale * 1.25, forKeyPath: "transform.scale")
        }
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = scale
        swell.toValue = scale * 1.25
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [swell, fade]
        group.duration = 0.3
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        Motion.run(on: photo, ["poof": group]) { photo.removeFromSuperlayer() }
    }

    @objc private func throwFromMenu(_ item: NSMenuItem) {
        guard let entry = item.representedObject as? HistoryEntry else { return }
        release(entry, velocity: CGVector(dx: 0, dy: 40))
    }

    /// From the preview, the picture gets a small hop before it falls.
    private func toss(_ loose: CALayer, from frame: CGRect, entry: HistoryEntry) {
        loose.position = CGPoint(x: frame.midX, y: frame.midY)
        content.layer?.addSublayer(loose)
        fall(loose, entry: entry, velocity: CGVector(dx: 0, dy: 380))
    }

    /// Falls under gravity from where it is, with the speed it has, and curves into the basket: the
    /// path is worked out frame by frame like a thrown object, so it speeds up as it drops. It
    /// turns with its sideways speed and shrinks as it goes in over the rim.
    private func fall(_ photo: CALayer, entry: HistoryEntry, velocity: CGVector) {
        falling += 1
        closeBasketPanel()
        updateBasket()
        let start = photo.presentation()?.position ?? photo.position, end = basketMouth
        let gravity: CGFloat = 3200
        let vx = min(max(velocity.dx, -1600), 1600)
        var vy = min(max(velocity.dy, -1400), 900)
        let drop = start.y - end.y
        // Starting below the rim, it has to be tossed up and over.
        if drop < 0 { vy = max(vy, sqrt(2 * gravity * -drop) + 220) }
        let flight = min(max((vy + sqrt(vy * vy + 2 * gravity * drop)) / gravity, 0.38), 1.1)
        // The sideways pull that lands it in the basket despite its own sideways speed.
        let pull = 2 * (end.x - start.x - vx * flight) / (flight * flight)

        let steps = 48
        var points: [NSValue] = []
        var angles: [NSNumber] = []
        var scales: [NSNumber] = []
        let startAngle = (photo.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        let startScale = (photo.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        let endScale = min(startScale, 44 / max(photo.bounds.width, photo.bounds.height, 1))
        let spin = min(max(((end.x - start.x) / flight) * 0.0012 + (vx >= 0 ? 0.35 : -0.35), -1.4), 1.4)
        for step in 0...steps {
            let u = CGFloat(step) / CGFloat(steps), t = u * flight
            points.append(NSValue(point: CGPoint(x: start.x + vx * t + pull * t * t / 2, y: start.y + vy * t - gravity * t * t / 2)))
            angles.append(NSNumber(value: Double(startAngle + spin * u)))
            scales.append(NSNumber(value: Double(startScale - (startScale - endScale) * u * u * u)))
        }

        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = points
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = angles
        let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
        shrink.values = scales
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.9, 1]
        let group = CAAnimationGroup()
        group.animations = [move, turn, shrink, fade]
        group.duration = Double(flight)

        photo.removeAllAnimations()
        Motion.immediately {
            photo.position = end
            photo.opacity = 0
        }
        Motion.run(on: photo, ["fall": group]) { [weak self] in
            photo.removeFromSuperlayer()
            self?.landed(entry)
        }
    }

    private func landed(_ entry: HistoryEntry) {
        falling -= 1
        HistoryLibrary.shared.throwIntoBasket([entry])
        thrown.append(entry)
        basket.bounce()
        TrashSound.moveToTrash.play()
        updateBasket()
    }

    /// ⌘Z: the last photo thrown goes back on its line.
    private func hangBackLastThrown() {
        guard let entry = thrown.popLast() else { return }
        hangBack([entry])
    }

    private func hangBack(_ entries: [HistoryEntry]) {
        closeBasketPanel()
        HistoryLibrary.shared.restore(entries)
        thrown.removeAll { entries.contains($0) }
        reloadLines(dropping: entries.count == 1 ? entries[0] : nil)
        updateBasket()
    }

    /// Opens the basket without a click (`--clothesline --basket`).
    func openBasket() {
        guard case .open = phase, basketPanel == nil else { return }
        toggleBasketPanel()
    }

    private func toggleBasketPanel() {
        if basketPanel != nil { return closeBasketPanel() }
        let entries = HistoryLibrary.shared.basket()
        guard !entries.isEmpty else { return }
        let panel = BasketPanel(entries: entries)
        panel.onRestore = { [weak self] entries in self?.hangBack(entries) }
        panel.onEmpty = { [weak self] in self?.emptyBasket() }
        panel.onDelete = { [weak self] entry in self?.deleteFromBasket(entry) }
        let rest = basketRestFrame
        let x = min(max(rest.midX - panel.frame.width / 2, 12), content.bounds.width - panel.frame.width - 12)
        panel.setFrameOrigin(CGPoint(x: x, y: rest.maxY + 28))
        content.addSubview(panel)
        basketPanel = panel
        panel.appear()
    }

    private func closeBasketPanel() {
        basketPanel?.disappear()
        basketPanel = nil
    }

    /// One capture in the basket deleted for good; the basket opens again on the rest.
    private func deleteFromBasket(_ entry: HistoryEntry) {
        closeBasketPanel()
        TrashSound.emptyTrash.play()
        HistoryLibrary.shared.deletePermanently([entry.id])
        thrown.removeAll { $0 == entry }
        updateBasket()
        toggleBasketPanel()
    }

    /// The basket tips out, then the captures are deleted for good and it sinks away.
    private func emptyBasket() {
        closeBasketPanel()
        TrashSound.emptyTrash.play()
        basket.tipOut { [weak self] in
            HistoryLibrary.shared.emptyBasket()
            self?.thrown = []
            self?.updateBasket()
        }
    }

    private func animate(to frame: CGRect, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(frame, display: true)
        }
    }

    /// Clicks in other apps (including on empty space between the lines, which passes through)
    /// put the lines away. Mouse-click monitors need no special permission.
    private func startWatchingOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

/// The window's transparent content: only the handle and the photos take clicks.
@MainActor
private final class PassthroughContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The black notch shape with rounded bottom corners, and the hint shown while hovering.
@MainActor
private final class HandleView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseDown: (() -> Void)?
    var onMouseDragged: (() -> Void)?
    var onMouseUp: (() -> Void)?

    var showsHint = false {
        didSet {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hint.animator().alphaValue = showsHint ? 1 : 0 }
            updateFill()
        }
    }

    /// Invisible until the mouse is over it. Not fully clear, or clicks would fall through to what's
    /// underneath and it couldn't be found.
    var hiddenUntilHover = false {
        didSet { updateFill() }
    }

    private func updateFill() {
        let hidden = hiddenUntilHover && !showsHint
        layer?.backgroundColor = NSColor.black.withAlphaComponent(hidden ? 0.01 : 1).cgColor
    }

    private let hint = NSTextField(labelWithString: "↓ 下拉看历史")

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] // bottom corners
        layer?.cornerRadius = 10
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor(white: 1, alpha: 0.75)
        hint.alphaValue = 0
        hint.sizeToFit()
        hint.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        addSubview(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        hint.setFrameOrigin(CGPoint(x: ((bounds.width - hint.frame.width) / 2).rounded(), y: 3))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        hint.setFrameOrigin(CGPoint(x: ((bounds.width - hint.frame.width) / 2).rounded(), y: 3))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?() }
    override func mouseUp(with event: NSEvent) { onMouseUp?() }
}

/// "更早的还有 37 张" under the lines, with ↑ / ↓ buttons, when there's more history than fits.
@MainActor
private final class PagerView: NSView {
    /// Room kept for it under the lines.
    static let band: CGFloat = 36

    var onPage: ((Int) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private lazy var newer = button("chevron.up", tip: "较新的（↑ 或往上滚动）", step: -1)
    private lazy var older = button("chevron.down", tip: "更早的（↓ 或往下滚动）", step: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        let stack = NSStackView(views: [newer, label, older])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(older count: Int, canGoNewer: Bool) {
        label.stringValue = count > 0 ? "更早的还有 \(count) 张" : "已经是最早的了"
        older.isEnabled = count > 0
        newer.isEnabled = canGoNewer
        layoutSubtreeIfNeeded()
        layer?.cornerRadius = fittingSize.height / 2
    }

    private func button(_ symbol: String, tip: String, step: Int) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: #selector(clicked))
        button.isBordered = false
        button.contentTintColor = .white
        button.tag = step
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    @objc private func clicked(_ sender: NSButton) { onPage?(sender.tag) }
}

/// The search box above the lines: type to keep only the captures whose text (or app) has it.
/// ⌘F or a click puts the cursor in it; Esc clears it, then leaves it. While it has the cursor,
/// keys type into it rather than acting on the photos.
@MainActor
private final class SearchBox: NSView, NSSearchFieldDelegate {
    var onChange: ((String) -> Void)?
    /// Esc with nothing typed: give the keyboard back to the lines.
    var onLeave: (() -> Void)?

    /// How much room it takes above the lines, and its own size.
    static let band: CGFloat = 40
    static let size = CGSize(width: 320, height: 28)

    /// How many captures matched, while searching.
    var found: Int? {
        didSet { showCount() }
    }

    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: frame.origin, size: Self.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Self.size.height / 2
        appearance = NSAppearance(named: .darkAqua)

        field.placeholderString = "搜索截图里的文字或应用（⌘F）"
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.frame = CGRect(x: 6, y: 3, width: Self.size.width - 84, height: 22)
        addSubview(field)

        count.font = .systemFont(ofSize: 11)
        count.textColor = NSColor(white: 1, alpha: 0.6)
        count.alignment = .right
        count.frame = CGRect(x: Self.size.width - 80, y: 6, width: 68, height: 16)
        addSubview(count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func focus() {
        window?.makeFirstResponder(field)
    }

    func reset() {
        field.stringValue = ""
        found = nil
    }

    func type(_ text: String) {
        field.stringValue = text
    }

    /// A short note in place of the count ("已复制 3 行文字").
    func flash(_ note: String) {
        count.stringValue = note
        count.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.count.textColor = NSColor(white: 1, alpha: 0.6)
            self?.showCount()
        }
    }

    private func showCount() {
        count.stringValue = found.map { $0 == 0 ? "没有找到" : "找到 \($0) 张" } ?? ""
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if field.stringValue.isEmpty {
            onLeave?()
        } else {
            field.stringValue = ""
            onChange?("")
        }
        return true
    }
}
