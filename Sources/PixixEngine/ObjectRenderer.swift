import CoreGraphics
import CoreText
import Foundation
import PixixCodec

/// Turns text and shapes into bitmaps. Results cover the layer's local bounds.
public enum ObjectRenderer {
    // MARK: Text

    private final class SizeCache: @unchecked Sendable {
        private var storage: [TextContent: CGSize] = [:]
        private let lock = NSLock()

        func size(for text: TextContent, compute: () -> CGSize) -> CGSize {
            lock.lock()
            defer { lock.unlock() }
            if let hit = storage[text] { return hit }
            if storage.count > 400 { storage.removeAll() }
            let size = compute()
            storage[text] = size
            return size
        }
    }

    private static let sizeCache = SizeCache()

    static func font(for text: TextContent) -> CTFont {
        let base = CTFontCreateWithName(text.fontName as CFString, max(text.fontSize, 1), nil)
        var traits: CTFontSymbolicTraits = []
        if text.isBold { traits.insert(.traitBold) }
        if text.isItalic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, [.traitBold, .traitItalic]) ?? base
    }

    /// Space left around the glyphs for outlines and overhanging strokes.
    static func textPadding(_ text: TextContent) -> CGFloat {
        (text.outlineWidth + max(4, text.fontSize * 0.08)).rounded(.up)
    }

    private static func attributed(_ text: TextContent, outline: Bool) -> NSAttributedString {
        var alignment: CTTextAlignment
        switch text.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(for: text),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        if outline {
            // A positive stroke width strokes without filling; the value is a percentage of the font size.
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                text.outlineWidth * 2 / max(text.fontSize, 1) * 100
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = text.outlineColor.cgColor
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = text.outlineColor.cgColor
        } else {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = text.color.cgColor
        }
        // An empty line still needs a height, so the box stays grabbable.
        let string = text.string.isEmpty ? " " : text.string
        return NSAttributedString(string: string, attributes: attributes)
    }

    private static func glyphSize(_ text: TextContent) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, outline: false))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil
        )
        return CGSize(width: size.width.rounded(.up) + 1, height: size.height.rounded(.up) + 1)
    }

    /// Size of the text box in the layer's own coordinates.
    public static func textSize(_ text: TextContent) -> CGSize {
        sizeCache.size(for: text) {
            let glyphs = glyphSize(text)
            let padding = textPadding(text)
            return CGSize(width: glyphs.width + padding * 2, height: glyphs.height + padding * 2)
        }
    }

    static func image(for text: TextContent, scale: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        let size = textSize(text)
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= PixelBuffer.maxDimension, height <= PixelBuffer.maxDimension,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: PixelBuffer.bitmapInfo
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        if let background = text.background, background.alpha > 0 {
            context.setFillColor(background.cgColor)
            let radius = min(size.height * 0.15, 12)
            context.addPath(CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            context.fillPath()
        }
        let padding = textPadding(text)
        let frameRect = CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
        let path = CGPath(rect: frameRect, transform: nil)
        func draw(outline: Bool) {
            let setter = CTFramesetterCreateWithAttributedString(attributed(text, outline: outline))
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        }
        if text.outlineWidth > 0 {
            context.setLineJoin(.round)
            draw(outline: true)
        }
        draw(outline: false)
        return context.makeImage()
    }

    // MARK: Shapes

    static func path(for shape: ShapeContent) -> CGPath {
        let path = CGMutablePath()
        switch shape.kind {
        case .line, .arrow:
            guard shape.points.count >= 2 else { break }
            path.move(to: shape.points[0])
            path.addLine(to: shape.points[1])
        case .rectangle:
            let box = shape.pointBounds
            let radius = min(shape.cornerRadius, min(box.width, box.height) / 2)
            if radius > 0 {
                path.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)
            } else {
                path.addRect(box)
            }
        case .ellipse:
            path.addEllipse(in: shape.pointBounds)
        case .freehand, .highlighter:
            guard let first = shape.points.first else { break }
            path.move(to: first)
            if shape.points.count == 1 {
                path.addLine(to: first)
            } else if shape.points.count == 2 {
                path.addLine(to: shape.points[1])
            } else {
                // Quadratic segments through midpoints hide the corners of the sampled polyline.
                for index in 1..<shape.points.count - 1 {
                    let current = shape.points[index], next = shape.points[index + 1]
                    path.addQuadCurve(to: CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2), control: current)
                }
                path.addLine(to: shape.points[shape.points.count - 1])
            }
        }
        return path
    }

    /// Draws a shape into a context that already uses the shape's coordinates.
    static func draw(_ shape: ShapeContent, in context: CGContext) {
        context.setLineWidth(shape.strokeWidth)
        context.setStrokeColor(shape.strokeColor.cgColor)
        context.setLineJoin(.round)
        context.setLineCap(shape.kind == .highlighter ? .butt : .round)

        if shape.kind == .arrow, shape.points.count >= 2 {
            let start = shape.points[0], end = shape.points[1]
            let length = start.distance(to: end)
            guard length > 0.5 else { return }
            let direction = (end - start) * (1 / length)
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let head = min(max(shape.strokeWidth * 4, 14), length)
            let base = end - direction * head
            context.move(to: start)
            // Stop the shaft inside the head so its round cap does not poke through the tip.
            context.addLine(to: end - direction * (head * 0.7))
            context.strokePath()
            context.setFillColor(shape.strokeColor.cgColor)
            context.move(to: end)
            context.addLine(to: base + normal * (head * 0.45))
            context.addLine(to: base - normal * (head * 0.45))
            context.closePath()
            context.fillPath()
            return
        }

        let path = path(for: shape)
        if let fill = shape.fillColor, fill.alpha > 0, shape.kind == .rectangle || shape.kind == .ellipse {
            context.addPath(path)
            context.setFillColor(fill.cgColor)
            context.fillPath()
        }
        if shape.strokeWidth > 0, shape.strokeColor.alpha > 0 {
            context.addPath(path)
            context.strokePath()
        }
    }

    /// Draws a shape into a context set up in document coordinates. For live previews while a shape is dragged out.
    public static func drawPreview(_ shape: ShapeContent, in context: CGContext) {
        draw(shape, in: context)
    }

    static func image(for shape: ShapeContent, scale: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        let bounds = shape.pointBounds.insetBy(dx: -shape.outset, dy: -shape.outset)
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= PixelBuffer.maxDimension, height <= PixelBuffer.maxDimension,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: PixelBuffer.bitmapInfo
              )
        else { return nil }
        // Top-left origin, then into the shape's own coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(shape, in: context)
        return context.makeImage()
    }

    /// An opaque ellipse on transparency, used to mask round effect regions.
    static func ellipseMask(size: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: PixelBuffer.bitmapInfo
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
