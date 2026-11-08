import AVFoundation
import AppKit
import PixSnapCore
import PixSnapRender
import UniformTypeIdentifiers

/// 图文教程: a recording's steps (each click, shortcut and ⌥⇧M mark; see `StepGuide`), each with
/// the frame just before it, the click circled and numbered (`GuideRenderer`). Titles come from
/// what was clicked ("点击“隐私与安全性”") and can be rewritten; a step can be dropped. The guide is
/// exported as one long image, or as Markdown with its pictures in a folder beside it.
@MainActor
final class GuideWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var open: [GuideWindow] = []

    /// `exportTo`: writes the long image and the Markdown there straight away (`--guide-export`).
    static func show(video: URL, exportTo folder: URL? = nil) {
        if let existing = open.first(where: { $0.video == video }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = GuideWindow(video: video)
        open.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.load(thenExportTo: folder)
    }

    private struct Item {
        var step: StepGuide.Step
        var picture: CGImage?
    }

    private let video: URL
    private let timeline: RecordingTimeline?
    private var items: [Item] = []
    private let table = NSTableView()
    private let preview = NSImageView()
    private let titleField = NSTextField(string: "")
    private let status = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []

    private init(video: URL) {
        self.video = video
        timeline = (try? Data(contentsOf: TimelineRecorder.url(forVideo: video))).flatMap { try? JSONDecoder().decode(RecordingTimeline.self, from: $0) }
        super.init(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "图文教程"
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentMinSize = CGSize(width: 860, height: 520)
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        titleField.stringValue = "操作步骤（\(formatter.string(from: Date()))）"
        contentView = makeContent()
    }

    override func close() {
        super.close()
        Self.open.removeAll { $0 === self }
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.placeholderString = "教程标题"
        let titleLabel = NSTextField(labelWithString: "标题")
        titleLabel.textColor = .secondaryLabelColor
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.isEnabled = false
            buttons.append(button)
            return button
        }
        let exportImage = button("导出长图…", #selector(exportLongImage))
        exportImage.keyEquivalent = "\r"
        let top = NSStackView(views: [titleLabel, titleField, NSView(), button("复制长图", #selector(copyLongImage)),
                                      button("导出 Markdown…", #selector(exportMarkdown)), exportImage])
        top.spacing = 8
        top.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        titleField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        top.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("step"))
        column.title = "步骤"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let remove = button("删掉这一步", #selector(removeStep))
        let hint = NSTextField(wrappingLabelWithString: "双击标题可以改写。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let sideBottom = NSStackView(views: [remove, hint])
        sideBottom.orientation = .vertical
        sideBottom.alignment = .leading
        sideBottom.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        sideBottom.translatesAutoresizingMaskIntoConstraints = false

        preview.imageScaling = .scaleProportionallyDown
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        [top, scroll, sideBottom, preview, status].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 320),
            scroll.bottomAnchor.constraint(equalTo: sideBottom.topAnchor),
            sideBottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sideBottom.widthAnchor.constraint(equalToConstant: 320),
            sideBottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            preview.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            preview.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        return content
    }

    // MARK: Steps

    private func load(thenExportTo folder: URL?) {
        guard let timeline else {
            status.stringValue = "这段录屏没有记录点击（更新到这一版之前录的），做不了图文教程。"
            return
        }
        let steps = StepGuide.steps(from: timeline)
        guard !steps.isEmpty else {
            status.stringValue = "录制时没有点击、快捷键或标记，没有可以做成步骤的地方。"
            return
        }
        items = steps.map { Item(step: $0, picture: nil) }
        table.reloadData()
        status.stringValue = "正在取每一步的画面…"
        let video = video
        Task {
            let asset = AVURLAsset(url: video)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            for (index, step) in steps.enumerated() {
                // Just before the click, so what was clicked shows as it was.
                let time = CMTime(seconds: max(0, step.t - 0.08), preferredTimescale: 600)
                guard let (frame, _) = try? await generator.image(at: time) else { continue }
                let radius = max(24, CGFloat(frame.width) / max(CGFloat(timeline.width), 1) * 30)
                items[index].picture = GuideRenderer.annotate(frame, number: index + 1, x: step.x, y: step.y, radius: radius) ?? frame
                if table.selectedRow == index || (table.selectedRow < 0 && index == 0) { showPreview() }
            }
            if table.selectedRow < 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
            buttons.forEach { $0.isEnabled = true }
            status.stringValue = "\(items.count) 步。选一步看大图。"
            if let folder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                writeLongImage(to: folder.appendingPathComponent("教程.png"))
                writeMarkdown(in: folder)
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let number = NSTextField(labelWithString: "\(row + 1)")
        number.font = .systemFont(ofSize: 12, weight: .bold)
        number.textColor = .white
        number.alignment = .center
        number.wantsLayer = true
        number.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        number.layer?.cornerRadius = 11
        let title = NSTextField(string: items[row].step.title)
        title.isBordered = false
        title.drawsBackground = false
        title.font = .systemFont(ofSize: 13)
        title.tag = row
        title.delegate = self
        title.lineBreakMode = .byTruncatingTail
        title.cell?.isScrollable = true
        let stack = NSStackView(views: [number, title])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = title
        NSLayoutConstraint.activate([
            number.widthAnchor.constraint(equalToConstant: 22), number.heightAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showPreview() }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, items.indices.contains(field.tag), field !== titleField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { items[field.tag].step.title = text }
    }

    private func showPreview() {
        let row = max(0, table.selectedRow)
        guard items.indices.contains(row), let picture = items[row].picture else { return }
        preview.image = NSImage(cgImage: picture, size: CGSize(width: picture.width, height: picture.height))
    }

    @objc private func removeStep() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        items.remove(at: row)
        table.reloadData()
        table.selectRowIndexes([min(row, items.count - 1)], byExtendingSelection: false)
        showPreview()
        status.stringValue = "\(items.count) 步。导出时序号会重新排。"
    }

    // MARK: Exporting

    private var guideTitle: String {
        let text = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "操作步骤" : text
    }

    /// Each step's picture, numbered in the order the steps are now.
    private func numberedPictures() async -> [(title: String, image: CGImage)] {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = .zero
        var result: [(String, CGImage)] = []
        for (index, item) in items.enumerated() {
            let time = CMTime(seconds: max(0, item.step.t - 0.08), preferredTimescale: 600)
            guard let (frame, _) = try? await generator.image(at: time) else { continue }
            let radius = max(24, CGFloat(frame.width) / max(CGFloat(timeline?.width ?? 1), 1) * 30)
            result.append((item.step.title, GuideRenderer.annotate(frame, number: index + 1, x: item.step.x, y: item.step.y, radius: radius) ?? frame))
        }
        return result
    }

    @objc private func copyLongImage() {
        Task {
            guard let image = GuideRenderer.longImage(title: guideTitle, steps: await numberedPictures()) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: CGSize(width: image.width / 2, height: image.height / 2))])
            status.stringValue = "已复制长图"
        }
    }

    @objc private func exportLongImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(guideTitle).png"
        panel.directoryURL = AppSettings.shared.saveFolder
        panel.beginSheetModal(for: self) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.writeLongImage(to: url)
            }
        }
    }

    @objc private func exportMarkdown() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "存到这里"
        panel.message = "选一个文件夹：会放进 \(guideTitle).md 和 images 文件夹"
        panel.directoryURL = AppSettings.shared.saveFolder
        panel.beginSheetModal(for: self) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let folder = panel.url else { return }
                self?.writeMarkdown(in: folder)
            }
        }
    }

    private func writeLongImage(to url: URL) {
        status.stringValue = "正在生成长图…"
        Task {
            guard let image = GuideRenderer.longImage(title: guideTitle, steps: await numberedPictures()),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                status.stringValue = "没能生成长图"
                return
            }
            do {
                try png.write(to: url)
                status.stringValue = "长图已存到“\(url.deletingLastPathComponent().lastPathComponent)”"
            } catch {
                status.stringValue = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func writeMarkdown(in folder: URL) {
        status.stringValue = "正在导出 Markdown…"
        Task {
            let pictures = await numberedPictures()
            let images = folder.appendingPathComponent("images", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
                for (index, picture) in pictures.enumerated() {
                    if let png = NSBitmapImageRep(cgImage: picture.image).representation(using: .png, properties: [:]) {
                        try png.write(to: images.appendingPathComponent("\(index + 1).png"))
                    }
                }
                let steps = items.map(\.step)
                try StepGuide.markdown(title: guideTitle, steps: steps).write(to: folder.appendingPathComponent("\(guideTitle).md"), atomically: true, encoding: .utf8)
                status.stringValue = "Markdown 已存到“\(folder.lastPathComponent)”"
            } catch {
                status.stringValue = "导出失败：\(error.localizedDescription)"
            }
        }
    }
}
