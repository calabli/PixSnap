import Foundation

/// A pixel position in an image, top-left origin.
public struct PixelPoint: Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// An 8-bit sRGB color picked from a screenshot.
public struct PixelColor: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#3A7BD5"
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// "58, 123, 213"
    public var rgb: String { "\(red), \(green), \(blue)" }
}
