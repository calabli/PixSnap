import AppKit
import PixSnapCore
import SwiftUI

/// Settings › 晾衣架: rope thickness, color and material, with a live sample rope.
struct RopeStyleSection: View {
    @Binding var style: RopeStyle

    var body: some View {
        Section("晾衣架") {
            RopePreview(style: style)
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help("左边是浅色背景，右边是深色背景")

            Picker("粗细", selection: $style.thickness) {
                ForEach(RopeStyle.Thickness.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("材质", selection: $style.material) {
                ForEach(RopeStyle.Material.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            LabeledContent("颜色") {
                HStack(spacing: 8) {
                    ForEach(RopeStyle.presetColors, id: \.color.hex) { preset in
                        Button { style.color = preset.color } label: {
                            Circle()
                                .fill(Color(nsColor: preset.color.nsColor))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                                .padding(2)
                                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: style.color == preset.color ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                    ColorPicker("自定义颜色", selection: Binding(
                        get: { Color(nsColor: style.color.nsColor) },
                        set: { style.color = PixelColor(NSColor($0)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("自定义颜色")
                }
            }

            HStack {
                Text("下次打开晾衣架时生效。").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") { style = .default }
                    .disabled(style == .default)
            }
        }
    }
}

/// One sagging rope over a light-to-dark background, drawn by the same view as the clothesline.
private struct RopePreview: NSViewRepresentable {
    let style: RopeStyle

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.rope.style = style
    }

    final class PreviewView: NSView {
        let rope = RopeView()
        private let background = CAGradientLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            background.colors = [NSColor(white: 0.92, alpha: 1).cgColor, NSColor(white: 0.15, alpha: 1).cgColor]
            background.startPoint = CGPoint(x: 0.3, y: 0.5)
            background.endPoint = CGPoint(x: 0.7, y: 0.5)
            layer?.addSublayer(background)
            addSubview(rope)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            background.frame = bounds
            rope.frame = bounds
            let y = bounds.height - 18
            rope.lines = [RopeView.Line(from: CGPoint(x: 12, y: y), to: CGPoint(x: bounds.width - 12, y: y), sag: 16)]
        }
    }
}
