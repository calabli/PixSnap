import Foundation

/// How the clothesline ropes look: thickness, color and material.
public struct RopeStyle: Codable, Equatable, Sendable {
    public enum Thickness: String, Codable, CaseIterable, Sendable {
        case thin, medium, thick, extraThick

        /// Stroke width in points.
        public var width: Double {
            switch self {
            case .thin: 1.5
            case .medium: 2.5
            case .thick: 4
            case .extraThick: 6
            }
        }

        public var title: String {
            switch self {
            case .thin: "细"
            case .medium: "中"
            case .thick: "粗"
            case .extraThick: "特粗"
            }
        }
    }

    public enum Material: String, Codable, CaseIterable, Sendable {
        /// A smooth, even line.
        case cotton
        /// Twisted strands.
        case jute
        /// A shiny wire with a highlight along the top.
        case wire
        /// A string of little glowing bulbs.
        case lights

        public var title: String {
            switch self {
            case .cotton: "棉绳"
            case .jute: "麻绳"
            case .wire: "金属丝"
            case .lights: "彩灯串"
            }
        }
    }

    public var thickness: Thickness
    public var color: PixelColor
    public var material: Material

    public init(thickness: Thickness, color: PixelColor, material: Material) {
        self.thickness = thickness
        self.color = color
        self.material = material
    }

    public static let `default` = RopeStyle(thickness: .thin, color: RopeStyle.presetColors[0].color, material: .cotton)

    /// The swatches offered in settings; any other color can be picked too.
    public static let presetColors: [(name: String, color: PixelColor)] = [
        ("白色", PixelColor(red: 245, green: 245, blue: 245)),
        ("麻色", PixelColor(red: 196, green: 164, blue: 112)),
        ("棕色", PixelColor(red: 120, green: 78, blue: 46)),
        ("红色", PixelColor(red: 214, green: 58, blue: 52)),
        ("蓝色", PixelColor(red: 48, green: 120, blue: 214)),
        ("黑色", PixelColor(red: 30, green: 30, blue: 30)),
    ]

    /// Unknown or damaged fields fall back to the default instead of failing the whole style.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default
        thickness = (try? container.decode(Thickness.self, forKey: .thickness)) ?? fallback.thickness
        color = (try? container.decode(String.self, forKey: .color)).flatMap(PixelColor.init(hex:)) ?? fallback.color
        material = (try? container.decode(Material.self, forKey: .material)) ?? fallback.material
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(thickness, forKey: .thickness)
        try container.encode(color.hex, forKey: .color)
        try container.encode(material, forKey: .material)
    }

    private enum CodingKeys: String, CodingKey {
        case thickness, color, material
    }
}

extension PixelColor {
    /// Parses "#3A7BD5" or "3A7BD5"; nil for anything else.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }
}
