import AppKit
import PixSnapCore

/// Before a recording starts, beside the selected region: 普通 or 讲解, what to add, the
/// microphone (with a meter that moves as you speak) and the Mac's sound, a camera bubble, then
/// 开始录制 (↩) or 取消 (Esc). Everything is remembered for next time.
///
/// 讲解 is for explaining how to do something: it counts down 3 seconds, leaves the zooms, the
/// pointer and the keys to 精修 (which opens when it's done) instead of drawing them live, and can
/// open the step-by-step guide too.
@MainActor
final class RecordingSetupPanel: NSPanel {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    private let region: CGRect
    private let targetScreen: NSScreen
    private let mode = NSSegmentedControl(labels: ["普通", "讲解"], trackingMode: .selectOne, target: nil, action: nil)
    private let zoomBox = NSButton(checkboxWithTitle: "跟随放大", target: nil, action: nil)
    private let pointerBox = NSButton(checkboxWithTitle: "醒目鼠标", target: nil, action: nil)
    private let keysBox = NSButton(checkboxWithTitle: "显示按键", target: nil, action: nil)
    private let guideBox = NSButton(checkboxWithTitle: "录完生成图文教程", target: nil, action: nil)
    private let notificationsBox = NSButton(checkboxWithTitle: "不录通知横幅", target: nil, action: nil)
    private let cameraBox = NSButton(checkboxWithTitle: "摄像头小窗", target: nil, action: nil)
    private let microphoneBox = NSButton(checkboxWithTitle: "麦克风", target: nil, action: nil)
    private let microphonePopup = NSPopUpButton()
    private let meter = NSLevelIndicator()
    private let systemAudioBox = NSButton(checkboxWithTitle: "系统声音（提示音、视频）", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private var tutorialRows: NSView?
    private let microphoneMeter = MicrophoneMeter()
    private var microphones: [(id: String, name: String)] = []
    /// The camera bubble while it's on: it stays for the recording.
    private(set) var cameraBubble: CameraBubble?

    private static let width: CGFloat = 470

    init(region: CGRect, on screen: NSScreen) {
        self.region = region
        targetScreen = screen
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = makeContent()
        showSettings()
    }

    override var canBecomeKey: Bool { true }

    // MARK: Layout

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "录屏")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        mode.target = self
        mode.action = #selector(changed)
        mode.toolTip = "讲解：倒数 3 秒再录，录完直接打开精修，自动放大、鼠标和按键在那里加上"
        let header = NSStackView(views: [title, NSView(), mode])

        for box in [zoomBox, pointerBox, keysBox, guideBox, notificationsBox, cameraBox, microphoneBox, systemAudioBox] {
            box.target = self
            box.action = #selector(changed)
        }
        zoomBox.toolTip = "点到哪里，镜头就放大到哪里（在精修里可以逐段关掉）"
        pointerBox.toolTip = "鼠标周围加一圈光晕，点击时出现涟漪"
        keysBox.toolTip = "按下的快捷键写在画面下方，比如“⌘ Command + F”"
        guideBox.toolTip = "每次点击一步，配好图和标题，可以导出长图或 Markdown"
        notificationsBox.toolTip = "录制时弹出的通知不会出现在视频里"
        cameraBox.toolTip = "右下角一个圆形的摄像头画面，可以拖到别处"
        let tutorial = NSGridView(views: [[zoomBox, pointerBox], [keysBox, guideBox]])
        tutorial.columnSpacing = 18
        tutorial.rowSpacing = 8
        tutorialRows = tutorial
        let common = NSGridView(views: [[notificationsBox, cameraBox]])
        common.columnSpacing = 18
        common.column(at: 0).width = (Self.width - 40 - 18) / 2
        tutorial.column(at: 0).width = (Self.width - 40 - 18) / 2

        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneChosen)
        microphonePopup.controlSize = .small
        microphonePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meter.levelIndicatorStyle = .discreteCapacity
        meter.minValue = 0
        meter.maxValue = 10
        meter.warningValue = 8
        meter.criticalValue = 9.5
        meter.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let microphoneRow = NSStackView(views: [microphoneBox, microphonePopup, meter])
        microphoneRow.spacing = 8
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let start = NSButton(title: "开始录制", target: self, action: #selector(startClicked))
        start.keyEquivalent = "\r"
        start.bezelColor = .systemRed
        start.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)
        start.imagePosition = .imageLeading
        let buttons = NSStackView(views: [footer, NSView(), cancel, start])
        buttons.spacing = 8

        func separator() -> NSBox {
            let line = NSBox()
            line.boxType = .separator
            return line
        }
        let stack = NSStackView(views: [header, tutorial, common, separator(), microphoneRow, systemAudioBox, hint, separator(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, separator(), microphoneRow, buttons] { view.translatesAutoresizingMaskIntoConstraints = false }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        for view in stack.arrangedSubviews where view is NSBox || view === header || view === microphoneRow || view === buttons {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        return background
    }

    // MARK: Settings

    private func showSettings() {
        let settings = AppSettings.shared
        let style = StudioWindow.savedStyle()
        mode.selectedSegment = settings.recordsTutorial ? 1 : 0
        zoomBox.state = style.zooms ? .on : .off
        pointerBox.state = style.pointerHalo || style.clickEffects ? .on : .off
        keysBox.state = style.showsKeys ? .on : .off
        guideBox.state = settings.opensGuideAfterTutorial ? .on : .off
        notificationsBox.state = settings.hidesNotificationsInRecordings ? .on : .off
        cameraBox.state = settings.showsCameraBubble ? .on : .off
        systemAudioBox.state = settings.recordsSystemAudio ? .on : .off

        microphones = MicrophoneMeter.microphones
        microphonePopup.removeAllItems()
        microphonePopup.addItems(withTitles: microphones.isEmpty ? ["没有麦克风"] : microphones.map(\.name))
        if let id = settings.microphoneID, let index = microphones.firstIndex(where: { $0.id == id }) {
            microphonePopup.selectItem(at: index)
        }
        if #available(macOS 15, *) {
            microphoneBox.state = settings.recordsMicrophone && !microphones.isEmpty ? .on : .off
            microphoneBox.isEnabled = !microphones.isEmpty
        } else {
            microphoneBox.state = .off
            microphoneBox.isEnabled = false
            microphoneBox.toolTip = "录麦克风需要 macOS 15 或更新"
        }
        updateDependents()
    }

    /// What follows from the switches: the 讲解 rows, the microphone's meter, the camera.
    private func updateDependents() {
        let tutorial = mode.selectedSegment == 1
        tutorialRows?.isHidden = !tutorial
        microphonePopup.isEnabled = microphoneBox.state == .on
        let stop = AppSettings.shared.shortcut(for: .recording).displayString
        footer.stringValue = tutorial ? "3 秒后开始 · \(stop) 停止 · ⌥⇧M 标记一步" : "\(stop) 停止 · ⌥⇧M 标记一步"
        if microphoneBox.state == .on {
            hint.stringValue = systemAudioBox.state == .on ? "说话时绿条会跳。录完两路声音合成一条。" : "说话时绿条会跳。"
            Task { await listen() }
        } else {
            microphoneMeter.stop()
            meter.doubleValue = 0
            hint.stringValue = systemAudioBox.state == .on ? "录下 Mac 播放的声音，不录你说话。" : "不录声音。"
        }
        updateCamera()
        layoutAndPlace()
    }

    private func listen() async {
        microphoneMeter.onLevel = { [weak self] level in self?.meter.doubleValue = level * 10 }
        let id = microphones.indices.contains(microphonePopup.indexOfSelectedItem) ? microphones[microphonePopup.indexOfSelectedItem].id : nil
        if await !microphoneMeter.start(microphone: id) {
            hint.stringValue = "没有麦克风权限：在系统设置 › 隐私与安全性 › 麦克风里允许 PixSnap。"
        }
    }

    private func updateCamera() {
        if cameraBox.state == .on, cameraBubble == nil {
            let bubble = CameraBubble(in: region)
            cameraBubble = bubble
            Task {
                if await !bubble.start() {
                    bubble.close()
                    cameraBubble = nil
                    cameraBox.state = .off
                    AppSettings.shared.showsCameraBubble = false
                    hint.stringValue = "没有摄像头权限：在系统设置 › 隐私与安全性 › 摄像头里允许 PixSnap。"
                }
            }
        } else if cameraBox.state == .off, let bubble = cameraBubble {
            bubble.close()
            cameraBubble = nil
        }
    }

    @objc private func changed() {
        let settings = AppSettings.shared
        settings.recordsTutorial = mode.selectedSegment == 1
        settings.opensGuideAfterTutorial = guideBox.state == .on
        settings.hidesNotificationsInRecordings = notificationsBox.state == .on
        settings.showsCameraBubble = cameraBox.state == .on
        settings.recordsSystemAudio = systemAudioBox.state == .on
        if microphoneBox.isEnabled { settings.recordsMicrophone = microphoneBox.state == .on }
        var style = StudioWindow.savedStyle()
        style.zooms = zoomBox.state == .on
        style.pointerHalo = pointerBox.state == .on
        style.clickEffects = pointerBox.state == .on
        style.showsKeys = keysBox.state == .on
        StudioWindow.save(style)
        updateDependents()
    }

    @objc private func microphoneChosen() {
        let index = microphonePopup.indexOfSelectedItem
        AppSettings.shared.microphoneID = microphones.indices.contains(index) ? microphones[index].id : nil
        if microphoneBox.state == .on { Task { await listen() } }
    }

    // MARK: Showing

    /// Below the region, else above it, else inside it at the bottom.
    private func layoutAndPlace() {
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        let visible = targetScreen.visibleFrame
        let x = min(max(region.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let below = CGRect(x: x, y: region.minY - 14 - size.height, width: size.width, height: size.height)
        let above = CGRect(x: x, y: region.maxY + 14, width: size.width, height: size.height)
        let inside = CGRect(x: x, y: max(region.minY + 24, visible.minY + 8), width: size.width, height: size.height)
        // Keep where it was dragged once it's showing; only the height changes.
        if isVisible {
            setFrame(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
            return
        }
        setFrame([below, above].first { visible.contains($0) } ?? inside, display: true)
    }

    func show() {
        layoutAndPlace()
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// Closes the panel; the camera bubble is handed to whoever records.
    func finish() {
        microphoneMeter.stop()
        orderOut(nil)
    }

    @objc private func startClicked() { start() }

    func start() {
        finish()
        onStart?()
    }

    @objc private func cancelClicked() {
        finish()
        cameraBubble?.close()
        cameraBubble = nil
        onCancel?()
    }
}
