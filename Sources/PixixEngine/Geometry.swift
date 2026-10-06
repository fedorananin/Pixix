import CoreGraphics
import Foundation

// Document space has a top-left origin with y pointing down, like the screen and like every image file.
// Core Graphics and Core Image point y up; the helpers here are where the two meet.

extension CGRect {
    /// The smallest whole-pixel rectangle containing this one.
    public var pixelAligned: CGRect {
        guard !isNull, !isInfinite else { return self }
        let x0 = minX.rounded(.down), y0 = minY.rounded(.down)
        return CGRect(x: x0, y: y0, width: maxX.rounded(.up) - x0, height: maxY.rounded(.up) - y0)
    }

    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    public init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Mirrors a rectangle between y-down and y-up coordinates of a space with the given height.
    func flipped(height: CGFloat) -> CGRect {
        CGRect(x: minX, y: height - maxY, width: width, height: self.height)
    }
}

extension CGPoint {
    public static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    public static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    public var length: CGFloat { hypot(x, y) }
    public func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

extension CGAffineTransform {
    /// Average scale factor of the transform.
    public var scaleMagnitude: CGFloat { sqrt(abs(a * d - b * c)) }

    /// Mirrors y within a space of the given height. It is its own inverse.
    static func flipY(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    public var isIdentityOrClose: Bool {
        abs(a - 1) < 1e-6 && abs(d - 1) < 1e-6 && abs(b) < 1e-6 && abs(c) < 1e-6 && abs(tx) < 1e-6 && abs(ty) < 1e-6
    }

    /// Scales about a fixed point.
    public static func scale(x: CGFloat, y: CGFloat, about anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: x, y: y))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }

    /// Rotates about a fixed point. Positive angles turn clockwise on screen, because y points down.
    public static func rotation(_ angle: CGFloat, about anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }
}

extension CGContext {
    /// Draws an image the right way up in a context whose y axis points down.
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }

    /// Clips to a grayscale mask in a context whose y axis points down. White lets paint through.
    func clipUpright(to rect: CGRect, mask: CGImage) {
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY)
        concatenate(flip)
        clip(to: rect, mask: mask)
        concatenate(flip)
    }
}
