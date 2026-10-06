import CoreGraphics
import CoreImage
import Foundation
import PixixCodec

/// Everything that undo has to restore. Copies are cheap because layers share pixel storage.
public struct DocumentState {
    public var size: CGSize
    /// Bottom layer first.
    public var layers: [Layer]
    public var activeLayerID: LayerID?
    public var selection: Selection?
}

public enum DocumentChange {
    /// Pixels inside the rectangle changed; nothing else did.
    case pixels(CGRect)
    /// Layers, size or selection changed.
    case everything
}

/// A layered image. All changes go through methods here so they land in the history.
@MainActor
public final class Document {
    public private(set) var state: DocumentState
    public let colorSpace: CGColorSpace
    public let history = History()
    public let renderer: Renderer
    public var onChange: ((DocumentChange) -> Void)?

    /// A destructive effect being tried out; it is rendered but not part of the document yet.
    public var preview: EffectPreview? {
        didSet { onChange?(.everything) }
    }

    public var size: CGSize { state.size }
    public var bounds: CGRect { CGRect(origin: .zero, size: state.size) }
    public var layers: [Layer] { state.layers }
    public var selection: Selection? { state.selection }
    public var activeLayerID: LayerID? { state.activeLayerID }
    public var activeIndex: Int? { state.layers.firstIndex { $0.id == state.activeLayerID } }
    public var activeLayer: Layer? { activeIndex.map { state.layers[$0] } }

    public func layer(_ id: LayerID) -> Layer? { state.layers.first { $0.id == id } }

    public init(size: CGSize, colorSpace: CGColorSpace, renderer: Renderer = Renderer()) {
        self.state = DocumentState(size: size, layers: [], activeLayerID: nil, selection: nil)
        self.colorSpace = colorSpace
        self.renderer = renderer
    }

    /// A document with the image as its only layer.
    public convenience init?(image: CGImage, layerName: String = "Background", renderer: Renderer = Renderer()) {
        let space = Resampler.renderableColorSpace(for: image)
        guard let buffer = PixelBuffer(image: image, colorSpace: space) else { return nil }
        self.init(size: buffer.size, colorSpace: space, renderer: renderer)
        let layer = Layer(name: layerName, content: .raster(buffer))
        state.layers = [layer]
        state.activeLayerID = layer.id
    }

    /// Replaces the whole state without recording history. For loading a project.
    public func load(_ newState: DocumentState) {
        state = newState
        onChange?(.everything)
    }

    // MARK: Rendering

    public func composite() -> CIImage {
        renderer.composite(state, colorSpace: colorSpace, preview: preview)
    }

    public func flattenedImage() -> CGImage? {
        renderer.makeImage(renderer.composite(state, colorSpace: colorSpace), size: state.size, colorSpace: colorSpace)
    }

    /// Premultiplied BGRA bytes of the whole picture or of one layer, as seen in the document.
    public func pixels(ofLayer id: LayerID? = nil) -> [UInt8] {
        let image = renderer.composite(state, colorSpace: colorSpace, only: id.map { [$0] })
        return renderer.pixels(image, size: state.size, colorSpace: colorSpace)
    }

    // MARK: History plumbing

    private static func bufferCost(_ a: DocumentState, _ b: DocumentState) -> Int {
        func buffers(_ state: DocumentState) -> [ObjectIdentifier: Int] {
            var result: [ObjectIdentifier: Int] = [:]
            for layer in state.layers {
                if let buffer = layer.buffer { result[ObjectIdentifier(buffer)] = buffer.byteCount }
            }
            return result
        }
        let first = buffers(a), second = buffers(b)
        var cost = 0
        for (id, bytes) in first where second[id] == nil { cost += bytes }
        for (id, bytes) in second where first[id] == nil { cost += bytes }
        return cost + (a.selection === b.selection ? 0 : (a.selection?.data.count ?? 0) + (b.selection?.data.count ?? 0))
    }

    /// Applies a change and records it as one undo step.
    /// Changes with the same `key` in a row merge, so dragging a slider or a handle is one step.
    public func mutate(_ name: String, key: String? = nil, _ body: (inout DocumentState) -> Void) {
        let before = state
        body(&state)
        let after = state
        if state.activeLayerID == nil || !state.layers.contains(where: { $0.id == state.activeLayerID }) {
            state.activeLayerID = state.layers.last?.id
        }
        let settled = state
        history.record(
            name: name, cost: Self.bufferCost(before, after), key: key,
            undo: { [weak self] in self?.restore(before) },
            redo: { [weak self] in self?.restore(settled) }
        )
        renderer.pruneCache(keeping: state.layers)
        onChange?(.everything)
    }

    /// Ends a run of merged changes (see `mutate`).
    public func endInteraction() {
        history.seal()
    }

    public func undo() { history.undo() }
    public func redo() { history.redo() }

    /// Registers an in-place pixel edit that has already been made. Used by `RasterEdit`.
    func recordPixels(name: String, cost: Int, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        history.record(name: name, cost: cost, undo: undo, redo: redo)
    }

    func notify(_ change: DocumentChange) {
        onChange?(change)
    }

    /// Changes layers without touching history. Only for edits that record their own undo step.
    func replaceLayers(_ layers: [Layer], active: LayerID?) {
        state.layers = layers
        state.activeLayerID = active
    }

    // MARK: Layers

    public func setActiveLayer(_ id: LayerID?) {
        guard state.activeLayerID != id else { return }
        state.activeLayerID = id
        onChange?(.everything)
    }

    /// Changes one layer's properties.
    public func updateLayer(_ id: LayerID, name: String, key: String? = nil, _ body: (inout Layer) -> Void) {
        guard state.layers.contains(where: { $0.id == id }) else { return }
        mutate(name, key: key.map { "\($0)-\(id)" }) { state in
            guard let index = state.layers.firstIndex(where: { $0.id == id }) else { return }
            body(&state.layers[index])
        }
    }

    /// Inserts above the active layer and makes the new layer active.
    public func addLayer(_ layer: Layer, name: String = "Add Layer") {
        mutate(name) { state in
            let index = state.layers.firstIndex { $0.id == state.activeLayerID }.map { $0 + 1 } ?? state.layers.count
            state.layers.insert(layer, at: index)
            state.activeLayerID = layer.id
        }
    }

    public func addEmptyLayer() {
        guard let buffer = PixelBuffer(width: Int(size.width), height: Int(size.height), colorSpace: colorSpace) else { return }
        let count = state.layers.filter(\.isRaster).count
        addLayer(Layer(name: "Layer \(count + 1)", content: .raster(buffer)))
    }

    /// Adds a picture as a new layer, shrunk to fit the canvas if it is larger, centered on `center`.
    @discardableResult
    public func addImageLayer(_ image: CGImage, name: String, center: CGPoint? = nil) -> LayerID? {
        guard let buffer = PixelBuffer(image: image, colorSpace: colorSpace) else { return nil }
        var layer = Layer(name: name, content: .raster(buffer))
        let fit = min(1, min(size.width / buffer.size.width, size.height / buffer.size.height))
        let target = center ?? bounds.center
        layer.transform = CGAffineTransform(scaleX: fit, y: fit).concatenating(CGAffineTransform(
            translationX: target.x - buffer.size.width * fit / 2, y: target.y - buffer.size.height * fit / 2
        ))
        addLayer(layer, name: "Add Image")
        return layer.id
    }

    public func removeLayer(_ id: LayerID) {
        guard state.layers.count > 1, let index = state.layers.firstIndex(where: { $0.id == id }) else { return }
        mutate("Delete Layer") { state in
            state.layers.remove(at: index)
            state.activeLayerID = state.layers[max(0, index - 1)].id
        }
    }

    public func duplicateLayer(_ id: LayerID) {
        guard let index = state.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = state.layers[index]
        copy.id = LayerID()
        copy.name += " copy"
        if let buffer = copy.buffer { copy.content = .raster(buffer.copy()) }
        mutate("Duplicate Layer") { state in
            state.layers.insert(copy, at: index + 1)
            state.activeLayerID = copy.id
        }
    }

    /// Moves a layer up (positive) or down in the stack.
    public func moveLayer(_ id: LayerID, by offset: Int) {
        guard let index = state.layers.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), state.layers.count - 1)
        guard target != index else { return }
        mutate("Reorder Layers") { state in
            let layer = state.layers.remove(at: index)
            state.layers.insert(layer, at: target)
        }
    }

    public func moveLayer(_ id: LayerID, toIndex target: Int) {
        guard let index = state.layers.firstIndex(where: { $0.id == id }) else { return }
        moveLayer(id, by: target - index)
    }

    /// A canvas-sized raster layer holding what the given layers look like together.
    private func rasterized(_ ids: Set<LayerID>, name: String, from state: DocumentState, raw: Bool) -> Layer? {
        let image: CIImage
        if raw, ids.count == 1, let layer = state.layers.first(where: { ids.contains($0.id) }) {
            guard let content = renderer.contentImage(layer, state: state, colorSpace: colorSpace, raw: true) else { return nil }
            image = content.cropped(to: CGRect(origin: .zero, size: state.size))
        } else {
            var visible = state
            // Merging should not depend on the surrounding effect regions or hidden state of other layers.
            visible.layers = state.layers.filter { ids.contains($0.id) }
            image = renderer.composite(visible, colorSpace: colorSpace)
        }
        guard let buffer = renderer.makeBuffer(image, size: state.size, colorSpace: colorSpace) else { return nil }
        return Layer(name: name, content: .raster(buffer))
    }

    /// Turns text, shapes and transformed images into plain canvas-sized pixels. Adjustments stay editable.
    public func rasterizeLayer(_ id: LayerID) {
        guard let index = state.layers.firstIndex(where: { $0.id == id }) else { return }
        let source = state.layers[index]
        if case .effect = source.content { return }
        guard var flat = rasterized([id], name: source.name, from: state, raw: true) else { return }
        flat.id = source.id
        flat.isVisible = source.isVisible
        flat.isLocked = source.isLocked
        flat.opacity = source.opacity
        flat.blendMode = source.blendMode
        flat.adjustments = source.adjustments
        flat.filter = source.filter
        mutate("Rasterize Layer") { $0.layers[index] = flat }
    }

    /// Merges a layer into the one below it.
    public func mergeDown(_ id: LayerID) {
        guard let index = state.layers.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let upper = state.layers[index], lower = state.layers[index - 1]
        if case .effect = lower.content { return }
        var pair = state
        pair.layers = [lower, upper].map {
            var layer = $0
            layer.isVisible = true
            return layer
        }
        // An effect region on top needs the picture below it; composite handles that for us.
        guard var merged = rasterized(Set(pair.layers.map(\.id)), name: lower.name, from: pair, raw: false) else { return }
        merged.id = lower.id
        merged.isVisible = lower.isVisible
        mutate("Merge Down") { state in
            state.layers[index - 1] = merged
            state.layers.remove(at: index)
            state.activeLayerID = merged.id
        }
    }

    public func flatten() {
        guard state.layers.count > 1 || state.layers.first?.isRaster == false else { return }
        guard let merged = rasterized(Set(state.layers.map(\.id)), name: "Background", from: state, raw: false) else { return }
        mutate("Flatten Image") { state in
            state.layers = [merged]
            state.activeLayerID = merged.id
        }
    }

    // MARK: Geometry

    /// Applies a document-space transform to every layer and sets a new canvas size.
    public func transformCanvas(_ name: String, by transform: CGAffineTransform, newSize: CGSize) {
        let size = CGSize(
            width: min(max(newSize.width.rounded(), 1), CGFloat(PixelBuffer.maxDimension)),
            height: min(max(newSize.height.rounded(), 1), CGFloat(PixelBuffer.maxDimension))
        )
        mutate(name) { state in
            for index in state.layers.indices {
                state.layers[index].transform = state.layers[index].transform.concatenating(transform)
            }
            state.size = size
            state.selection = nil
        }
    }

    /// Crops to a rectangle, which may reach outside the canvas to extend it.
    /// `angle` straightens: the picture is turned so the tilted crop frame ends up level.
    public func crop(to rect: CGRect, angle: CGFloat = 0) {
        let frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width.rounded(), height: rect.height.rounded())
        guard frame.width >= 1, frame.height >= 1 else { return }
        let transform = CGAffineTransform.rotation(-angle, about: frame.center)
            .concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
        transformCanvas("Crop", by: transform, newSize: frame.size)
    }

    /// Scales the whole picture. Different horizontal and vertical factors stretch it.
    public func resize(to newSize: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        transformCanvas(
            "Resize Image", by: CGAffineTransform(scaleX: newSize.width / size.width, y: newSize.height / size.height),
            newSize: newSize
        )
    }

    /// Changes the canvas without scaling. `anchor` is where the old picture sticks: 0 is left or top, 1 is right or bottom.
    public func setCanvasSize(_ newSize: CGSize, anchor: CGPoint) {
        let shift = CGAffineTransform(
            translationX: ((newSize.width - size.width) * anchor.x).rounded(),
            y: ((newSize.height - size.height) * anchor.y).rounded()
        )
        transformCanvas("Canvas Size", by: shift, newSize: newSize)
    }

    /// Turns the picture clockwise by a number of quarter turns (negative for counterclockwise).
    public func rotate(quarterTurns: Int) {
        let turns = ((quarterTurns % 4) + 4) % 4
        let w = size.width, h = size.height
        switch turns {
        case 1:
            transformCanvas("Rotate Right", by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0), newSize: CGSize(width: h, height: w))
        case 2:
            transformCanvas("Rotate 180°", by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h), newSize: size)
        case 3:
            transformCanvas("Rotate Left", by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w), newSize: CGSize(width: h, height: w))
        default:
            break
        }
    }

    public func flip(horizontal: Bool) {
        let transform = horizontal
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
            : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        transformCanvas(horizontal ? "Flip Horizontal" : "Flip Vertical", by: transform, newSize: size)
    }

    // MARK: Selection

    public func setSelection(_ selection: Selection?, name: String = "Select", combine: SelectionCombine = .replace) {
        var result = selection
        if let selection, let current = state.selection, combine != .replace {
            result = current.combined(with: selection, mode: combine)
        } else if selection == nil, combine != .replace {
            return
        }
        if result?.isEmpty == true { result = nil }
        guard result !== state.selection else { return }
        mutate(result == nil ? "Deselect" : name) { $0.selection = result }
    }

    public func selectAll() {
        setSelection(Selection.all(in: size), name: "Select All")
    }

    public func invertSelection() {
        guard let selection = state.selection else {
            selectAll()
            return
        }
        setSelection(selection.inverted(), name: "Invert Selection")
    }

    public func featherSelection(radius: Double) {
        guard let selection = state.selection else { return }
        setSelection(selection.feathered(radius: radius, context: renderer.context), name: "Feather Selection")
    }

    /// Selects by color similarity, starting from a point.
    public func selectSimilar(
        at point: CGPoint, tolerance: Int, contiguous: Bool, sampleAllLayers: Bool, combine: SelectionCombine
    ) {
        guard bounds.contains(point) else { return }
        let source = pixels(ofLayer: sampleAllLayers ? nil : activeLayerID)
        guard let mask = Selection.flood(
            pixels: source, width: Int(size.width), height: Int(size.height), at: point, tolerance: tolerance,
            contiguous: contiguous
        ) else { return }
        setSelection(mask, name: "Magic Wand", combine: combine)
    }

    /// Color of the picture (or of one layer) at a point, not premultiplied.
    public func color(at point: CGPoint, layer id: LayerID? = nil) -> RGBAColor? {
        guard bounds.contains(point) else { return nil }
        let pixel = CGRect(x: point.x.rounded(.down), y: point.y.rounded(.down), width: 1, height: 1)
        let image = renderer.composite(state, colorSpace: colorSpace, only: id.map { [$0] })
            .cropped(to: pixel.flipped(height: size.height))
            .transformed(by: CGAffineTransform(translationX: -pixel.minX, y: -(size.height - pixel.maxY)))
        let bytes = renderer.pixels(image, size: CGSize(width: 1, height: 1), colorSpace: colorSpace)
        guard bytes.count == 4, bytes[3] > 0 else { return bytes.count == 4 ? .clear : nil }
        let alpha = Double(bytes[3]) / 255
        return RGBAColor(
            red: Double(bytes[2]) / 255 / alpha, green: Double(bytes[1]) / 255 / alpha,
            blue: Double(bytes[0]) / 255 / alpha, alpha: alpha
        )
    }

    // MARK: Effects

    /// Bakes an effect into the active raster layer, inside the selection if there is one.
    public func applyEffect(_ effect: EffectDescriptor, values: [String: Double]) {
        guard let index = activeIndex, let buffer = state.layers[index].buffer else { return }
        let image = renderer.effectImage(effect, values: values, buffer: buffer, layer: state.layers[index], state: state)
        guard let result = renderer.makeBuffer(image, size: buffer.size, colorSpace: colorSpace) else { return }
        preview = nil
        mutate(effect.name) { $0.layers[index].content = .raster(result) }
    }

    /// Bakes the layer's sliders and filter into its pixels and resets them.
    public func applyAdjustments(_ id: LayerID) {
        guard let index = state.layers.firstIndex(where: { $0.id == id }), let buffer = state.layers[index].buffer else { return }
        let layer = state.layers[index]
        guard !layer.adjustments.isNeutral || layer.filter != .none else { return }
        var image = layer.filter.apply(to: buffer.ciImage(), extent: buffer.bounds)
        image = layer.adjustments.apply(to: image, extent: buffer.bounds)
        guard let result = renderer.makeBuffer(image, size: buffer.size, colorSpace: colorSpace) else { return }
        mutate("Apply Adjustments") { state in
            state.layers[index].content = .raster(result)
            state.layers[index].adjustments = Adjustments()
            state.layers[index].filter = .none
        }
    }

    // MARK: Clipboard helpers

    /// The selected part of the picture (or of one layer) as an image cropped to the selection's bounds.
    public func copyImage(layer id: LayerID?) -> (image: CGImage, origin: CGPoint)? {
        var image = renderer.composite(state, colorSpace: colorSpace, only: id.map { [$0] })
        var area = bounds
        if let selection = state.selection {
            image = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: selection.ciImage(),
            ])
            area = selection.bounds
        }
        guard !area.isEmpty else { return nil }
        let moved = image.cropped(to: area.flipped(height: size.height))
            .transformed(by: CGAffineTransform(translationX: -area.minX, y: -(size.height - area.maxY)))
        guard let result = renderer.makeImage(moved, size: area.size, colorSpace: colorSpace) else { return nil }
        return (result, area.origin)
    }

    /// Lifts the selected pixels of the active raster layer into a new layer above it, leaving a hole behind.
    @discardableResult
    public func floatSelection() -> LayerID? {
        guard let selection = state.selection, let index = activeIndex, state.layers[index].isRaster,
              !state.layers[index].isLocked,
              let lifted = copyImage(layer: state.layers[index].id),
              let piece = PixelBuffer(image: lifted.image, colorSpace: colorSpace)
        else { return nil }
        // Work on a canvas-aligned copy of the source, so the mask lines up with its pixels.
        var source = state.layers[index]
        let punched: PixelBuffer
        if source.isAligned(to: state.size), let buffer = source.buffer {
            punched = buffer.copy()
        } else {
            guard let flat = rasterized([source.id], name: source.name, from: state, raw: true), let buffer = flat.buffer else { return nil }
            punched = buffer
            source.transform = .identity
        }
        punched.withContext { context in
            context.clipUpright(to: punched.bounds, mask: selection.image)
            context.setBlendMode(.destinationOut)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(punched.bounds)
        }
        source.content = .raster(punched)
        var layer = Layer(name: "Selection", content: .raster(piece))
        layer.transform = CGAffineTransform(translationX: lifted.origin.x, y: lifted.origin.y)
        mutate("Move Selection") { state in
            state.layers[index] = source
            state.layers.insert(layer, at: index + 1)
            state.activeLayerID = layer.id
            state.selection = nil
        }
        return layer.id
    }

    /// Swaps in a state that was captured earlier, without recording anything.
    func restore(_ snapshot: DocumentState) {
        state = snapshot
        renderer.pruneCache(keeping: state.layers)
        onChange?(.everything)
    }

    /// Records the difference between an earlier state and the current one as an undo step.
    func recordSwap(name: String, before: DocumentState) {
        let after = state
        history.record(
            name: name, cost: Self.bufferCost(before, after),
            undo: { [weak self] in self?.restore(before) },
            redo: { [weak self] in self?.restore(after) }
        )
    }
}

extension Layer {
    /// True when the layer is plain canvas-sized pixels that can be painted on directly.
    public func isAligned(to size: CGSize) -> Bool {
        guard let buffer else { return false }
        return transform.isIdentityOrClose && buffer.size == size
    }
}
