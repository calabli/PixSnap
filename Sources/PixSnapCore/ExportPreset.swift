import CoreGraphics
import Foundation

/// How 精修 writes the finished video: as sharp as recorded, at 1080p, small enough to send in
/// WeChat (≤ 25 MB, lowering the size when the bit rate gets too thin to stay readable), or as a GIF.
public enum ExportPreset: String, CaseIterable, Sendable {
    case original, hd1080, wechat, gif

    public var title: String {
        switch self {
        case .original: "清晰（原尺寸）"
        case .hd1080: "1080p"
        case .wechat: "发微信（25 MB 内）"
        case .gif: "GIF 动图"
        }
    }

    public var fileExtension: String { self == .gif ? "gif" : "mp4" }

    /// The most a WeChat video may weigh, with some room left.
    public static let wechatBytes = 24_000_000.0
    public static let audioBitRate = 128_000.0

    /// The picture's size and the video's bit rate (bits a second) for a finished video `size`
    /// pixels and `duration` seconds long. Sizes are even, as H.264 needs.
    public func settings(size: CGSize, duration: Double) -> (size: CGSize, bitRate: Double) {
        func fit(_ longSide: CGFloat) -> CGSize {
            let scale = min(1, longSide / max(size.width, size.height, 1))
            return CGSize(width: max(2, (size.width * scale / 2).rounded() * 2), height: max(2, (size.height * scale / 2).rounded() * 2))
        }
        // About 0.13 bits a pixel at 30 frames a second: text stays crisp.
        func sharp(_ size: CGSize) -> Double { Double(size.width * size.height) * 4 }
        switch self {
        case .original:
            let out = fit(.greatestFiniteMagnitude)
            return (out, sharp(out))
        case .hd1080:
            let out = fit(1920)
            return (out, min(sharp(out), 10_000_000))
        case .gif:
            let out = fit(800)
            return (out, sharp(out))
        case .wechat:
            let budget = Self.wechatBytes * 8 / max(duration, 0.5) - Self.audioBitRate
            let longSide: CGFloat = budget >= 3_000_000 ? 1920 : budget >= 1_400_000 ? 1280 : 960
            let out = fit(longSide)
            return (out, max(250_000, min(budget, sharp(out), 8_000_000)))
        }
    }
}
