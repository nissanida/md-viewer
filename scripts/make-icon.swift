// Draws the app icon at 1024x1024: the Markdown mark (M and a down arrow) on a
// light rounded square, with an orange cursor for the terminal.
// Usage: swift scripts/make-icon.swift output.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded square on the standard macOS icon grid, with a soft shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.set()
NSColor.white.setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
           ending: NSColor(srgbRed: 0.925, green: 0.93, blue: 0.94, alpha: 1))!.draw(in: tilePath, angle: -90)
NSColor.black.withAlphaComponent(0.08).setStroke()
tilePath.lineWidth = 2
tilePath.stroke()

// The Markdown mark (after the public-domain logo by Dustin Curtis), in SVG
// coordinates: x 30...185, y 30...98, y pointing down.
let ink = NSColor(srgbRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)
let scale: CGFloat = 3.5
let center = NSPoint(x: 512, y: 540)
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: center.x + (x - 107.5) * scale, y: center.y + (64 - y) * scale)
}
func shape(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: point(points[0].0, points[0].1))
    for p in points.dropFirst() { path.line(to: point(p.0, p.1)) }
    path.close()
    path.lineJoinStyle = .round
    return path
}
let letterM = shape([(30, 98), (30, 30), (50, 30), (70, 55), (90, 30), (110, 30), (110, 98), (90, 98), (90, 59), (70, 84), (50, 59), (50, 98)])
let arrow = shape([(155, 98), (125, 65), (145, 65), (145, 30), (165, 30), (165, 65), (185, 65)])
ink.setFill()
letterM.fill()
arrow.fill()

// A terminal cursor in Claude's orange.
let cursor = NSRect(x: point(125, 0).x, y: point(0, 118).y, width: 60 * scale, height: 9 * scale)
NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
NSBezierPath(roundedRect: cursor, xRadius: 10, yRadius: 10).fill()

image.unlockFocus()

let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
