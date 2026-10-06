import AppKit
import PixixEngine

/// The handles around the active layer: dragging them moves, resizes and rotates it.
/// Shared by every tool that leaves an object on the canvas.
@MainActor
final class FrameInteraction {
    enum Handle: Equatable {
        /// 0 top-left, then clockwise.
        case corner(Int)
        /// 0 top, 1 right, 2 bottom, 3 left.
        case edge(Int)
        case rotate
        /// An end of a line or arrow.
        case endpoint(Int)
    }

    private enum Drag {
        case move(original: Layer, start: CGPoint)
        case scale(Handle, original: Layer)
        case rotate(original: Layer, center: CGPoint, startAngle: CGFloat)
        case endpoint(Int, original: Layer)
    }

    private unowned let editor: EditorController
    private var drag: Drag?

    init(editor: EditorController) {
        self.editor = editor
    }

    var isDragging: Bool { drag != nil }

    private var document: Document { editor.document }
    private var canvas: CanvasView { editor.canvas }

    /// Distance in image pixels that counts as "on the handle".
    private var reach: CGFloat { 9 / max(canvas.scale, 0.0001) }

    private func isLine(_ layer: Layer) -> Bool {
        layer.shape.map { $0.kind == .line || $0.kind == .arrow } ?? false
    }

    /// Handle positions in document coordinates.
    func handles(for layer: Layer) -> [(Handle, CGPoint)] {
        if let shape = layer.shape, isLine(layer), shape.points.count >= 2 {
            return [
                (.endpoint(0), shape.points[0].applying(layer.transform)),
                (.endpoint(1), shape.points[1].applying(layer.transform)),
            ]
        }
        let corners = layer.corners
        var result: [(Handle, CGPoint)] = corners.enumerated().map { (.corner($0.offset), $0.element) }
        let mids = (0..<4).map { index -> CGPoint in
            let a = corners[index], b = corners[(index + 1) % 4]
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        // Text scales as a whole, so side handles would only confuse.
        if layer.text == nil {
            result += mids.enumerated().map { (.edge($0.offset), $0.element) }
        }
        let center = CGPoint(x: (corners[0].x + corners[2].x) / 2, y: (corners[0].y + corners[2].y) / 2)
        let outward = mids[0] - center
        let length = max(outward.length, 0.0001)
        result.append((.rotate, mids[0] + outward * (26 / max(canvas.scale, 0.0001) / length)))
        return result
    }

    func handle(at point: CGPoint) -> Handle? {
        guard let layer = document.activeLayer, !layer.isLocked, layer.isVisible else { return nil }
        return handles(for: layer).min { $0.1.distance(to: point) < $1.1.distance(to: point) }
            .flatMap { $0.1.distance(to: point) <= reach ? $0.0 : nil }
    }

    /// Starts dragging a handle of the active layer if one is under the point.
    func beginHandleDrag(at point: CGPoint) -> Bool {
        guard let layer = document.activeLayer, let handle = handle(at: point) else { return false }
        switch handle {
        case .rotate:
            let center = layer.localBounds.center.applying(layer.transform)
            drag = .rotate(original: layer, center: center, startAngle: atan2(point.y - center.y, point.x - center.x))
        case .endpoint(let index):
            drag = .endpoint(index, original: layer)
        default:
            drag = .scale(handle, original: layer)
        }
        return true
    }

    func beginMove(at point: CGPoint) {
        guard let layer = document.activeLayer, !layer.isLocked else { return }
        drag = .move(original: layer, start: point)
    }

    func drag(to point: CGPoint, event: NSEvent) {
        guard let drag else { return }
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        var layer: Layer
        let name: String
        switch drag {
        case .move(let original, let start):
            layer = original
            name = "Move"
            var delta = point - start
            if shift {
                if abs(delta.x) > abs(delta.y) { delta.y = 0 } else { delta.x = 0 }
            } else {
                delta = snapped(delta, bounds: original.documentBounds)
            }
            layer.transform = original.transform.concatenating(CGAffineTransform(translationX: delta.x, y: delta.y))

        case .scale(let handle, let original):
            layer = original
            name = "Resize"
            guard abs(original.transform.a * original.transform.d - original.transform.b * original.transform.c) > 1e-9 else { return }
            let box = original.localBounds
            let local = point.applying(original.transform.inverted())
            var grip: CGPoint, anchor: CGPoint
            var scalesX = true, scalesY = true
            switch handle {
            case .corner(let index):
                let points = [
                    CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
                ]
                grip = points[index]
                anchor = points[(index + 2) % 4]
            case .edge(let index):
                let points = [
                    CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.midY),
                    CGPoint(x: box.midX, y: box.maxY), CGPoint(x: box.minX, y: box.midY),
                ]
                grip = points[index]
                anchor = points[(index + 2) % 4]
                scalesX = index % 2 == 1
                scalesY = index % 2 == 0
            default:
                return
            }
            if option { anchor = box.center }
            var sx: CGFloat = 1, sy: CGFloat = 1
            if scalesX, abs(grip.x - anchor.x) > 1e-6 { sx = max((local.x - anchor.x) / (grip.x - anchor.x), 0.01) }
            if scalesY, abs(grip.y - anchor.y) > 1e-6 { sy = max((local.y - anchor.y) / (grip.y - anchor.y), 0.01) }
            if case .corner = handle {
                // Pictures and text keep their proportions unless Shift is held; shapes and areas do the opposite.
                let proportionalByDefault = original.isRaster || original.text != nil
                if proportionalByDefault != shift {
                    let uniform = max(sx, sy)
                    sx = uniform
                    sy = uniform
                }
            }
            layer.scale(x: sx, y: sy, aboutLocal: anchor)

        case .rotate(let original, let center, let startAngle):
            layer = original
            name = "Rotate"
            var angle = atan2(point.y - center.y, point.x - center.x) - startAngle
            if shift {
                let step = CGFloat.pi / 12
                angle = (angle / step).rounded() * step
            }
            layer.transform = original.transform.concatenating(.rotation(angle, about: center))

        case .endpoint(let index, let original):
            layer = original
            name = "Edit Line"
            guard var shape = original.shape, shape.points.count >= 2 else { return }
            var target = point
            if shift {
                let other = shape.points[1 - index].applying(original.transform)
                target = Self.snapAngle(from: other, to: point)
            }
            shape.points[index] = target.applying(original.transform.inverted())
            layer.content = .shape(shape)
        }
        let updated = layer
        document.updateLayer(layer.id, name: name, key: "frame") { $0 = updated }
    }

    func end() {
        guard drag != nil else { return }
        drag = nil
        document.endInteraction()
    }

    /// Pulls a dragged box onto the canvas edges and center lines when it comes close.
    private func snapped(_ delta: CGPoint, bounds: CGRect) -> CGPoint {
        let threshold = 6 / max(canvas.scale, 0.0001)
        let size = document.size
        var result = delta
        let moved = bounds.offsetBy(dx: delta.x, dy: delta.y)
        let xPairs = [(moved.minX, CGFloat(0)), (moved.maxX, size.width), (moved.midX, size.width / 2)]
        if let best = xPairs.map({ $0.1 - $0.0 }).min(by: { abs($0) < abs($1) }), abs(best) <= threshold { result.x += best }
        let yPairs = [(moved.minY, CGFloat(0)), (moved.maxY, size.height), (moved.midY, size.height / 2)]
        if let best = yPairs.map({ $0.1 - $0.0 }).min(by: { abs($0) < abs($1) }), abs(best) <= threshold { result.y += best }
        return result
    }

    /// Constrains a direction to multiples of 45°.
    static func snapAngle(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let delta = point - origin
        let step = CGFloat.pi / 4
        let angle = (atan2(delta.y, delta.x) / step).rounded() * step
        return CGPoint(x: origin.x + cos(angle) * delta.length, y: origin.y + sin(angle) * delta.length)
    }

    func cursor(at point: CGPoint) -> NSCursor? {
        guard let handle = handle(at: point) else { return nil }
        switch handle {
        case .rotate: return .crosshair
        default: return .pointingHand
        }
    }

    func draw(in context: CGContext, canvas: CanvasView) {
        guard let layer = document.activeLayer, layer.isVisible else { return }
        let accent = NSColor.controlAccentColor.cgColor
        context.saveGState()
        context.setStrokeColor(accent)
        context.setLineWidth(1)
        let positions = handles(for: layer).map { ($0.0, canvas.viewPoint(fromImage: $0.1)) }
        if !isLine(layer) {
            let corners = layer.corners.map { canvas.viewPoint(fromImage: $0) }
            context.addLines(between: corners)
            context.closePath()
            context.strokePath()
            if let rotate = positions.first(where: { $0.0 == .rotate })?.1 {
                context.move(to: CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2))
                context.addLine(to: rotate)
                context.strokePath()
            }
        }
        guard !layer.isLocked else {
            context.restoreGState()
            return
        }
        context.setFillColor(.white)
        context.setLineWidth(1.5)
        for (handle, position) in positions {
            let rect = CGRect(x: position.x - 4.5, y: position.y - 4.5, width: 9, height: 9)
            switch handle {
            case .rotate, .endpoint:
                context.fillEllipse(in: rect.insetBy(dx: -1, dy: -1))
                context.strokeEllipse(in: rect.insetBy(dx: -1, dy: -1))
            default:
                context.fill(rect)
                context.stroke(rect)
            }
        }
        context.restoreGState()
    }
}
