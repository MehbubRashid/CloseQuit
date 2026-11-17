// Renders CloseQuit's app icon into the asset catalog.
// Usage (from the project folder): swift scripts/make-icon.swift

import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "CloseQuit/Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ top: UInt32, _ bottom: UInt32) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray,
               locations: [0, 1])!
}

/// Draws on a 1024×1024 design canvas, scaled to `pixels`.
func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // Body: the macOS icon grid's 824 pt rounded square.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    cg.addPath(body)
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    cg.drawLinearGradient(gradient(0xFDFDFE, 0xDCDFE5), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    // The red close button.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 268
    let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x8E1A12, 0.35))
    cg.addEllipse(in: circle)
    cg.setFillColor(color(0xFF5F57))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addEllipse(in: circle)
    cg.clip()
    cg.drawLinearGradient(gradient(0xFF7B70, 0xE5443A), start: CGPoint(x: 512, y: center.y + radius),
                          end: CGPoint(x: 512, y: center.y - radius), options: [])
    cg.restoreGState()

    cg.addEllipse(in: circle.insetBy(dx: 4, dy: 4))
    cg.setStrokeColor(color(0xB0281F, 0.45))
    cg.setLineWidth(8)
    cg.strokePath()

    // The × glyph.
    let arm: CGFloat = 108
    cg.setLineCap(.round)
    cg.setLineWidth(64)
    cg.setStrokeColor(color(0x6E0F09, 0.9))
    cg.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
    cg.addLine(to: CGPoint(x: center.x + arm, y: center.y + arm))
    cg.move(to: CGPoint(x: center.x - arm, y: center.y + arm))
    cg.addLine(to: CGPoint(x: center.x + arm, y: center.y - arm))
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images: [[String: String]] = []
for slot in slots {
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    try renderIcon(pixels: slot.points * slot.scale).write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(slot.points)x\(slot.points)", "scale": "\(slot.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))

let catalog = outputDirectory.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalog.path) {
    try #"{"info":{"author":"xcode","version":1}}"#.write(to: catalog, atomically: true, encoding: .utf8)
}
print("Wrote \(slots.count) icon sizes to \(outputDirectory.path)")
