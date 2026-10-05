import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let rect = NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.43, green: 0.25, blue: 0.84, alpha: 1), ending: NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.43, alpha: 1))!.draw(in: shape, angle: 60)
    let path = NSBezierPath(); path.lineWidth = s * 0.09; path.lineCapStyle = .round
    path.move(to: NSPoint(x: s * 0.34, y: s * 0.32)); path.line(to: NSPoint(x: s * 0.66, y: s * 0.68))
    path.move(to: NSPoint(x: s * 0.34, y: s * 0.68)); path.line(to: NSPoint(x: s * 0.66, y: s * 0.32))
    NSColor.white.setStroke(); path.stroke(); image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = rep.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { let half = size / 2; try data.write(to: directory.appendingPathComponent("icon_\(half)x\(half)@2x.png")) }
}
