// Draws a sample landscape, for screenshots and for trying the app without a photo at hand.
// Usage: swift Scripts/make-sample.swift <output.jpg> [variant 0-3] [width] [height]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-sample.swift <output.jpg> [variant] [width] [height]\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let variant = arguments.count > 2 ? Int(arguments[2]) ?? 0 : 0
let width = arguments.count > 3 ? Int(arguments[3]) ?? 3000 : 3000
let height = arguments.count > 4 ? Int(arguments[4]) ?? 2000 : 2000

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Sky top, sky bottom, sun, far hills, near hills.
let palettes: [[CGColor]] = [
    [color(0.16, 0.25, 0.75), color(1, 0.62, 0.45), color(1, 0.95, 0.75), color(0.36, 0.3, 0.6), color(0.12, 0.13, 0.3)],
    [color(0.35, 0.65, 0.95), color(0.85, 0.95, 1), color(1, 1, 0.9), color(0.3, 0.55, 0.5), color(0.1, 0.3, 0.25)],
    [color(0.1, 0.08, 0.25), color(0.75, 0.3, 0.55), color(1, 0.8, 0.85), color(0.3, 0.15, 0.4), color(0.08, 0.05, 0.18)],
    [color(0.95, 0.6, 0.3), color(1, 0.9, 0.6), color(1, 1, 1), color(0.7, 0.4, 0.3), color(0.35, 0.18, 0.15)],
]
let palette = palettes[((variant % palettes.count) + palettes.count) % palettes.count]

let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
let w = CGFloat(width), h = CGFloat(height)

let sky = CGGradient(colorsSpace: space, colors: [palette[0], palette[1]] as CFArray, locations: [0, 1])!
context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.25), options: [.drawsAfterEndLocation])

// Sun with a soft glow.
let sun = CGPoint(x: w * (0.3 + 0.15 * CGFloat(variant % 3)), y: h * 0.62)
let glow = CGGradient(
    colorsSpace: space, colors: [palette[2], palette[2].copy(alpha: 0)!] as CFArray, locations: [0, 1]
)!
context.drawRadialGradient(glow, startCenter: sun, startRadius: h * 0.07, endCenter: sun, endRadius: h * 0.35, options: [])
context.setFillColor(palette[2])
context.fillEllipse(in: CGRect(x: sun.x - h * 0.075, y: sun.y - h * 0.075, width: h * 0.15, height: h * 0.15))

// Ridges made of summed sine waves, so every variant gets its own skyline.
func ridge(base: CGFloat, amplitude: CGFloat, seed: CGFloat, fill: CGColor) {
    context.move(to: CGPoint(x: 0, y: 0))
    var x: CGFloat = 0
    while x <= w {
        let t = x / w
        let y = base + amplitude * (sin(t * 5 + seed) * 0.5 + sin(t * 11 + seed * 2.3) * 0.3 + sin(t * 23 + seed * 0.7) * 0.2)
        context.addLine(to: CGPoint(x: x, y: h * y))
        x += 4
    }
    context.addLine(to: CGPoint(x: w, y: 0))
    context.closePath()
    context.setFillColor(fill)
    context.fillPath()
}
let seed = CGFloat(variant) * 1.7 + 0.4
ridge(base: 0.42, amplitude: 0.13, seed: seed, fill: palette[3].copy(alpha: 0.75)!)
ridge(base: 0.3, amplitude: 0.1, seed: seed + 2, fill: palette[3])
ridge(base: 0.17, amplitude: 0.07, seed: seed + 4, fill: palette[4])

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
