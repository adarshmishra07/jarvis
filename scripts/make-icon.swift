// Draws the app icon (the arc orb from the home page) as a 1024 px PNG. Run by scripts/make-icon.sh.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let red = NSColor(red: 0.95, green: 0.14, blue: 0.12, alpha: 1)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824 px rounded square centred in the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1).cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(shape); ctx.clip()
// A faint red glow behind the orb.
let c = CGPoint(x: size / 2, y: size / 2)
let glow = CGGradient(colorsSpace: nil, colors: [red.withAlphaComponent(0.28).cgColor, red.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 420, options: [])

func ring(_ r: CGFloat, _ width: CGFloat, _ dash: [CGFloat], _ rotation: CGFloat, _ alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: rotation)
    ctx.setStrokeColor(red.withAlphaComponent(alpha).cgColor); ctx.setLineWidth(width)
    ctx.setLineDash(phase: 0, lengths: dash)
    ctx.addArc(center: .zero, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false); ctx.strokePath()
    ctx.restoreGState()
}
let R: CGFloat = 330
ring(R, 6, [10, 26], 0, 0.75)
ring(R * 0.82, 14, [150, 50, 30, 50], 0.4, 0.95)
ring(R * 0.62, 5, [], 0, 0.5)
ring(R * 0.5, 20, [100, 62], -0.3, 1)
let core = CGGradient(colorsSpace: nil, colors: [NSColor.white.cgColor, red.withAlphaComponent(0.95).cgColor, red.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: R * 0.42, options: [])

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
