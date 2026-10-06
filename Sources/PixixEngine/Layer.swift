import CoreGraphics
import Foundation
import PixixCodec

public typealias LayerID = UUID

public enum BlendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight
    case difference, exclusion, additive, hue, saturation, color, luminosity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .darken: "Darken"
        case .lighten: "Lighten"
        case .colorDodge: "Color Dodge"
        case .colorBurn: "Color Burn"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .additive: "Additive"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    var filterName: String {
        switch self {
        case .normal: "CISourceOverCompositing"
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .additive: "CILinearDodgeBlendMode"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        }
    }
}

public enum TextAlignment: String, Codable, Sendable, CaseIterable {
    case left, center, right
}

/// Editable text. It is drawn fresh on every change and never stored as pixels.
public struct TextContent: Codable, Sendable, Hashable {
    public var string = "Text"
    public var fontName = "Helvetica Neue"
    public var fontSize = 64.0
    public var isBold = false
    public var isItalic = false
    public var alignment = TextAlignment.left
    public var color = RGBAColor.white
    /// Outline drawn outside the glyphs, in pixels. Zero disables it.
    public var outlineWidth = 0.0
    public var outlineColor = RGBAColor.black
    public var background: RGBAColor?

    public init() {}
}

public enum ShapeKind: String, Codable, Sendable, CaseIterable {
    case line, arrow, rectangle, ellipse, freehand, highlighter
}

/// A vector shape. Lines and arrows use two points; rectangles and ellipses use
/// the corner points of their box; freehand strokes use every sampled point.
public struct ShapeContent: Codable, Sendable, Hashable {
    public var kind: ShapeKind
    public var points: [CGPoint]
    public var strokeColor = RGBAColor(red: 1, green: 0.23, blue: 0.19)
    public var strokeWidth = 6.0
    public var fillColor: RGBAColor?
    public var cornerRadius = 0.0

    public init(kind: ShapeKind, points: [CGPoint]) {
        self.kind = kind
        self.points = points
    }

    /// The box the points span, before stroke width is added.
    public var pointBounds: CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() {
            rect = rect.union(CGRect(origin: point, size: .zero))
        }
        return rect
    }

    /// How far paint reaches outside `pointBounds`.
    public var outset: CGFloat {
        switch kind {
        case .arrow: max(strokeWidth * 2.5, 10)
        default: strokeWidth / 2 + 1
        }
    }
}

public enum RegionEffect: String, Codable, Sendable, CaseIterable {
    case blur, pixelate
}

/// A movable area that blurs or pixelates everything underneath it.
public struct EffectRegion: Codable, Sendable, Hashable {
    public var effect: RegionEffect
    public var size: CGSize
    /// Blur radius or pixel cell size, in document pixels.
    public var amount = 16.0
    public var isEllipse = false

    public init(effect: RegionEffect, size: CGSize) {
        self.effect = effect
        self.size = size
    }
}

public enum LayerContent {
    case raster(PixelBuffer)
    case text(TextContent)
    case shape(ShapeContent)
    case effect(EffectRegion)
}

/// One layer of a document. A value type: copies share pixel storage, which is what makes
/// whole-document undo snapshots cheap.
public struct Layer: Identifiable {
    public var id = LayerID()
    public var name: String
    public var content: LayerContent
    public var isVisible = true
    public var isLocked = false
    /// 0...1
    public var opacity = 1.0
    public var blendMode = BlendMode.normal
    /// Maps the layer's own coordinates to document coordinates.
    public var transform = CGAffineTransform.identity
    public var adjustments = Adjustments()
    public var filter = PhotoFilter.none

    public init(name: String, content: LayerContent) {
        self.name = name
        self.content = content
    }

    public var isRaster: Bool {
        if case .raster = content { return true }
        return false
    }

    public var buffer: PixelBuffer? {
        if case .raster(let buffer) = content { return buffer }
        return nil
    }

    public var text: TextContent? {
        if case .text(let text) = content { return text }
        return nil
    }

    public var shape: ShapeContent? {
        if case .shape(let shape) = content { return shape }
        return nil
    }

    public var effectRegion: EffectRegion? {
        if case .effect(let region) = content { return region }
        return nil
    }

    public var kindSymbol: String {
        switch content {
        case .raster: "photo"
        case .text: "textformat"
        case .shape(let shape):
            switch shape.kind {
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .freehand: "scribble"
            case .highlighter: "highlighter"
            }
        case .effect(let region): region.effect == .blur ? "drop" : "square.grid.3x3"
        }
    }

    /// The layer's box in its own coordinates.
    public var localBounds: CGRect {
        switch content {
        case .raster(let buffer): buffer.bounds
        case .text(let text): CGRect(origin: .zero, size: ObjectRenderer.textSize(text))
        case .shape(let shape): shape.pointBounds.insetBy(dx: -shape.outset, dy: -shape.outset)
        case .effect(let region): CGRect(origin: .zero, size: region.size)
        }
    }

    /// The four corners of the layer in document coordinates: top-left, top-right, bottom-right, bottom-left.
    public var corners: [CGPoint] {
        let box = localBounds
        return [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
        ].map { $0.applying(transform) }
    }

    /// The axis-aligned box around the layer in document coordinates.
    public var documentBounds: CGRect { localBounds.applying(transform) }

    public func contains(documentPoint point: CGPoint) -> Bool {
        guard abs(transform.a * transform.d - transform.b * transform.c) > 1e-9 else { return false }
        let local = point.applying(transform.inverted())
        return localBounds.insetBy(dx: -2, dy: -2).contains(local)
    }

    /// Resizes the layer about a point given in its own coordinates.
    /// Shapes and regions change their geometry, so stroke widths stay put; everything else is scaled.
    public mutating func scale(x sx: CGFloat, y sy: CGFloat, aboutLocal anchor: CGPoint) {
        switch content {
        case .effect(var region):
            region.size = CGSize(width: max(region.size.width * abs(sx), 2), height: max(region.size.height * abs(sy), 2))
            content = .effect(region)
            // The box grows from its origin, so shift it to keep the anchor still.
            let shift = CGAffineTransform(translationX: anchor.x - anchor.x * abs(sx), y: anchor.y - anchor.y * abs(sy))
            transform = shift.concatenating(transform)
        case .shape(var shape) where shape.kind == .rectangle || shape.kind == .ellipse:
            let stretch = CGAffineTransform.scale(x: abs(sx), y: abs(sy), about: anchor)
            shape.points = shape.points.map { $0.applying(stretch) }
            content = .shape(shape)
        case .text(var text):
            let before = localBounds.size
            let factor = max(abs(sx), abs(sy)) == 1 ? min(abs(sx), abs(sy)) : max(abs(sx), abs(sy))
            text.fontSize = min(max(text.fontSize * factor, 4), 2000)
            content = .text(text)
            let after = localBounds.size
            guard before.width > 0, before.height > 0 else { return }
            // Text reflows, so keep the anchor's relative position in the box rather than its coordinates.
            let relative = CGPoint(x: anchor.x / before.width, y: anchor.y / before.height)
            let shift = CGAffineTransform(
                translationX: anchor.x - relative.x * after.width, y: anchor.y - relative.y * after.height
            )
            transform = shift.concatenating(transform)
        default:
            transform = CGAffineTransform.scale(x: sx, y: sy, about: anchor).concatenating(transform)
        }
    }
}
