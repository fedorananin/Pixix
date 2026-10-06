// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift <output.icns> <scratch-folder>
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns> <scratch-folder>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let iconset = URL(fileURLWithPath: arguments[2]).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

func draw(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let unit = CGFloat(size) / 1024
    context.scaleBy(x: unit, y: unit)

    // The rounded square, inset the way macOS icons are.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.3))
    context.addPath(platePath)
    context.setFillColor(color(0.16, 0.2, 0.5))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let sky = CGGradient(
        colorsSpace: nil, colors: [color(0.24, 0.33, 0.95), color(0.55, 0.3, 0.92), color(1, 0.55, 0.45)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Sun.
    context.setFillColor(color(1, 0.93, 0.7))
    context.fillEllipse(in: CGRect(x: 610, y: 560, width: 150, height: 150))

    // Two ranges of hills.
    context.setFillColor(color(0.13, 0.17, 0.42, 0.75))
    context.move(to: CGPoint(x: 100, y: 100))
    context.addLine(to: CGPoint(x: 100, y: 420))
    context.addLine(to: CGPoint(x: 330, y: 640))
    context.addLine(to: CGPoint(x: 560, y: 380))
    context.addLine(to: CGPoint(x: 700, y: 500))
    context.addLine(to: CGPoint(x: 924, y: 300))
    context.addLine(to: CGPoint(x: 924, y: 100))
    context.closePath()
    context.fillPath()
    context.setFillColor(color(0.07, 0.09, 0.27, 0.9))
    context.move(to: CGPoint(x: 100, y: 100))
    context.addLine(to: CGPoint(x: 100, y: 260))
    context.addLine(to: CGPoint(x: 400, y: 430))
    context.addLine(to: CGPoint(x: 640, y: 250))
    context.addLine(to: CGPoint(x: 924, y: 400))
    context.addLine(to: CGPoint(x: 924, y: 100))
    context.closePath()
    context.fillPath()

    // Crop marks in two corners hint at editing.
    context.setStrokeColor(color(1, 1, 1, 0.92))
    context.setLineWidth(34)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 230, y: 660))
    context.addLine(to: CGPoint(x: 230, y: 794))
    context.addLine(to: CGPoint(x: 364, y: 794))
    context.move(to: CGPoint(x: 660, y: 230))
    context.addLine(to: CGPoint(x: 794, y: 230))
    context.addLine(to: CGPoint(x: 794, y: 364))
    context.strokePath()
    context.restoreGState()
    return context.makeImage()!
}

func write(_ image: CGImage, _ name: String) throws {
    let url = iconset.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for points in [16, 32, 128, 256, 512] {
    try write(draw(size: points), "icon_\(points)x\(points).png")
    try write(draw(size: points * 2), "icon_\(points)x\(points)@2x.png")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
