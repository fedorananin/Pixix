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

    public static func font(for text: TextContent) -> CTFont {
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
        // An empty line still needs a height, so the box stays grabbable and the caret has somewhere to stand.
        let string = text.string.isEmpty || text.string.hasSuffix("\n") ? text.string + " " : text.string
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

    /// Size of the text box in the layer's own coordinates. The box starts at the origin.
    public static func textSize(_ text: TextContent) -> CGSize {
        // Neither a shadow nor a tail changes the box, so they share one measurement.
        var key = text
        key.shadow = nil
        key.tail = nil
        return sizeCache.size(for: key) {
            let glyphs = glyphSize(text)
            let padding = textPadding(text)
            return CGSize(width: glyphs.width + padding * 2, height: glyphs.height + padding * 2)
        }
    }

    /// Everything the text paints: its box, the shadow around it and the tail of a speech bubble.
    public static func textBounds(_ text: TextContent) -> CGRect {
        let reach = shadowReach(text.shadow)
        var bounds = CGRect(origin: .zero, size: textSize(text)).insetBy(dx: -reach, dy: -reach)
        if let tail = text.tail {
            bounds = bounds.union(CGRect(x: tail.x - reach - 2, y: tail.y - reach - 2, width: reach * 2 + 4, height: reach * 2 + 4))
        }
        return bounds.pixelAligned
    }

    /// The rounded box behind the text, with a tail when the text is a speech bubble. Text box coordinates.
    static func bubblePath(_ text: TextContent) -> CGPath {
        let box = CGRect(origin: .zero, size: textSize(text))
        guard let tail = text.tail else {
            let radius = min(box.height * 0.15, 12)
            return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let radius = min(box.height * 0.3, box.width / 2, max(text.fontSize * 0.45, 4))
        let bubble = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let reach = tail - box.center
        guard !box.contains(tail), reach.length > 1 else { return bubble }
        let across = CGPoint(x: -reach.y, y: reach.x) * (min(box.width, box.height) * 0.32 / reach.length)
        let pointer = CGMutablePath()
        pointer.move(to: box.center + across)
        pointer.addLine(to: tail)
        pointer.addLine(to: box.center - across)
        pointer.closeSubpath()
        return bubble.union(pointer)
    }

    /// A drop shadow for everything drawn until the matching `endShadow`. `scale` is the context's pixel scale,
    /// because shadows are measured in the pixels of the bitmap and ignore the context's transform.
    private static func beginShadow(_ radius: Double?, scale: CGFloat, in context: CGContext) -> Bool {
        guard let radius, radius > 0 else { return false }
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -radius * 0.4 * scale), blur: radius * scale,
            color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6).cgColor
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        return true
    }

    private static func endShadow(in context: CGContext) {
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func image(for text: TextContent, scale: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        let size = textSize(text)
        let bounds = textBounds(text)
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= PixelBuffer.maxDimension, height <= PixelBuffer.maxDimension,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: PixelBuffer.bitmapInfo
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        let shadowed = beginShadow(text.shadow, scale: scale, in: context)
        if let background = text.background, background.alpha > 0 {
            context.saveGState()
            // Into the text box's own coordinates, which have a top-left origin.
            context.translateBy(x: -bounds.minX, y: bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(background.cgColor)
            context.addPath(bubblePath(text))
            context.fillPath()
            context.restoreGState()
        }
        let padding = textPadding(text)
        let frameRect = CGRect(
            x: padding - bounds.minX, y: bounds.maxY - size.height + padding, width: size.width - padding * 2,
            height: size.height - padding * 2
        )
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
        if shadowed { endShadow(in: context) }
        return context.makeImage()
    }

    /// Where the lines of a text sit inside its box, for drawing a caret and finding the character under a click.
    /// Positions are UTF-16 offsets into the string, and rectangles are in the text box's coordinates.
    public struct TextLayout {
        public struct Line {
            public let range: NSRange
            public let frame: CGRect
            let line: CTLine
        }

        public let lines: [Line]
        /// Length of the text in UTF-16 units.
        public let length: Int

        private func lineIndex(for position: Int) -> Int? {
            guard !lines.isEmpty else { return nil }
            return lines.lastIndex { $0.range.location <= position } ?? 0
        }

        private func offset(_ position: Int, in line: Line) -> CGFloat {
            let clamped = min(max(position, line.range.location), NSMaxRange(line.range))
            return line.frame.minX + CTLineGetOffsetForStringIndex(line.line, clamped, nil)
        }

        /// A thin rectangle where the insertion point stands.
        public func caret(at position: Int) -> CGRect {
            guard let index = lineIndex(for: min(max(position, 0), length)) else { return .zero }
            let line = lines[index]
            return CGRect(x: offset(position, in: line), y: line.frame.minY, width: 0, height: line.frame.height)
        }

        /// One rectangle per line that the range touches.
        public func rects(for range: NSRange) -> [CGRect] {
            guard range.length > 0 else { return [] }
            return lines.compactMap { line in
                let start = max(range.location, line.range.location), end = min(NSMaxRange(range), NSMaxRange(line.range))
                guard start < end else { return nil }
                let x0 = offset(start, in: line), x1 = offset(end, in: line)
                return CGRect(x: min(x0, x1), y: line.frame.minY, width: max(abs(x1 - x0), 3), height: line.frame.height)
            }
        }

        /// The position nearest to a point.
        public func position(at point: CGPoint) -> Int {
            guard let nearest = lines.min(by: {
                abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y)
            }) else { return 0 }
            let found = CTLineGetStringIndexForPosition(nearest.line, CGPoint(x: point.x - nearest.frame.minX, y: 0))
            // The end of a line is before its line break, not after it.
            let isLast = nearest.range.location == lines.last?.range.location
            let end = isLast ? length : NSMaxRange(nearest.range) - 1
            return min(max(found == kCFNotFound ? end : found, nearest.range.location), max(end, nearest.range.location))
        }
    }

    public static func layout(_ text: TextContent) -> TextLayout {
        let size = textSize(text)
        let padding = textPadding(text)
        let frameRect = CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, outline: false))
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let result = zip(lines, origins).map { line, origin -> TextLayout.Line in
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let range = CTLineGetStringRange(line)
            // Line origins count from the bottom of the frame; the box counts from its top.
            let baseline = size.height - (frameRect.minY + origin.y)
            return TextLayout.Line(
                range: NSRange(location: range.location, length: range.length),
                frame: CGRect(x: frameRect.minX + origin.x, y: baseline - ascent, width: width, height: ascent + descent),
                line: line
            )
        }
        return TextLayout(lines: result, length: (text.string as NSString).length)
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
        case .ellipse, .badge:
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

        if shape.kind == .badge {
            drawBadge(shape, in: context)
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

    /// A disc in the stroke color with the label in the middle, in whichever of black and white reads better.
    private static func drawBadge(_ shape: ShapeContent, in context: CGContext) {
        let box = shape.pointBounds
        context.setFillColor(shape.strokeColor.cgColor)
        context.fillEllipse(in: box)
        guard let label = shape.label, !label.isEmpty, min(box.width, box.height) >= 4 else { return }
        let color = shape.strokeColor
        let luminance = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
        let ink = luminance > 0.6 ? RGBAColor.black : RGBAColor.white
        // Longer labels get smaller letters, so "10" still fits the disc.
        let size = min(box.width, box.height) * (label.count <= 1 ? 0.58 : label.count == 2 ? 0.46 : 0.34)
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink.cgColor,
        ]))
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        // The context's y axis points down, which would draw glyphs upside down.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: box.midX - glyphs.midX, y: box.midY + glyphs.midY)
        CTLineDraw(line, context)
        context.restoreGState()
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
        let shadowed = beginShadow(shape.shadow, scale: scale, in: context)
        draw(shape, in: context)
        if shadowed { endShadow(in: context) }
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
