import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 512); transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 452, height: 452), xRadius: 110, yRadius: 110)
        NSGradient(starting: NSColor(calibratedRed: 0.70, green: 0.66, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.29, green: 0.34, blue: 0.76, alpha: 1))!.draw(in: tile, angle: -65)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let monitor = NSBezierPath(roundedRect: NSRect(x: 112, y: 181, width: 288, height: 203), xRadius: 22, yRadius: 22)
        monitor.lineWidth = 15; monitor.stroke()
        let base = NSBezierPath(); base.move(to: NSPoint(x: 256, y: 179)); base.line(to: NSPoint(x: 256, y: 139)); base.move(to: NSPoint(x: 206, y: 135)); base.line(to: NSPoint(x: 306, y: 135)); base.lineWidth = 16; base.lineCapStyle = .round; base.stroke()
        let wave = NSBezierPath(); wave.move(to: NSPoint(x: 147, y: 226)); wave.curve(to: NSPoint(x: 364, y: 277), controlPoint1: NSPoint(x: 215, y: 331), controlPoint2: NSPoint(x: 275, y: 192)); wave.lineWidth = 14; wave.lineCapStyle = .round; NSColor.white.withAlphaComponent(0.82).setStroke(); wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
