import AppKit
import PixixCodec
import PixixEngine

/// A tool from the palette. Points are in image pixels with a top-left origin.
@MainActor
class EditorTool {
    unowned let editor: EditorController

    init(editor: EditorController) {
        self.editor = editor
    }

    var document: Document { editor.document }
    var model: EditorModel { editor.model }
    var canvas: CanvasView { editor.canvas }

    func activate() {}
    func deactivate() {}
    func mouseDown(at point: CGPoint, event: NSEvent) {}
    func mouseDragged(to point: CGPoint, event: NSEvent) {}
    func mouseUp(at point: CGPoint, event: NSEvent) {}
    func mouseMoved(to point: CGPoint, event: NSEvent) {}
    func cursor(at point: CGPoint) -> NSCursor { .crosshair }
    func drawOverlay(in context: CGContext, canvas: CanvasView) {}
    /// Return true when the key was used.
    func keyDown(_ event: NSEvent) -> Bool { false }
    func settingsDidChange() {}
    /// Called after the document changed in any way other than a few pixels.
    func documentDidChange() {}
    /// True while the tool is taking typed text.
    var holdsKeyboard: Bool { false }

    func redrawOverlay() {
        canvas.setOverlayNeedsDisplay()
    }

    /// The topmost visible layer under a point.
    func layer(at point: CGPoint) -> Layer? {
        document.layers.reversed().first { $0.isVisible && $0.contains(documentPoint: point) }
    }
}

// MARK: - Move

final class MoveTool: EditorTool {
    private lazy var frame = FrameInteraction(editor: editor)

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        if frame.beginHandleDrag(at: point) { return }
        // Dragging inside a selection lifts those pixels onto their own layer and moves that.
        if let selection = document.selection, selection.bounds.contains(point), document.activeLayer?.isRaster == true,
           document.floatSelection() != nil {
            frame.beginMove(at: point)
            return
        }
        guard let hit = layer(at: point) else { return }
        document.setActiveLayer(hit.id)
        if event.clickCount == 2, hit.text != nil {
            editor.beginTextEditing(hit.id, at: point)
            return
        }
        frame.beginMove(at: point)
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        frame.drag(to: point, event: event)
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        frame.end()
    }

    override func cursor(at point: CGPoint) -> NSCursor {
        if let cursor = frame.cursor(at: point) { return cursor }
        return layer(at: point) != nil ? .openHand : .arrow
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        frame.draw(in: context, canvas: canvas)
    }

    override func keyDown(_ event: NSEvent) -> Bool {
        editor.nudgeActiveLayer(with: event)
    }
}

// MARK: - Crop

final class CropTool: EditorTool {
    private enum Drag {
        case handle(Int, original: CGRect)
        case move(start: CGPoint, original: CGRect)
        case new(start: CGPoint)
    }

    private var drag: Drag?
    private var rect: CGRect {
        get { model.cropRect }
        set { model.cropRect = newValue }
    }
    /// The frame as the user left it. Straightening shrinks the frame on screen from this one, so that
    /// easing the slider back gives the room back.
    private var chosen = CGRect.zero

    private var ratio: CGFloat? {
        switch model.cropAspect {
        case .free: nil
        case .original: document.size.width / max(document.size.height, 1)
        case .custom: model.customAspectWidth / max(model.customAspectHeight, 0.01)
        default: model.cropAspect.fixedRatio
        }
    }

    private var reach: CGFloat { 10 / max(canvas.scale, 0.0001) }

    override func activate() {
        rect = document.bounds
        // Before the slider is zeroed: that reports a settings change, which starts from the chosen frame.
        chosen = rect
        model.straighten = 0
        applyRatio()
        chosen = rect
    }

    override func deactivate() {
        canvas.setPreviewRotation(0, about: .zero)
    }

    override func settingsDidChange() {
        rect = chosen
        applyRatio()
        chosen = rect
        fitToTurnedPicture()
        updatePreview()
        redrawOverlay()
    }

    /// The image changed size underneath us (undo, rotate); start over from the full canvas.
    func reset() {
        rect = document.bounds
        applyRatio()
        chosen = rect
        fitToTurnedPicture()
        updatePreview()
        redrawOverlay()
    }

    /// A straightened picture is tilted under the frame, and a frame as large as before would catch empty
    /// corners. Shrink it until it is all picture. A frame pulled past the edge to extend the canvas is left alone.
    private func fitToTurnedPicture() {
        guard model.straighten != 0, document.bounds.insetBy(dx: -0.5, dy: -0.5).contains(chosen) else { return }
        rect = chosen.shrunkToFit(document.bounds, turnedBy: model.straighten * .pi / 180)
    }

    private func updatePreview() {
        canvas.setPreviewRotation(-model.straighten * .pi / 180, about: rect.center)
    }

    /// Shrinks the frame around its center until it has the chosen proportions.
    private func applyRatio() {
        guard let ratio else { return }
        rect = FrameGeometry.fitted(rect, ratio: ratio)
    }

    private func handle(at point: CGPoint) -> Int? {
        let points = FrameGeometry.handlePoints(rect)
        guard let nearest = points.indices.min(by: { points[$0].distance(to: point) < points[$1].distance(to: point) }),
              points[nearest].distance(to: point) <= reach
        else { return nil }
        return nearest
    }

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        if event.clickCount == 2, rect.contains(point) {
            apply()
            return
        }
        if let handle = handle(at: point) {
            drag = .handle(handle, original: rect)
        } else if rect.contains(point) {
            drag = .move(start: point, original: rect)
        } else {
            drag = .new(start: point)
        }
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        guard let drag else { return }
        let snap = !event.modifierFlags.contains(.control)
        switch drag {
        case .move(let start, let original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            if snap { moved = snappedOrigin(moved) }
            rect = moved
        case .new(let start):
            rect = FrameGeometry.frame(anchor: start, to: snap ? snappedPoint(point) : point, ratio: ratio)
        case .handle(let index, let original):
            let target = snap ? snappedPoint(point) : point
            if index < 4 {
                let anchor = FrameGeometry.handlePoints(original)[(index + 2) % 4]
                rect = FrameGeometry.frame(anchor: anchor, to: target, ratio: ratio)
            } else {
                rect = FrameGeometry.frame(original, draggingEdge: index - 4, to: target, ratio: ratio)
            }
        }
        updatePreview()
        redrawOverlay()
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        if rect.width < 2 || rect.height < 2 { reset() }
        rect = CGRect(
            x: rect.minX.rounded(), y: rect.minY.rounded(), width: max(rect.width.rounded(), 1),
            height: max(rect.height.rounded(), 1)
        )
        // A frame set by hand is taken as it is, even tilted past the picture.
        chosen = rect
        redrawOverlay()
    }

    private func snappedPoint(_ point: CGPoint) -> CGPoint {
        var result = point
        for edge in [0, document.size.width] where abs(point.x - edge) <= reach * 0.6 { result.x = edge }
        for edge in [0, document.size.height] where abs(point.y - edge) <= reach * 0.6 { result.y = edge }
        return result
    }

    private func snappedOrigin(_ rect: CGRect) -> CGRect {
        var result = rect
        let limit = reach * 0.6
        if abs(rect.minX) <= limit { result.origin.x = 0 }
        if abs(rect.maxX - document.size.width) <= limit { result.origin.x = document.size.width - rect.width }
        if abs(rect.minY) <= limit { result.origin.y = 0 }
        if abs(rect.maxY - document.size.height) <= limit { result.origin.y = document.size.height - rect.height }
        return result
    }

    func apply() {
        var frame = CGRect(
            x: rect.minX.rounded(), y: rect.minY.rounded(), width: max(rect.width.rounded(), 1),
            height: max(rect.height.rounded(), 1)
        )
        if model.straighten != 0, rect.width > 4, rect.height > 4 {
            // Whole pixels, rounded inward: rounding outward would let a sliver of emptiness back into a corner.
            let x0 = rect.minX.rounded(.up), y0 = rect.minY.rounded(.up)
            frame = CGRect(x: x0, y: y0, width: max(rect.maxX.rounded(.down) - x0, 1), height: max(rect.maxY.rounded(.down) - y0, 1))
        }
        guard frame != document.bounds || model.straighten != 0 else { return }
        let angle = model.straighten * .pi / 180
        canvas.setPreviewRotation(0, about: .zero)
        document.crop(to: frame, angle: angle)
        model.straighten = 0
        rect = document.bounds
        chosen = rect
        canvas.fit()
    }

    override func keyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:
            apply()
            return true
        case 53:
            model.straighten = 0
            reset()
            return true
        default:
            return false
        }
    }

    override func cursor(at point: CGPoint) -> NSCursor {
        if handle(at: point) != nil { return .pointingHand }
        return rect.contains(point) ? .openHand : .crosshair
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        let frame = CGRect(
            from: canvas.viewPoint(fromImage: rect.origin), to: canvas.viewPoint(fromImage: CGPoint(x: rect.maxX, y: rect.maxY))
        )
        context.saveGState()
        context.addRect(canvas.bounds)
        context.addRect(frame)
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fillPath(using: .evenOdd)

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        for step in 1...2 {
            let x = frame.minX + frame.width * CGFloat(step) / 3, y = frame.minY + frame.height * CGFloat(step) / 3
            context.move(to: CGPoint(x: x, y: frame.minY))
            context.addLine(to: CGPoint(x: x, y: frame.maxY))
            context.move(to: CGPoint(x: frame.minX, y: y))
            context.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        context.strokePath()

        context.setStrokeColor(.white)
        context.setLineWidth(1.5)
        context.stroke(frame)
        context.setFillColor(.white)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.setLineWidth(1)
        for point in FrameGeometry.handlePoints(frame) {
            let box = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            context.fill(box)
            context.stroke(box)
        }
        context.restoreGState()

        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        Self.drawLabel(text, centeredAt: CGPoint(x: frame.midX, y: frame.maxY + 16), in: canvas.bounds)
    }

    static func drawLabel(_ text: String, centeredAt point: CGPoint, in bounds: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var box = CGRect(x: point.x - size.width / 2 - 6, y: point.y - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
        box.origin.x = min(max(box.minX, bounds.minX + 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.minY, bounds.minY + 4), bounds.maxY - box.height - 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
    }
}

// MARK: - Selection

final class SelectTool: EditorTool {
    private var start: CGPoint?
    private var current: CGPoint?
    private var points: [CGPoint] = []
    private var combine = SelectionCombine.replace

    private func combineMode(for event: NSEvent) -> SelectionCombine {
        let shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option)
        if shift && option { return .intersect }
        if shift { return .add }
        if option { return .subtract }
        return model.selectionMode
    }

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        combine = combineMode(for: event)
        start = point
        current = point
        points = [point]
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        current = point
        if model.tool == .lasso, let last = points.last, last.distance(to: point) * canvas.scale > 2 {
            points.append(point)
        }
        redrawOverlay()
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            start = nil
            current = nil
            points = []
            redrawOverlay()
        }
        guard let start else { return }
        let rect = CGRect(from: start, to: point).intersection(document.bounds)
        let moved = start.distance(to: point) * canvas.scale > 3
        var selection: Selection?
        switch model.tool {
        case .selectEllipse where moved:
            selection = Selection.ellipse(CGRect(from: start, to: point), in: document.size)
        case .lasso where points.count > 2:
            selection = Selection.polygon(points, in: document.size)
        case .selectRectangle where moved && !rect.isEmpty:
            selection = Selection.rectangle(rect, in: document.size)
        default:
            break
        }
        guard var selection else {
            // A plain click clears the selection, as everywhere else.
            if combine == .replace { document.setSelection(nil) }
            return
        }
        if model.feather > 0 {
            selection = selection.feathered(radius: model.feather, context: document.renderer.context)
        }
        document.setSelection(selection, combine: combine)
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        guard let start, let current else { return }
        let path = CGMutablePath()
        let a = canvas.viewPoint(fromImage: start), b = canvas.viewPoint(fromImage: current)
        switch model.tool {
        case .selectEllipse: path.addEllipse(in: CGRect(from: a, to: b))
        case .lasso: path.addLines(between: points.map { canvas.viewPoint(fromImage: $0) })
        default: path.addRect(CGRect(from: a, to: b))
        }
        context.saveGState()
        context.setLineWidth(1)
        context.addPath(path)
        context.setStrokeColor(.white)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(.black)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.strokePath()
        context.restoreGState()
        if model.tool != .lasso {
            let size = CGRect(from: start, to: current).size
            CropTool.drawLabel(
                "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))",
                centeredAt: CGPoint(x: max(a.x, b.x) - 30, y: max(a.y, b.y) + 16), in: canvas.bounds
            )
        }
    }
}

final class WandTool: EditorTool {
    override func mouseDown(at point: CGPoint, event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option)
        let combine: SelectionCombine = shift && option ? .intersect : shift ? .add : option ? .subtract : model.selectionMode
        guard document.bounds.contains(point) else {
            if combine == .replace { document.setSelection(nil) }
            return
        }
        document.selectSimilar(
            at: point, tolerance: Int(model.tolerance * 2.55), contiguous: model.contiguous,
            sampleAllLayers: model.sampleAllLayers, combine: combine
        )
    }
}

// MARK: - Painting

final class PaintTool: EditorTool {
    private var stroke: BrushStroke?
    private var pointer: CGPoint?
    /// Where the clone stamp copies from, and how far that is from the brush.
    private var cloneSource: CGPoint?
    private var cloneOffset: CGPoint?

    private var strokeName: String { model.tool.title }

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        if model.tool == .clone {
            if event.modifierFlags.contains(.option) {
                cloneSource = point
                cloneOffset = nil
                redrawOverlay()
                return
            }
            guard let cloneSource else {
                editor.host.showToast("Option-click to choose where to clone from")
                return
            }
            if cloneOffset == nil { cloneOffset = point - cloneSource }
        }
        var settings = BrushSettings()
        settings.size = model.brushSize
        settings.hardness = model.brushHardness
        settings.opacity = model.brushOpacity
        settings.color = event.modifierFlags.contains(.control) ? model.secondaryColor : model.primaryColor
        switch model.tool {
        case .pencil:
            settings.antialiased = false
            settings.hardness = 1
        case .eraser:
            settings.mode = .erase
        case .clone:
            // The picture is drawn shifted by the offset, so the sample comes from the opposite direction.
            settings.mode = .clone(offset: cloneOffset ?? .zero)
        default:
            break
        }
        guard let stroke = BrushStroke(document: document, settings: settings) else {
            NSSound.beep()
            return
        }
        self.stroke = stroke
        stroke.move(to: point)
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        pointer = point
        stroke?.move(to: point)
        redrawOverlay()
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        stroke?.end(name: strokeName)
        stroke = nil
    }

    override func mouseMoved(to point: CGPoint, event: NSEvent) {
        pointer = point
        redrawOverlay()
    }

    override func deactivate() {
        stroke?.cancel()
        stroke = nil
    }

    override func keyDown(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers {
        case "[":
            model.brushSize = max(1, (model.brushSize * 0.85).rounded(.down))
        case "]":
            model.brushSize = min(1000, max(model.brushSize + 1, (model.brushSize * 1.18).rounded()))
        default:
            return false
        }
        redrawOverlay()
        return true
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        context.saveGState()
        if let pointer {
            let center = canvas.viewPoint(fromImage: pointer)
            let radius = max(model.brushSize * canvas.scale / 2, 1.5)
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setLineWidth(1)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            context.strokeEllipse(in: circle.insetBy(dx: -1, dy: -1))
            context.setStrokeColor(.white)
            context.strokeEllipse(in: circle)
        }
        if model.tool == .clone, let cloneSource {
            // While painting, show where pixels are being read from.
            let source = stroke != nil && pointer != nil && cloneOffset != nil ? pointer! - cloneOffset! : cloneSource
            let center = canvas.viewPoint(fromImage: source)
            context.setStrokeColor(.white)
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: center.x - 7, y: center.y))
            context.addLine(to: CGPoint(x: center.x + 7, y: center.y))
            context.move(to: CGPoint(x: center.x, y: center.y - 7))
            context.addLine(to: CGPoint(x: center.x, y: center.y + 7))
            context.strokePath()
        }
        context.restoreGState()
    }
}

final class FillTool: EditorTool {
    override func mouseDown(at point: CGPoint, event: NSEvent) {
        let color = event.modifierFlags.contains(.control) ? model.secondaryColor : model.primaryColor
        document.floodFill(
            at: point, color: color, tolerance: Int(model.tolerance * 2.55), contiguous: model.contiguous,
            sampleAllLayers: model.sampleAllLayers
        )
    }
}

final class GradientTool: EditorTool {
    private var start: CGPoint?
    private var current: CGPoint?

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        start = point
        current = point
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        guard let start else { return }
        current = event.modifierFlags.contains(.shift) ? FrameInteraction.snapAngle(from: start, to: point) : point
        redrawOverlay()
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        defer {
            start = nil
            current = nil
            redrawOverlay()
        }
        guard let start, let current, start.distance(to: current) * canvas.scale > 3 else { return }
        document.drawGradient(
            from: start, to: current, startColor: model.primaryColor, endColor: model.secondaryColor,
            radial: model.gradientIsRadial
        )
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        guard let start, let current else { return }
        let a = canvas.viewPoint(fromImage: start), b = canvas.viewPoint(fromImage: current)
        context.saveGState()
        for (color, width) in [(CGColor.black, CGFloat(3)), (CGColor.white, CGFloat(1.5))] {
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.move(to: a)
            context.addLine(to: b)
            context.strokePath()
        }
        context.restoreGState()
    }
}

final class PickerTool: EditorTool {
    private func pick(at point: CGPoint, event: NSEvent) {
        guard let color = document.color(at: point, layer: model.sampleAllLayers ? nil : document.activeLayerID),
              color.alpha > 0
        else { return }
        var opaque = color
        opaque.alpha = 1
        if event.modifierFlags.contains(.option) {
            model.secondaryColor = opaque
        } else {
            model.primaryColor = opaque
        }
    }

    override func mouseDown(at point: CGPoint, event: NSEvent) { pick(at: point, event: event) }
    override func mouseDragged(to point: CGPoint, event: NSEvent) { pick(at: point, event: event) }
}

// MARK: - Objects

/// Text and speech bubbles. Both are typed straight onto the picture.
final class TextTool: EditorTool {
    private lazy var frame = FrameInteraction(editor: editor)
    private var session: TextEditingSession?
    /// A press on existing text: a move if the pointer travels, a wish to type if it does not.
    private var pressed: CGPoint?
    private var isSelectingText = false
    /// A bubble being pulled out: from the spot it points at to where it will sit.
    private var bubble: (tip: CGPoint, place: CGPoint)?

    override var holdsKeyboard: Bool { session != nil }

    /// Starts typing into a text layer, with the caret at a point or with everything selected.
    func beginEditing(_ id: LayerID, at point: CGPoint? = nil) {
        endEditing()
        document.setActiveLayer(id)
        session = TextEditingSession(editor: editor, layerID: id, caretAt: point)
        session?.onEnd = { [weak self] in
            self?.session = nil
            self?.redrawOverlay()
        }
        redrawOverlay()
    }

    func endEditing() {
        session?.end()
        session = nil
    }

    /// Types into the text being edited, or selects part of it. For scripted scenarios.
    func type(_ string: String) {
        session?.insert(string)
    }

    func select(_ range: NSRange) {
        session?.select(range)
    }

    override func deactivate() {
        endEditing()
        bubble = nil
    }

    override func documentDidChange() {
        session?.documentDidChange()
    }

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        if let session {
            // The handles sit on the corners of the box, so they come before the text inside it.
            if frame.beginHandleDrag(at: point) { return }
            if session.mouseDown(at: point, event: event) {
                isSelectingText = true
                return
            }
            // A click anywhere else finishes the text, as in every editor.
            endEditing()
            return
        }
        if document.activeLayer?.text != nil, frame.beginHandleDrag(at: point) { return }
        if let hit = layer(at: point), hit.text != nil {
            document.setActiveLayer(hit.id)
            frame.beginMove(at: point)
            pressed = point
            return
        }
        if model.tool == .callout {
            bubble = (point, point)
        } else {
            addText(at: point)
        }
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        if isSelectingText {
            session?.mouseDragged(to: point)
        } else if let tip = bubble?.tip {
            bubble = (tip, point)
            redrawOverlay()
        } else {
            frame.drag(to: point, event: event)
        }
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        if isSelectingText {
            isSelectingText = false
            return
        }
        if let bubble {
            self.bubble = nil
            addBubble(tip: bubble.tip, at: point)
            return
        }
        frame.end()
        // A click on text that did not turn into a move puts the caret there.
        if let pressed, pressed.distance(to: point) * canvas.scale < 3, let id = document.activeLayerID,
           document.activeLayer?.text != nil {
            beginEditing(id, at: point)
        }
        pressed = nil
    }

    private func addText(at point: CGPoint) {
        var text = model.textDefaults
        text.color = model.primaryColor
        text.tail = nil
        var layer = Layer(name: "Text", content: .text(text))
        let size = layer.frameBounds.size
        layer.transform = CGAffineTransform(translationX: point.x - size.width / 2, y: point.y - size.height / 2)
        document.addLayer(layer, name: "Add Text")
        // The placeholder is selected, so the first key replaces it.
        beginEditing(layer.id)
    }

    /// A bubble in the primary color with its tail on `tip`. A plain click puts the bubble up and to the right.
    private func addBubble(tip: CGPoint, at point: CGPoint) {
        var text = model.textDefaults
        text.string = "Text"
        text.background = model.primaryColor
        let fill = model.primaryColor
        text.color = 0.299 * fill.red + 0.587 * fill.green + 0.114 * fill.blue > 0.6 ? .black : .white
        text.outlineWidth = 0
        text.alignment = .center
        text.tail = .zero
        var layer = Layer(name: "Speech Bubble", content: .text(text))
        let size = layer.frameBounds.size
        var center = point
        if tip.distance(to: point) * canvas.scale < 6 {
            let reach = max(size.height * 1.6, 60)
            center = CGPoint(x: tip.x + reach, y: tip.y - reach)
        }
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        layer.transform = CGAffineTransform(translationX: origin.x, y: origin.y)
        text.tail = tip - origin
        layer.content = .text(text)
        document.addLayer(layer, name: "Add Speech Bubble")
        beginEditing(layer.id)
    }

    override func cursor(at point: CGPoint) -> NSCursor {
        if document.activeLayer?.text != nil, let cursor = frame.cursor(at: point) { return cursor }
        if let session { return session.contains(point) ? .iBeam : .arrow }
        if let hit = layer(at: point), hit.text != nil { return .openHand }
        return model.tool == .callout ? .crosshair : .iBeam
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        if let bubble {
            let a = canvas.viewPoint(fromImage: bubble.tip), b = canvas.viewPoint(fromImage: bubble.place)
            context.saveGState()
            for (color, width) in [(CGColor.black, CGFloat(3)), (CGColor.white, CGFloat(1.5))] {
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.move(to: a)
                context.addLine(to: b)
                context.strokePath()
            }
            context.restoreGState()
        }
        if document.activeLayer?.text != nil { frame.draw(in: context, canvas: canvas) }
        session?.draw(in: context, canvas: canvas)
    }

    override func keyDown(_ event: NSEvent) -> Bool {
        // Return on a selected text starts typing into it.
        if event.keyCode == 36 || event.keyCode == 76, let id = document.activeLayerID, document.activeLayer?.text != nil {
            beginEditing(id)
            return true
        }
        return editor.nudgeActiveLayer(with: event)
    }
}

/// Lines, arrows, boxes, ellipses and freehand strokes. Each becomes an object layer that stays editable.
final class ShapeTool: EditorTool {
    private lazy var frame = FrameInteraction(editor: editor)
    private var draft: ShapeContent?
    private var start: CGPoint?

    private func isEditableShape(_ layer: Layer?) -> Bool {
        guard let kind = layer?.shape?.kind else { return false }
        return kind != .freehand && kind != .highlighter
    }

    private func makeShape(kind: ShapeKind, at point: CGPoint) -> ShapeContent {
        var shape = ShapeContent(kind: kind, points: kind == .freehand || kind == .highlighter ? [point] : [point, point])
        shape.strokeColor = model.primaryColor
        shape.strokeWidth = model.strokeWidth
        shape.cornerRadius = model.cornerRadius
        if kind == .highlighter {
            shape.strokeColor.alpha = 0.4
            shape.strokeWidth = max(model.strokeWidth * 3, 14)
        }
        if model.fillsShapes, kind == .rectangle || kind == .ellipse { shape.fillColor = model.secondaryColor }
        if kind == .badge {
            shape.label = String(document.nextBadgeNumber)
            shape.points = Self.badgeBox(center: point, diameter: badgeDiameter)
        }
        return shape
    }

    /// As large as the last badge, or a size that reads well on this picture.
    private var badgeDiameter: CGFloat {
        model.badgeSize ?? Self.defaultBadgeDiameter(for: document.size)
    }

    static func defaultBadgeDiameter(for size: CGSize) -> CGFloat {
        max(28, (max(size.width, size.height) / 20).rounded())
    }

    private static func badgeBox(center: CGPoint, diameter: CGFloat) -> [CGPoint] {
        let radius = diameter / 2
        return [CGPoint(x: center.x - radius, y: center.y - radius), CGPoint(x: center.x + radius, y: center.y + radius)]
    }

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        if isEditableShape(document.activeLayer), frame.beginHandleDrag(at: point) { return }
        guard let kind = model.tool.shapeKind else { return }
        start = point
        draft = makeShape(kind: kind, at: point)
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        if frame.isDragging {
            frame.drag(to: point, event: event)
            return
        }
        guard var shape = draft, let start else { return }
        let shift = event.modifierFlags.contains(.shift)
        switch shape.kind {
        case .freehand, .highlighter:
            if let last = shape.points.last, last.distance(to: point) * canvas.scale > 1.5 { shape.points.append(point) }
        case .line, .arrow:
            shape.points[1] = shift ? FrameInteraction.snapAngle(from: start, to: point) : point
        case .badge:
            // A click drops a badge of the usual size; pulling away from the spot sizes it.
            let radius = start.distance(to: point)
            let diameter = radius * canvas.scale > 6 ? max(radius * 2, 12) : badgeDiameter
            shape.points = Self.badgeBox(center: start, diameter: diameter)
        case .rectangle, .ellipse:
            var end = point
            if shift {
                let side = max(abs(point.x - start.x), abs(point.y - start.y))
                end = CGPoint(x: start.x + (point.x < start.x ? -side : side), y: start.y + (point.y < start.y ? -side : side))
            }
            shape.points[1] = end
        }
        draft = shape
        redrawOverlay()
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        if frame.isDragging {
            frame.end()
            return
        }
        defer {
            draft = nil
            start = nil
            redrawOverlay()
        }
        guard let shape = draft else { return }
        let extent = shape.pointBounds
        guard max(extent.width, extent.height) * canvas.scale > 3 else { return }
        if shape.kind == .badge { model.badgeSize = extent.width }
        var layer = Layer(name: model.tool.title, content: .shape(shape))
        if shape.kind == .highlighter { layer.blendMode = .multiply }
        document.addLayer(layer, name: "Add \(model.tool.title)")
    }

    override func cursor(at point: CGPoint) -> NSCursor {
        if isEditableShape(document.activeLayer), let cursor = frame.cursor(at: point) { return cursor }
        return .crosshair
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        if let draft {
            // Draw the real shape, scaled to the view, so the preview matches the result exactly.
            context.saveGState()
            let origin = canvas.viewPoint(fromImage: .zero)
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: canvas.scale, y: canvas.scale)
            ObjectRenderer.drawPreview(draft, in: context)
            context.restoreGState()
        } else if isEditableShape(document.activeLayer) {
            frame.draw(in: context, canvas: canvas)
        }
    }

    override func keyDown(_ event: NSEvent) -> Bool {
        editor.nudgeActiveLayer(with: event)
    }
}

/// Drags out an area that blurs or pixelates whatever is under it.
final class RegionTool: EditorTool {
    private lazy var frame = FrameInteraction(editor: editor)
    private var start: CGPoint?
    private var current: CGPoint?

    override func mouseDown(at point: CGPoint, event: NSEvent) {
        if document.activeLayer?.effectRegion != nil, frame.beginHandleDrag(at: point) { return }
        if let hit = layer(at: point), hit.effectRegion != nil {
            document.setActiveLayer(hit.id)
            frame.beginMove(at: point)
            return
        }
        start = point
        current = point
    }

    override func mouseDragged(to point: CGPoint, event: NSEvent) {
        if frame.isDragging {
            frame.drag(to: point, event: event)
            return
        }
        current = point
        redrawOverlay()
    }

    override func mouseUp(at point: CGPoint, event: NSEvent) {
        if frame.isDragging {
            frame.end()
            return
        }
        defer {
            start = nil
            current = nil
            redrawOverlay()
        }
        guard let start else { return }
        let rect = CGRect(from: start, to: point)
        guard min(rect.width, rect.height) * canvas.scale > 4 else { return }
        let effect = model.tool.regionEffect ?? .blur
        var region = EffectRegion(effect: effect, size: rect.size)
        if effect == .spotlight {
            region.amount = 60
        } else {
            // Scale the default strength with the picture, so a 12 MP photo is not left readable.
            region.amount = model.fixedRegionAmount
                ?? max(model.regionAmount, (max(document.size.width, document.size.height) / 110).rounded())
        }
        var layer = Layer(name: effect.title, content: .effect(region))
        layer.transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        document.addLayer(layer, name: effect == .spotlight ? "Add Spotlight" : "Add \(layer.name) Area")
    }

    override func drawOverlay(in context: CGContext, canvas: CanvasView) {
        if let start, let current {
            let rect = CGRect(from: canvas.viewPoint(fromImage: start), to: canvas.viewPoint(fromImage: current))
            context.saveGState()
            context.setStrokeColor(.white)
            context.setLineWidth(1.5)
            context.stroke(rect)
            context.setStrokeColor(.black)
            context.setLineDash(phase: 0, lengths: [5, 5])
            context.stroke(rect)
            context.restoreGState()
        } else if document.activeLayer?.effectRegion != nil {
            frame.draw(in: context, canvas: canvas)
        }
    }

    override func cursor(at point: CGPoint) -> NSCursor {
        if document.activeLayer?.effectRegion != nil, let cursor = frame.cursor(at: point) { return cursor }
        if let hit = layer(at: point), hit.effectRegion != nil { return .openHand }
        return .crosshair
    }

    override func keyDown(_ event: NSEvent) -> Bool {
        editor.nudgeActiveLayer(with: event)
    }
}
