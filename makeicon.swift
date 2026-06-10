import AppKit

// Draws a clean, Apple-style app icon: dark squircle with a "now playing" island.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let full = NSRect(x: 0, y: 0, width: size, height: size)

// Background squircle + vertical gradient.
let bg = NSBezierPath(roundedRect: full, xRadius: 230, yRadius: 230)
bg.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.17, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.03, alpha: 1),
])!.draw(in: full, angle: -90)

// The island pill.
let pw: CGFloat = 640, ph: CGFloat = 210
let pill = NSRect(x: (size - pw) / 2, y: (size - ph) / 2, width: pw, height: ph)
let pillPath = NSBezierPath(roundedRect: pill, xRadius: ph / 2, yRadius: ph / 2)
NSColor.black.setFill()
pillPath.fill()
NSColor(white: 1, alpha: 0.16).setStroke()
pillPath.lineWidth = 3
pillPath.stroke()

// Left lobe: album thumbnail (pink).
let ts: CGFloat = 118
let thumb = NSRect(x: pill.minX + 46, y: (size - ts) / 2, width: ts, height: ts)
NSColor(calibratedRed: 0.93, green: 0.29, blue: 0.5, alpha: 1).setFill()
NSBezierPath(roundedRect: thumb, xRadius: 30, yRadius: 30).fill()
// little music note hint
NSColor(white: 1, alpha: 0.9).setFill()
let noteStem = NSRect(x: thumb.midX + 12, y: thumb.midY - 18, width: 9, height: 54)
NSBezierPath(roundedRect: noteStem, xRadius: 4, yRadius: 4).fill()
NSBezierPath(ovalIn: NSRect(x: thumb.midX - 18, y: thumb.midY - 30, width: 34, height: 26)).fill()

// Right lobe: waveform bars.
let barColor = NSColor(calibratedRed: 0.93, green: 0.29, blue: 0.5, alpha: 1)
barColor.setFill()
let heights: [CGFloat] = [60, 104, 78, 120, 66]
var bx = pill.maxX - 46 - CGFloat(heights.count) * 26 + 6
for h in heights {
    let bar = NSRect(x: bx, y: (size - h) / 2, width: 16, height: h)
    NSBezierPath(roundedRect: bar, xRadius: 8, yRadius: 8).fill()
    bx += 26
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed\n".data(using: .utf8)!)
    exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/island_icon.png"
try? png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
