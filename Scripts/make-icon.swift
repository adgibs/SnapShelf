// Draws the SnapShelf app icon and writes Support/AppIcon.icns.
// Run from the project root:  swift Scripts/make-icon.swift
import AppKit

/// Draws the icon on a 1024-point canvas.
func drawIcon() {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    // macOS icon grid: an 824-point rounded square centred on the canvas.
    let body = canvas.insetBy(dx: 100, dy: 100)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    // Soft drop shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.20, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.27, green: 0.42, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.72, blue: 0.92, alpha: 1),
    ])!.draw(in: body, angle: 65)

    // The shelf.
    let shelf = CGRect(x: body.minX + 96, y: body.minY + 190, width: body.width - 192, height: 34)
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: shelf, xRadius: 17, yRadius: 17).fill()
    NSColor.black.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: shelf.offsetBy(dx: 0, dy: -22).insetBy(dx: 26, dy: 8), xRadius: 9, yRadius: 9).fill()

    // Three captures standing on the shelf.
    func card(_ rect: CGRect, top: NSColor, bottom: NSColor, tilt: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.minY)
        transform.rotate(byDegrees: tilt)
        transform.translateX(by: -rect.midX, yBy: -rect.minY)
        transform.concat()
        let cardShadow = NSShadow()
        cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        cardShadow.shadowBlurRadius = 18
        cardShadow.shadowOffset = NSSize(width: 0, height: -6)
        cardShadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        transform.concat()
        let inner = rect.insetBy(dx: 16, dy: 16)
        NSBezierPath(roundedRect: inner, xRadius: 14, yRadius: 14).addClip()
        NSGradient(starting: bottom, ending: top)!.draw(in: inner, angle: 90)
        // A simple horizon so each card reads as a picture.
        NSColor.white.withAlphaComponent(0.35).setFill()
        let hill = NSBezierPath()
        hill.move(to: CGPoint(x: inner.minX, y: inner.minY))
        hill.line(to: CGPoint(x: inner.minX, y: inner.minY + inner.height * 0.28))
        hill.curve(
            to: CGPoint(x: inner.maxX, y: inner.minY + inner.height * 0.2),
            controlPoint1: CGPoint(x: inner.minX + inner.width * 0.35, y: inner.minY + inner.height * 0.55),
            controlPoint2: CGPoint(x: inner.minX + inner.width * 0.7, y: inner.minY + inner.height * 0.05)
        )
        hill.line(to: CGPoint(x: inner.maxX, y: inner.minY))
        hill.close()
        hill.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    let base = shelf.maxY - 2
    card(CGRect(x: body.minX + 130, y: base, width: 210, height: 280),
         top: NSColor(srgbRed: 1.0, green: 0.78, blue: 0.36, alpha: 1),
         bottom: NSColor(srgbRed: 0.98, green: 0.47, blue: 0.36, alpha: 1), tilt: 4)
    card(CGRect(x: body.minX + 484, y: base, width: 210, height: 250),
         top: NSColor(srgbRed: 0.56, green: 0.90, blue: 0.66, alpha: 1),
         bottom: NSColor(srgbRed: 0.16, green: 0.66, blue: 0.62, alpha: 1), tilt: -5)
    card(CGRect(x: body.minX + 292, y: base, width: 240, height: 360),
         top: NSColor(srgbRed: 0.80, green: 0.62, blue: 1.0, alpha: 1),
         bottom: NSColor(srgbRed: 0.45, green: 0.33, blue: 0.90, alpha: 1), tilt: 0)

    // Viewfinder corners in the top-right: this is a capture tool.
    let frame = CGRect(x: body.maxX - 250, y: body.maxY - 250, width: 150, height: 150)
    let marks = NSBezierPath()
    let arm: CGFloat = 46
    for (corner, dx, dy) in [
        (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
        (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
    ] {
        marks.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
        marks.line(to: corner)
        marks.line(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
    }
    marks.lineWidth = 20
    marks.lineCapStyle = .round
    marks.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    marks.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("SnapShelf-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let output = URL(fileURLWithPath: "Support/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
