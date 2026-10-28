import AppKit
import PixSnapCore

/// 大爆炸: the text in a capture bursts out into tiles, one per word or punctuation mark, each flying
/// from where it was in the image to its place in a tidy grid. Click tiles to pick them, or drag
/// across several (starting on a picked one un-picks); then copy them (joined back with the right
/// spacing) or search the web for them. ⌘A picks all, ⌘C copies, Esc or a click outside closes.
@MainActor
final class BigBangWindow: NSPanel {
    /// Open boards, kept alive until closed.
    private static var open: [BigBangWindow] = []

    /// Reads `image` (shown on screen at `imageFrame`, global coordinates) and bursts its text.
    static func show(image: CGImage, imageFrame: CGRect, on screen: NSScreen) {
        let window = BigBangWindow(screen: screen)
        open.append(window)
        window.present(image: image, imageFrame: imageFrame)
    }

    private let backdrop = NSVisualEffectView()
    private let dim = NSView()
    private let scroll = NSScrollView()
    private let board = BoardView()
    private let bar = BigBangBar()
    private let status = NSTextField(labelWithString: "正在识别文字…")
    private let hint = NSTextField(labelWithString: "点选或拖过要的词 · ⌘A 全选 · ⌘C 复制 · Esc 关闭")

    private static let boardWidth: CGFloat = 860
    private static let barHeight: CGFloat = 44

    private init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)

        let content = OutsideClickView(frame: CGRect(origin: .zero, size: screen.frame.size))
        content.onOutsideClick = { [weak self] in self?.dismiss() }
        contentView = content
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        for view in [backdrop, dim] {
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }

        for label in [status, hint] {
            label.textColor = NSColor(white: 1, alpha: 0.7)
            label.alignment = .center
            label.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: 18)
            content.addSubview(label)
        }
        status.font = .systemFont(ofSize: 14, weight: .medium)
        status.frame.origin.y = content.bounds.midY
        hint.font = .systemFont(ofSize: 12)
        hint.isHidden = true

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = board
        scroll.isHidden = true
        content.addSubview(scroll)

        bar.isHidden = true
        bar.onSelectAll = { [weak self] in self?.board.toggleAll() }
        bar.onCopy = { [weak self] in self?.copySelection() }
        bar.onSearch = { [weak self] in self?.searchSelection() }
        bar.onClose = { [weak self] in self?.dismiss() }
        content.addSubview(bar)
        board.onSelectionChange = { [weak self] count, total in self?.bar.setSelected(count, of: total) }
        content.outsideOf = { [weak self] in [self?.scroll.frame, self?.bar.frame].compactMap { $0 } }
    }

    override var canBecomeKey: Bool { true }

    private func present(image: CGImage, imageFrame: CGRect) {
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
        Task {
            let pieces = await TextRecognizer.pieces(in: image)
            guard isVisible else { return }
            guard !pieces.isEmpty else {
                status.stringValue = "没有识别到文字"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.dismiss() }
                return
            }
            burst(pieces, from: imageFrame)
        }
    }

    /// Lays the tiles out, then sends each flying from its spot in the image.
    private func burst(_ pieces: [TextRecognizer.PlacedPiece], from imageFrame: CGRect) {
        guard let content = contentView else { return }
        status.isHidden = true
        let width = min(Self.boardWidth, content.bounds.width - 120)
        let height = board.layOut(pieces.map(\.piece), width: width)
        let visibleHeight = min(height, content.bounds.height - 260)
        scroll.frame = CGRect(x: (content.bounds.width - width) / 2, y: (content.bounds.height - visibleHeight) / 2 + 20,
                              width: width, height: visibleHeight)
        scroll.isHidden = false
        hint.frame.origin.y = scroll.frame.maxY + 14
        hint.isHidden = false
        bar.frame = CGRect(x: (content.bounds.width - 480) / 2, y: scroll.frame.minY - Self.barHeight - 18, width: 480, height: Self.barHeight)
        bar.isHidden = false
        bar.setSelected(0, of: pieces.count)

        // Where each piece was on screen, in the board's coordinates.
        let origins = pieces.map { placed -> CGPoint in
            let onScreen = CGPoint(x: imageFrame.minX + placed.box.midX * imageFrame.width, y: imageFrame.minY + placed.box.midY * imageFrame.height)
            return board.convert(CGPoint(x: onScreen.x - frame.minX, y: onScreen.y - frame.minY), from: nil)
        }
        board.burst(from: origins)
    }

    // MARK: Actions

    private func copySelection() {
        let text = BigBangText.join(board.selectedPieces)
        guard !text.isEmpty else { return bar.flash("先点选要复制的词") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        bar.flash("已复制")
    }

    /// The picked words in the default browser.
    private func searchSelection() {
        let text = BigBangText.join(board.selectedPieces).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return bar.flash("先点选要搜索的词") }
        var components = URLComponents(string: "https://www.bing.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        if let url = components.url { NSWorkspace.shared.open(url) }
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "a": board.selectAll()
        case "c": copySelection()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; self.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.orderOut(nil)
                Self.open.removeAll { $0 === self }
            }
        })
    }
}

/// The tiles, laid out like text in a flipped document view: picked ones fill with the accent color.
@MainActor
private final class BoardView: NSView {
    var onSelectionChange: ((Int, Int) -> Void)?

    private struct Tile {
        let piece: BigBangText.Piece
        let layer: CALayer
        let frame: CGRect
        var selected = false
    }

    private var tiles: [Tile] = []
    /// While dragging: what the tiles passed over become.
    private var painting: Bool?

    private static let height: CGFloat = 34
    private static let gap: CGFloat = 8

    override var isFlipped: Bool { true }

    var selectedPieces: [BigBangText.Piece] { tiles.filter(\.selected).map(\.piece) }

    /// Flows the tiles left to right in rows `width` wide. Returns the height they take.
    func layOut(_ pieces: [BigBangText.Piece], width: CGFloat) -> CGFloat {
        wantsLayer = true
        tiles.forEach { $0.layer.removeFromSuperlayer() }
        tiles = []
        var x: CGFloat = 0, y: CGFloat = 0
        for piece in pieces {
            let font = NSFont.systemFont(ofSize: piece.isWord ? 17 : 15, weight: piece.isWord ? .medium : .regular)
            let textWidth = ceil((piece.text as NSString).size(withAttributes: [.font: font]).width)
            let tileWidth = min(width, textWidth + (piece.isWord ? 24 : 16))
            if x > 0, x + tileWidth > width {
                x = 0
                y += Self.height + Self.gap
            }
            let frame = CGRect(x: x, y: y, width: tileWidth, height: Self.height)
            x += tileWidth + Self.gap

            let layer = CALayer()
            layer.frame = frame
            layer.cornerRadius = 9
            layer.cornerCurve = .continuous
            let text = CATextLayer()
            text.string = piece.text
            text.font = font
            text.fontSize = font.pointSize
            text.alignmentMode = .center
            text.truncationMode = .end
            text.contentsScale = window?.backingScaleFactor ?? 2
            text.frame = CGRect(x: 4, y: (Self.height - font.pointSize * 1.25) / 2, width: tileWidth - 8, height: font.pointSize * 1.3)
            layer.addSublayer(text)
            self.layer?.addSublayer(layer)
            tiles.append(Tile(piece: piece, layer: layer, frame: frame))
            style(tiles.count - 1)
        }
        let height = y + Self.height
        frame = CGRect(x: 0, y: 0, width: width, height: height)
        return height
    }

    /// Each tile flies from `origins[i]` (where its word was) to its place, popping in, the
    /// nearer ones first.
    func burst(from origins: [CGPoint]) {
        let now = CACurrentMediaTime()
        for (index, tile) in tiles.enumerated() {
            let from = origins.indices.contains(index) ? origins[index] : CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            let to = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            let delay = min(0.35, Double(index) * 0.006)
            let fly = Motion.spring("position", from: NSValue(point: from), to: NSValue(point: to), duration: 0.6, bounce: 0.28)
            let pop = Motion.spring("transform.scale", from: 0.3, to: 1, duration: 0.55, bounce: 0.35)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.15
            for animation in [fly, pop, fade] as [CAAnimation] {
                animation.beginTime = now + delay
                animation.fillMode = .backwards
                tile.layer.add(animation, forKey: animation === fly ? "fly" : animation === pop ? "pop" : "fade")
            }
        }
    }

    func selectAll() {
        for index in tiles.indices { tiles[index].selected = true; style(index) }
        report()
    }

    /// Select all, or with everything already picked, clear.
    func toggleAll() {
        let all = tiles.allSatisfy(\.selected)
        for index in tiles.indices { tiles[index].selected = !all; style(index) }
        report()
    }

    private func style(_ index: Int) {
        let tile = tiles[index]
        Motion.immediately {
            tile.layer.backgroundColor = tile.selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor(white: 1, alpha: tile.piece.isWord ? 0.14 : 0.07).cgColor
            (tile.layer.sublayers?.first as? CATextLayer)?.foregroundColor = tile.selected || tile.piece.isWord
                ? NSColor.white.cgColor : NSColor(white: 1, alpha: 0.6).cgColor
        }
    }

    private func report() {
        onSelectionChange?(tiles.filter(\.selected).count, tiles.count)
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tile(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return tiles.firstIndex { $0.frame.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = tile(at: event) else { return }
        painting = !tiles[index].selected
        paint(index)
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        guard let index = tile(at: event) else { return }
        paint(index)
    }

    override func mouseUp(with event: NSEvent) {
        painting = nil
    }

    private func paint(_ index: Int) {
        guard let painting, tiles[index].selected != painting else { return }
        tiles[index].selected = painting
        style(index)
        tiles[index].layer.add(Motion.spring("transform.scale", from: 0.88, to: 1, duration: 0.25, bounce: 0.4), forKey: "tap")
        report()
    }
}

/// The bar under the tiles: how many are picked, and what to do with them.
@MainActor
private final class BigBangBar: NSVisualEffectView {
    var onSelectAll: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSearch: (() -> Void)?
    var onClose: (() -> Void)?

    private let count = NSTextField(labelWithString: "")
    private let selectAll = NSButton(title: "全选", target: nil, action: nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        material = .hudWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        selectAll.target = self
        selectAll.action = #selector(selectAllClicked)
        let views: [NSView] = [
            count, NSView(), selectAll,
            button("复制", symbol: "doc.on.doc", action: #selector(copyClicked)),
            button("搜索", symbol: "magnifyingglass", action: #selector(searchClicked)),
            button(nil, symbol: "xmark", action: #selector(closeClicked)),
        ]
        for view in views.compactMap({ $0 as? NSButton }) { view.bezelStyle = .rounded }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func button(_ title: String?, symbol: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)!
        let button = title.map { NSButton(title: $0, image: image, target: self, action: action) } ?? NSButton(image: image, target: self, action: action)
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        return button
    }

    func setSelected(_ selected: Int, of total: Int) {
        count.stringValue = selected == 0 ? "共 \(total) 个词，点选或拖选" : "已选 \(selected) / \(total)"
        selectAll.title = selected == total && total > 0 ? "取消全选" : "全选"
    }

    /// A short note in place of the count.
    func flash(_ note: String) {
        let previous = count.stringValue
        count.stringValue = note
        count.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, count.stringValue == note else { return }
            count.stringValue = previous
            count.textColor = .secondaryLabelColor
        }
    }

    @objc private func selectAllClicked() { onSelectAll?() }
    @objc private func copyClicked() { onCopy?() }
    @objc private func searchClicked() { onSearch?() }
    @objc private func closeClicked() { onClose?() }
}

/// The board's background: a click outside the tiles and the bar closes it.
@MainActor
private final class OutsideClickView: NSView {
    var onOutsideClick: (() -> Void)?
    /// The areas that aren't "outside".
    var outsideOf: () -> [CGRect] = { [] }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !outsideOf().contains(where: { $0.contains(point) }) { onOutsideClick?() }
    }
}
