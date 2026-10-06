import CoreGraphics
import CoreImage
import Foundation
import IOSurface
import Metal

/// A destructive effect shown live while its dialog is open.
public struct EffectPreview {
    public var layerID: LayerID
    public var effect: EffectDescriptor
    public var values: [String: Double]

    public init(layerID: LayerID, effect: EffectDescriptor, values: [String: Double]) {
        self.layerID = layerID
        self.effect = effect
        self.values = values
    }
}

/// Composites a document with Core Image.
///
/// Color management is switched off on purpose: pixel values pass through untouched and the
/// document's color space is attached to whatever comes out. Blending therefore happens on
/// gamma-encoded values, which is what Paint.NET and most editors do.
@MainActor
public final class Renderer {
    public let context: CIContext
    private var objectCache: [LayerID: (key: AnyHashable, scale: CGFloat, image: CIImage)] = [:]
    private var ellipseMask: CIImage?

    public init() {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: true,
            .name: "Pixix",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    // MARK: Coordinate mapping

    /// Maps "local Core Image" coordinates (the layer's own x, with y negated) into the document's
    /// Core Image space, where y points up from the bottom edge.
    private func documentTransform(_ layer: Layer, documentHeight: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(layer.transform)
            .concatenating(.flipY(height: documentHeight))
    }

    /// Places an image whose natural extent starts at the origin over the given local box.
    private func place(_ image: CIImage, over box: CGRect, pixelScale: CGFloat) -> CIImage {
        image.transformed(
            by: CGAffineTransform(scaleX: 1 / pixelScale, y: 1 / pixelScale)
                .concatenating(CGAffineTransform(translationX: box.minX, y: -box.maxY))
        )
    }

    // MARK: Layer content

    private func objectImage(_ layer: Layer, colorSpace: CGColorSpace) -> (image: CIImage, scale: CGFloat)? {
        // Render at the resolution the layer ends up at, so enlarged text stays sharp.
        let wanted = min(max(layer.transform.scaleMagnitude, 1), 8).rounded(.up)
        let key: AnyHashable
        switch layer.content {
        case .text(let text): key = AnyHashable(text)
        case .shape(let shape): key = AnyHashable(shape)
        default: return nil
        }
        if let hit = objectCache[layer.id], hit.key == key, hit.scale == wanted {
            return (hit.image, wanted)
        }
        let rendered: CGImage?
        switch layer.content {
        case .text(let text): rendered = ObjectRenderer.image(for: text, scale: wanted, colorSpace: colorSpace)
        case .shape(let shape): rendered = ObjectRenderer.image(for: shape, scale: wanted, colorSpace: colorSpace)
        default: rendered = nil
        }
        guard let rendered else { return nil }
        let image = CIImage(cgImage: rendered, options: [.colorSpace: NSNull()])
        objectCache[layer.id] = (key, wanted, image)
        return (image, wanted)
    }

    /// Drops cached bitmaps of layers that no longer exist.
    public func pruneCache(keeping layers: [Layer]) {
        let alive = Set(layers.map(\.id))
        objectCache = objectCache.filter { alive.contains($0.key) }
    }

    /// The effect applied to a raster layer's pixels, limited to the selection. Result is in the buffer's own space.
    func effectImage(
        _ effect: EffectDescriptor, values: [String: Double], buffer: PixelBuffer, layer: Layer, state: DocumentState
    ) -> CIImage {
        let source = buffer.ciImage()
        let extent = buffer.bounds
        var result = effect.apply(to: source, values: values, extent: extent)
        if let selection = state.selection {
            // Bring the document-space mask into the layer's pixel space.
            let toDocument = CGAffineTransform(translationX: 0, y: -extent.height)
                .concatenating(documentTransform(layer, documentHeight: state.size.height))
            let mask = selection.ciImage().transformed(by: toDocument.inverted())
            result = result.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: mask,
            ]).cropped(to: extent)
        }
        return result
    }

    /// A layer's picture in the document's Core Image space, before opacity and blending.
    /// With `raw`, adjustments and filters are left out.
    func contentImage(
        _ layer: Layer, state: DocumentState, colorSpace: CGColorSpace, preview: EffectPreview? = nil, raw: Bool = false
    ) -> CIImage? {
        var image: CIImage
        var toDocument = documentTransform(layer, documentHeight: state.size.height)
        switch layer.content {
        case .raster(let buffer):
            if let preview, preview.layerID == layer.id {
                image = effectImage(preview.effect, values: preview.values, buffer: buffer, layer: layer, state: state)
            } else {
                image = buffer.ciImage()
            }
            if !raw {
                image = layer.filter.apply(to: image, extent: buffer.bounds)
                image = layer.adjustments.apply(to: image, extent: buffer.bounds)
            }
            toDocument = CGAffineTransform(translationX: 0, y: -CGFloat(buffer.height)).concatenating(toDocument)
            let scale = toDocument.scaleMagnitude
            if scale < 0.7, scale > 0.001 {
                // Plain bilinear sampling aliases badly when shrinking; prefilter first.
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
                ])
                toDocument = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale).concatenating(toDocument)
            }
            return image.transformed(by: toDocument)
        case .text, .shape:
            guard let object = objectImage(layer, colorSpace: colorSpace) else { return nil }
            image = place(object.image, over: layer.localBounds, pixelScale: object.scale)
            if !raw, !layer.adjustments.isNeutral || layer.filter != .none {
                let extent = image.extent
                image = layer.filter.apply(to: image, extent: extent)
                image = layer.adjustments.apply(to: image, extent: extent)
            }
            return image.transformed(by: toDocument)
        case .effect:
            return nil
        }
    }

    private func regionMask(_ region: EffectRegion, layer: Layer, state: DocumentState) -> CIImage {
        let box = CGRect(origin: .zero, size: region.size)
        let shape: CIImage
        if region.isEllipse {
            if ellipseMask == nil, let rendered = ObjectRenderer.ellipseMask(size: 1024) {
                ellipseMask = CIImage(cgImage: rendered, options: [.colorSpace: NSNull()])
            }
            let unit = ellipseMask ?? CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            shape = unit
                .transformed(by: CGAffineTransform(scaleX: box.width / 1024, y: box.height / 1024))
                .transformed(by: CGAffineTransform(translationX: 0, y: -box.height))
        } else {
            shape = CIImage(color: .white).cropped(to: CGRect(x: 0, y: -box.height, width: box.width, height: box.height))
        }
        var mask = shape.transformed(by: documentTransform(layer, documentHeight: state.size.height))
        if layer.opacity < 1 {
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity),
            ])
        }
        return mask
    }

    private func applyRegion(_ region: EffectRegion, layer: Layer, below: CIImage, state: DocumentState) -> CIImage {
        let documentRect = CGRect(origin: .zero, size: state.size)
        let base = below.cropped(to: documentRect)
        let filtered: CIImage
        switch region.effect {
        case .blur:
            filtered = base.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(region.amount, 0.5)])
        case .pixelate:
            // Anchor the grid to the region, so cells do not swim when the region moves by less than a cell.
            let corner = CGPoint.zero.applying(documentTransform(layer, documentHeight: state.size.height))
            filtered = base.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(region.amount, 2), kCIInputCenterKey: CIVector(x: corner.x, y: corner.y),
            ])
        }
        return filtered.cropped(to: documentRect).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: below, kCIInputMaskImageKey: regionMask(region, layer: layer, state: state),
        ])
    }

    // MARK: Compositing

    /// The whole document as one image in Core Image coordinates.
    public func composite(
        _ state: DocumentState, colorSpace: CGColorSpace, preview: EffectPreview? = nil, only: Set<LayerID>? = nil
    ) -> CIImage {
        let documentRect = CGRect(origin: .zero, size: state.size)
        var result = CIImage.empty()
        for layer in state.layers where layer.isVisible && layer.opacity > 0 {
            if let only, !only.contains(layer.id) { continue }
            if case .effect(let region) = layer.content {
                result = applyRegion(region, layer: layer, below: result, state: state)
                continue
            }
            guard var image = contentImage(layer, state: state, colorSpace: colorSpace, preview: preview) else { continue }
            if layer.opacity < 1 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity),
                ])
            }
            image = image.cropped(to: documentRect)
            result = image.applyingFilter(layer.blendMode.filterName, parameters: [kCIInputBackgroundImageKey: result])
        }
        return result.cropped(to: documentRect)
    }

    // MARK: Output

    /// Draws into a surface the size of the document. `rect` limits the work to part of it (document coordinates).
    public func render(_ image: CIImage, to surface: IOSurface, documentSize: CGSize, rect: CGRect? = nil) {
        let full = CGRect(origin: .zero, size: documentSize)
        let background = CIImage.empty()
        let source = image.composited(over: background)
        guard let rect, !rect.isNull else {
            context.render(source.clearingOutside(full), to: surface, bounds: full, colorSpace: nil)
            return
        }
        let dirty = rect.pixelAligned.intersection(full)
        guard !dirty.isEmpty else { return }
        let area = dirty.flipped(height: documentSize.height)
        let destination = CIRenderDestination(ioSurface: surface)
        destination.colorSpace = nil
        destination.alphaMode = .premultiplied
        do {
            let task = try context.startTask(
                toRender: source.clearingOutside(area), from: area, to: destination, at: area.origin
            )
            _ = try task.waitUntilCompleted()
        } catch {
            context.render(source.clearingOutside(full), to: surface, bounds: full, colorSpace: nil)
        }
    }

    public func makeImage(_ image: CIImage, size: CGSize, colorSpace: CGColorSpace) -> CGImage? {
        guard let buffer = PixelBuffer(width: Int(size.width), height: Int(size.height), colorSpace: colorSpace) else { return nil }
        render(image, to: buffer.surface, documentSize: size)
        return buffer.makeImage()
    }

    /// A new buffer of the given size holding the image.
    public func makeBuffer(_ image: CIImage, size: CGSize, colorSpace: CGColorSpace) -> PixelBuffer? {
        guard let buffer = PixelBuffer(width: Int(size.width), height: Int(size.height), colorSpace: colorSpace) else { return nil }
        render(image, to: buffer.surface, documentSize: size)
        return buffer
    }

    /// Premultiplied BGRA bytes of the image, tightly packed, top row first.
    public func pixels(_ image: CIImage, size: CGSize, colorSpace: CGColorSpace) -> [UInt8] {
        let width = Int(size.width), height = Int(size.height)
        guard let buffer = makeBuffer(image, size: size, colorSpace: colorSpace) else { return [] }
        var output = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withBytes { bytes, rowBytes in
            output.withUnsafeMutableBytes { out in
                for row in 0..<height {
                    let source = UnsafeRawBufferPointer(rebasing: bytes[(row * rowBytes)...].prefix(width * 4))
                    UnsafeMutableRawBufferPointer(rebasing: out[(row * width * 4)...].prefix(width * 4)).copyMemory(from: source)
                }
            }
        }
        return output
    }
}

extension CIImage {
    /// Transparent everywhere outside the rectangle, so stale pixels in a reused surface get overwritten.
    func clearingOutside(_ rect: CGRect) -> CIImage {
        cropped(to: rect).composited(over: CIImage(color: .clear).cropped(to: rect))
    }
}
