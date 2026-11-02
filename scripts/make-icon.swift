// Draws PixSnap's app icon and writes Resources/AppIcon.icns: a blue rounded square with a
// viewfinder's corners, and inside it a photo pegged to a sagging rope, like the clothesline.
// Usage: swift scripts/make-icon.swift   (needs iconutil, which comes with Xcode's tools)
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("PixSnap.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// The icon at `size` pixels, drawn on a 1024 grid.
func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // The body: macOS's 824-point rounded square, with a soft shadow under it.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.33, green: 0.62, blue: 1.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0.20, green: 0.27, blue: 0.86, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Viewfinder corners.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let inset: CGFloat = 196, arm: CGFloat = 120
    let lo = inset, hi = 1024 - inset
    for (x, y, dx, dy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0), (lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0)] {
        ctx.move(to: CGPoint(x: x, y: y + dy * arm))
        ctx.addLine(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + dx * arm, y: y))
    }
    ctx.strokePath()

    // The rope, sagging a little, across the upper part.
    let rope = CGMutablePath()
    rope.move(to: CGPoint(x: 100, y: 640))
    rope.addQuadCurve(to: CGPoint(x: 924, y: 640), control: CGPoint(x: 512, y: 590))
    ctx.addPath(rope)
    ctx.setStrokeColor(NSColor(srgbRed: 0.96, green: 0.88, blue: 0.72, alpha: 1).cgColor)
    ctx.setLineWidth(14)
    ctx.strokePath()

    // The photo hanging from it, tipped slightly, with a picture of hills and a sun.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 612)
    ctx.rotate(by: -0.06)
    let photo = CGRect(x: -170, y: -300, width: 340, height: 280)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: photo, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    let picture = photo.insetBy(dx: 22, dy: 22)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: picture, cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 1.0, green: 0.80, blue: 0.55, alpha: 1).cgColor,
        NSColor(srgbRed: 1.0, green: 0.58, blue: 0.48, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: picture.maxY), end: CGPoint(x: 0, y: picture.minY), options: [])
    ctx.setFillColor(NSColor(srgbRed: 1, green: 0.97, blue: 0.85, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: 38, y: -110, width: 70, height: 70))
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: picture.minX, y: picture.minY))
    hills.addLine(to: CGPoint(x: picture.minX, y: -200))
    hills.addQuadCurve(to: CGPoint(x: 10, y: -190), control: CGPoint(x: -90, y: -110))
    hills.addQuadCurve(to: CGPoint(x: picture.maxX, y: -175), control: CGPoint(x: 90, y: -130))
    hills.addLine(to: CGPoint(x: picture.maxX, y: picture.minY))
    hills.closeSubpath()
    ctx.addPath(hills)
    ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.45, blue: 0.62, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // The wooden peg holding it to the rope.
    let peg = CGRect(x: -24, y: -60, width: 48, height: 110)
    ctx.addPath(CGPath(roundedRect: peg, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(NSColor(srgbRed: 0.86, green: 0.62, blue: 0.36, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.setStrokeColor(NSColor(srgbRed: 0.62, green: 0.40, blue: 0.20, alpha: 1).cgColor)
    ctx.setLineWidth(6)
    ctx.move(to: CGPoint(x: 0, y: -50))
    ctx.addLine(to: CGPoint(x: 0, y: 40))
    ctx.strokePath()
    ctx.setFillColor(NSColor(srgbRed: 0.75, green: 0.77, blue: 0.80, alpha: 1).cgColor)
    ctx.fill(CGRect(x: -28, y: 0, width: 56, height: 14))
    ctx.restoreGState()

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try draw(size: 1024).write(to: root.appendingPathComponent("build/AppIcon-preview.png"))
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
