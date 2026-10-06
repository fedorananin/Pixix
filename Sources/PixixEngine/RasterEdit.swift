import CoreGraphics
import Foundation
import PixixCodec

/// One in-place change to a raster layer's pixels: a brush stroke, a fill, a gradient.
///
/// Painting needs plain canvas-sized pixels. If the active layer is something else (text, a placed
/// image that has been moved or scaled, nothing at all), the edit quietly prepares one and folds
/// that into the same undo step.
@MainActor
public final class RasterEdit {
    let document: Document
    public let layerID: LayerID
    public let buffer: PixelBuffer
    /// The pixels as they were when the edit began.
    private let base: PixelBuffer
    private var dirty = CGRect.null
    /// Set when the layer list itself had to change to make painting possible.
    private let stateBefore: DocumentState?
    private var isFinished = false

    public init?(document: Document) {
        self.document = document
        let state = document.state
        let size = state.size
        if let index = document.activeIndex {
            let layer = state.layers[index]
            if layer.isLocked || !layer.isVisible { return nil }
            if layer.isAligned(to: size), let buffer = layer.buffer {
                self.buffer = buffer
                layerID = layer.id
                stateBefore = nil
                base = buffer.copy()
                return
            }
            if layer.isRaster {
                // Bake the layer's placement into canvas-sized pixels.
                guard let image = document.renderer.contentImage(layer, state: state, colorSpace: document.colorSpace, raw: true),
                      let flat = document.renderer.makeBuffer(image.cropped(to: document.bounds), size: size, colorSpace: document.colorSpace)
                else { return nil }
                var layers = state.layers
                layers[index].content = .raster(flat)
                layers[index].transform = .identity
                document.replaceLayers(layers, active: layer.id)
                buffer = flat
                layerID = layer.id
                stateBefore = state
                base = flat.copy()
                return
            }
        }
        // Text, shapes and regions are not painted on; the paint goes on a fresh layer above.
        guard let fresh = PixelBuffer(width: Int(size.width), height: Int(size.height), colorSpace: document.colorSpace) else { return nil }
        let layer = Layer(name: "Layer \(state.layers.filter(\.isRaster).count + 1)", content: .raster(fresh))
        var layers = state.layers
        layers.insert(layer, at: document.activeIndex.map { $0 + 1 } ?? layers.count)
        document.replaceLayers(layers, active: layer.id)
        buffer = fresh
        layerID = layer.id
        stateBefore = state
        base = fresh.copy()
    }

    /// The starting pixels as an image, for tools that need to read what was there.
    public func withBaseImage<T>(_ body: (CGImage) -> T) -> T {
        base.withUnsafeImage(body)
    }

    /// Draws into the layer inside `rect`. The context has a top-left origin.
    /// - Parameters:
    ///   - restoringBase: first puts back the starting pixels, so the body can redraw the whole effect from scratch.
    ///   - clipToSelection: keeps paint inside the document's selection.
    public func draw(in rect: CGRect, restoringBase: Bool = false, clipToSelection: Bool = true, _ body: (CGContext) -> Void) {
        let area = rect.pixelAligned.intersection(buffer.bounds)
        guard !area.isEmpty, !isFinished else { return }
        buffer.withContext { context in
            context.saveGState()
            context.clip(to: area)
            if restoringBase {
                context.saveGState()
                context.setBlendMode(.copy)
                base.withUnsafeImage { context.drawUpright($0, in: buffer.bounds) }
                context.restoreGState()
            }
            if clipToSelection, let selection = document.selection {
                context.clipUpright(to: buffer.bounds, mask: selection.image)
            }
            body(context)
            context.restoreGState()
        }
        dirty = dirty.union(area)
        document.notify(stateBefore == nil ? .pixels(area) : .everything)
    }

    /// Finishes the edit and records it as one undo step.
    public func commit(name: String) {
        guard !isFinished else { return }
        isFinished = true
        guard !dirty.isNull else {
            if let stateBefore { document.restore(stateBefore) }
            return
        }
        if let stateBefore {
            document.recordSwap(name: name, before: stateBefore)
            document.notify(.everything)
            return
        }
        let rect = dirty
        let buffer = self.buffer
        let old = Self.pack(base.bytes(in: rect)), new = Self.pack(buffer.bytes(in: rect))
        document.recordPixels(
            name: name, cost: old.count + new.count,
            undo: { [weak document] in
                buffer.setBytes(Self.unpack(old), in: rect)
                document?.notify(.pixels(rect))
            },
            redo: { [weak document] in
                buffer.setBytes(Self.unpack(new), in: rect)
                document?.notify(.pixels(rect))
            }
        )
    }

    /// Abandons the edit and puts the pixels back.
    public func cancel() {
        guard !isFinished else { return }
        isFinished = true
        if let stateBefore {
            document.restore(stateBefore)
        } else if !dirty.isNull {
            buffer.setBytes(base.bytes(in: dirty), in: dirty)
            document.notify(.pixels(dirty))
        }
    }

    private static func pack(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .lz4) as Data) ?? data
    }

    private static func unpack(_ data: Data) -> Data {
        (try? (data as NSData).decompressed(using: .lz4) as Data) ?? data
    }
}

public struct BrushSettings: Sendable {
    public enum Mode: Sendable {
        case paint
        case erase
        /// Copies pixels from a place offset from the brush.
        case clone(offset: CGPoint)
    }

    /// Diameter in pixels.
    public var size: CGFloat = 20
    /// 1 is a crisp edge, 0 fades all the way from the center.
    public var hardness: CGFloat = 0.8
    public var opacity: CGFloat = 1
    public var color = RGBAColor.black
    public var mode = Mode.paint
    /// Off for the pencil, which draws hard-edged pixels.
    public var antialiased = true

    public init() {}
}

/// A brush, pencil, eraser or clone stroke in progress.
@MainActor
public final class BrushStroke {
    private let edit: RasterEdit
    private let settings: BrushSettings
    private let width: Int
    private let height: Int
    /// Coverage of the whole stroke so far. Painting the stroke through this mask, instead of dab by dab,
    /// keeps a half-transparent stroke from darkening where it overlaps itself.
    private let mask: UnsafeMutableRawPointer
    private let maskContext: CGContext
    private var lastPoint: CGPoint?
    private var distanceToNextDab: CGFloat = 0
    private let dabGradient: CGGradient

    public init?(document: Document, settings: BrushSettings) {
        guard let edit = RasterEdit(document: document) else { return nil }
        self.edit = edit
        self.settings = settings
        width = edit.buffer.width
        height = edit.buffer.height
        guard let memory = calloc(width * height, 1),
              let context = CGContext(
                  data: memory, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        mask = memory
        maskContext = context
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(settings.antialiased)
        context.setBlendMode(.lighten)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(settings.size)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setFillColor(gray: 1, alpha: 1)
        let hardness = min(max(settings.hardness, 0), 0.99)
        dabGradient = CGGradient(
            colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: [1, 1, 1, 1, 0, 1],
            locations: [0, hardness, 1], count: 3
        )!
    }

    isolated deinit {
        free(mask)
    }

    private var usesDabs: Bool { settings.antialiased && settings.hardness < 0.97 && settings.size > 2 }

    private func dab(at point: CGPoint) {
        let radius = settings.size / 2
        maskContext.saveGState()
        maskContext.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        maskContext.clip()
        maskContext.drawRadialGradient(dabGradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
        maskContext.restoreGState()
    }

    /// Extends the stroke to a new point. The first call starts it.
    public func move(to point: CGPoint) {
        let radius = settings.size / 2 + 2
        var touched = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        if let last = lastPoint {
            touched = touched.union(CGRect(x: last.x - radius, y: last.y - radius, width: radius * 2, height: radius * 2))
            if usesDabs {
                let spacing = max(settings.size * 0.12, 1)
                let length = last.distance(to: point)
                var travelled = distanceToNextDab
                while travelled <= length {
                    let t = length > 0 ? travelled / length : 0
                    dab(at: CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t))
                    travelled += spacing
                }
                distanceToNextDab = travelled - length
            } else {
                maskContext.move(to: last)
                maskContext.addLine(to: point)
                maskContext.strokePath()
            }
        } else if usesDabs {
            dab(at: point)
            distanceToNextDab = max(settings.size * 0.12, 1)
        } else {
            maskContext.move(to: point)
            maskContext.addLine(to: point)
            maskContext.strokePath()
        }
        lastPoint = point
        compose(in: touched)
    }

    private func maskImage() -> CGImage {
        let provider = CGDataProvider(dataInfo: nil, data: mask, size: width * height, releaseData: { _, _, _ in })!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Repaints the stroke over the starting pixels inside `rect`.
    private func compose(in rect: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let coverage = maskImage()
        // Whole pixels only: the starting pixels are restored per pixel, so a fractional fill edge
        // would leave a faint seam wherever two segments of the stroke meet.
        let area = rect.pixelAligned
        edit.draw(in: area, restoringBase: true) { context in
            context.clipUpright(to: bounds, mask: coverage)
            switch settings.mode {
            case .paint:
                var color = settings.color
                color.alpha *= settings.opacity
                context.setFillColor(color.cgColor)
                context.fill(area)
            case .erase:
                context.setBlendMode(.destinationOut)
                context.setFillColor(gray: 0, alpha: settings.opacity)
                context.fill(area)
            case .clone(let offset):
                context.setAlpha(settings.opacity)
                edit.withBaseImage { context.drawUpright($0, in: bounds.offsetBy(dx: offset.x, dy: offset.y)) }
            }
        }
    }

    public func end(name: String) {
        edit.commit(name: name)
    }

    public func cancel() {
        edit.cancel()
    }
}

extension Document {
    /// Fills the selection, or the whole layer when nothing is selected.
    public func fill(with color: RGBAColor) {
        guard let edit = RasterEdit(document: self) else { return }
        let area = selection?.bounds ?? bounds
        edit.draw(in: area) { context in
            context.setFillColor(color.cgColor)
            context.fill(area)
        }
        edit.commit(name: "Fill")
    }

    /// Erases the selection, or the whole layer when nothing is selected.
    public func erase() {
        guard activeLayer?.isRaster == true, let edit = RasterEdit(document: self) else { return }
        let area = selection?.bounds ?? bounds
        edit.draw(in: area) { context in
            context.setBlendMode(.destinationOut)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(area)
        }
        edit.commit(name: selection == nil ? "Clear Layer" : "Delete Selection")
    }

    /// The paint bucket: fills the area of similar color around a point.
    public func floodFill(at point: CGPoint, color: RGBAColor, tolerance: Int, contiguous: Bool, sampleAllLayers: Bool) {
        guard bounds.contains(point) else { return }
        // Sample before RasterEdit possibly adds a layer, so the picture read is the one the user clicked on.
        let source = pixels(ofLayer: sampleAllLayers || activeLayer?.isRaster != true ? nil : activeLayerID)
        guard let region = Selection.flood(
            pixels: source, width: Int(size.width), height: Int(size.height), at: point, tolerance: tolerance,
            contiguous: contiguous
        ), !region.isEmpty, let edit = RasterEdit(document: self) else { return }
        let whole = bounds
        edit.draw(in: region.bounds) { context in
            context.clipUpright(to: whole, mask: region.image)
            context.setFillColor(color.cgColor)
            context.fill(region.bounds)
        }
        edit.commit(name: "Paint Bucket")
    }

    /// Draws a two-color gradient over the selection or the whole layer.
    public func drawGradient(from start: CGPoint, to end: CGPoint, startColor: RGBAColor, endColor: RGBAColor, radial: Bool) {
        guard let edit = RasterEdit(document: self),
              let gradient = CGGradient(
                  colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [startColor.cgColor, endColor.cgColor] as CFArray,
                  locations: [0, 1]
              )
        else { return }
        let area = selection?.bounds ?? bounds
        edit.draw(in: area) { context in
            let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            if radial {
                context.drawRadialGradient(
                    gradient, startCenter: start, startRadius: 0, endCenter: start, endRadius: start.distance(to: end),
                    options: options
                )
            } else {
                context.drawLinearGradient(gradient, start: start, end: end, options: options)
            }
        }
        edit.commit(name: "Gradient")
    }
}
