import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func draw(_ size: Int) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.47, blue: 0.94, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.28, blue: 0.72, alpha: 1))!.draw(in: background, angle: -45)
    NSColor.white.setFill()
    let book = NSBezierPath()
    book.move(to: NSPoint(x: 218, y: 732)); book.curve(to: NSPoint(x: 502, y: 694), controlPoint1: NSPoint(x: 365, y: 774), controlPoint2: NSPoint(x: 430, y: 740))
    book.line(to: NSPoint(x: 502, y: 296)); book.curve(to: NSPoint(x: 218, y: 334), controlPoint1: NSPoint(x: 365, y: 376), controlPoint2: NSPoint(x: 300, y: 360)); book.close()
    book.move(to: NSPoint(x: 522, y: 694)); book.curve(to: NSPoint(x: 806, y: 732), controlPoint1: NSPoint(x: 659, y: 774), controlPoint2: NSPoint(x: 720, y: 750))
    book.line(to: NSPoint(x: 806, y: 334)); book.curve(to: NSPoint(x: 522, y: 296), controlPoint1: NSPoint(x: 659, y: 376), controlPoint2: NSPoint(x: 600, y: 340)); book.close(); book.fill()
    NSColor(srgbRed: 0.65, green: 0.78, blue: 1, alpha: 1).setStroke()
    for y in [634, 554, 474] {
        let line = NSBezierPath(); line.move(to: NSPoint(x: 278, y: y)); line.line(to: NSPoint(x: 433, y: y - 18)); line.lineWidth = 24; line.lineCapStyle = .round; line.stroke()
    }
    let seal = NSBezierPath(ovalIn: NSRect(x: 567, y: 215, width: 310, height: 310))
    NSColor(srgbRed: 0.06, green: 0.23, blue: 0.58, alpha: 1).setFill(); seal.fill()
    NSColor.white.setStroke(); seal.lineWidth = 20; seal.stroke()
    let tick = NSBezierPath(); tick.move(to: NSPoint(x: 651, y: 371)); tick.line(to: NSPoint(x: 700, y: 323)); tick.line(to: NSPoint(x: 795, y: 420)); tick.lineWidth = 32; tick.lineCapStyle = .round; tick.lineJoinStyle = .round; tick.stroke()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
    let points = size == 1024 ? 512 : size
    let name = size == 1024 ? "icon_512x512@2x.png" : "icon_\(points)x\(points).png"
    try png.write(to: output.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512, 1024] { try draw(size) }
