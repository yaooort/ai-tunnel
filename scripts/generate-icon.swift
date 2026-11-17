#!/usr/bin/swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func ring(center: NSPoint, color: NSColor) {
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: 42)
    NSGraphicsContext.saveGraphicsState()
    transform.concat()
    let outline = NSBezierPath(roundedRect: NSRect(x: -115, y: -175, width: 230, height: 350),
                               xRadius: 115, yRadius: 115)
    outline.lineWidth = 48
    color.setStroke()
    outline.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func render(size: Int) throws -> Data {
    // Explicit pixels keep iconset sizes correct on both Retina and other displays.
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888),
                            xRadius: 205, yRadius: 205)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor(calibratedRed: 0.055, green: 0.105, blue: 0.185, alpha: 1).setFill()
    tile.fill()
    NSShadow().set()
    NSGradient(starting: NSColor(calibratedRed: 0.075, green: 0.17, blue: 0.29, alpha: 1),
               ending: NSColor(calibratedRed: 0.025, green: 0.07, blue: 0.14, alpha: 1))!
        .draw(in: tile, angle: -45)
    ring(center: NSPoint(x: 427, y: 421),
         color: NSColor(calibratedRed: 0.18, green: 0.71, blue: 1, alpha: 1))
    ring(center: NSPoint(x: 597, y: 603),
         color: NSColor(calibratedRed: 0.15, green: 0.90, blue: 0.72, alpha: 1))
    let bridge = NSBezierPath()
    bridge.move(to: NSPoint(x: 462, y: 461))
    bridge.line(to: NSPoint(x: 562, y: 564))
    bridge.lineWidth = 47
    bridge.lineCapStyle = .round
    NSColor(calibratedRed: 0.65, green: 0.97, blue: 0.97, alpha: 1).setStroke()
    bridge.stroke()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
