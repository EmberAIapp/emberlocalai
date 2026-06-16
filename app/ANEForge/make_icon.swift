// Draws the Ember app icon (an ember on a dark rounded square) -> PNG at argv[1].
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// dark rounded-square background (macOS-style icon shape)
let inset: CGFloat = 76
let rect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
let path = CGPath(roundedRect: rect, cornerWidth: 200, cornerHeight: 200, transform: nil)
ctx.addPath(path)
ctx.setFillColor(NSColor(red: 0.043, green: 0.035, blue: 0.027, alpha: 1).cgColor)
ctx.fillPath()
ctx.addPath(path); ctx.clip()

// outer warm glow
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(red: 1, green: 0.48, blue: 0.24, alpha: 0.55).cgColor,
             NSColor(red: 0.91, green: 0.26, blue: 0.10, alpha: 0).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size/2, y: size/2), startRadius: 8,
                       endCenter: CGPoint(x: size/2, y: size/2), endRadius: size*0.42, options: [])

// incandescent ember core
let core = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(red: 1, green: 0.957, blue: 0.902, alpha: 1).cgColor,
             NSColor(red: 1, green: 0.69, blue: 0.38, alpha: 1).cgColor,
             NSColor(red: 0.91, green: 0.26, blue: 0.10, alpha: 1).cgColor] as CFArray,
    locations: [0, 0.38, 1])!
ctx.drawRadialGradient(core, startCenter: CGPoint(x: size*0.46, y: size*0.56), startRadius: 4,
                       endCenter: CGPoint(x: size/2, y: size/2), endRadius: size*0.24, options: [])

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("icon written: \(CommandLine.arguments[1])")
