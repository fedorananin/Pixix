import AppKit
import IOSurface

@MainActor
protocol CanvasViewDelegate: AnyObject {
    func canvas(_ canvas: CanvasView, navigateBy delta: Int)
    func canvasViewportDidChange(_ canvas: CanvasView)
    func canvasPointerDidMove(_ canvas: CanvasView)
    /// Return true when the key was handled.
    func canvas(_ canvas: CanvasView, keyDown event: NSEvent) -> Bool
    func canvas(_ canvas: CanvasView, didReceive pasteboard: NSPasteboard, at imagePoint: CGPoint) -> Bool
}

/// Receives pointer input in image coordinates while the editor is active.
@MainActor
protocol CanvasToolHandler: AnyObject {
    func toolMouseDown(at point: CGPoint, event: NSEvent)
    func toolMouseDragged(to point: CGPoint, event: NSEvent)
    func toolMouseUp(at point: CGPoint, event: NSEvent)
    func toolMouseMoved(to point: CGPoint, event: NSEvent)
    func toolCursor(at point: CGPoint) -> NSCursor
    func toolFlagsChanged(_ event: NSEvent)
    func drawOverlay(in context: CGContext, canvas: CanvasView)
}

/// Shows an image with zoom and pan. Coordinates are top-left based, in image pixels.
final class CanvasView: NSView {
    weak var delegate: CanvasViewDelegate?
    weak var toolHandler: CanvasToolHandler? {
        didSet { overlay.needsDisplay = true }
    }

    /// The viewer browses with swipes; the editor never does.
    var allowsNavigation = true
    /// Extra room around the image when fitting, in points.
    var fitPadding: CGFloat = 0 {
        didSet { if isFitted { fit() } }
    }
    /// How far the image may be dragged past the view edge, as a fraction of the view.
    var panSlack: CGFloat = 0
    var showsCheckerboard = false {
        didSet { checkerLayer.isHidden = !showsCheckerboard }
    }

    private(set) var contentSize: CGSize = .zero
    /// View points per image pixel.
    private(set) var scale: CGFloat = 1
    /// The image point shown at the middle of the view.
    private var focus: CGPoint = .zero
    /// True while the image follows the window size.
    private(set) var isFitted = true

    private let checkerLayer = CALayer()
    private let imageLayer = CALayer()
    /// Covers the whole view; the editor draws the selection outline into it.
    let selectionLayer = CALayer()
    /// Turns the picture on screen without changing it, to preview straightening. Radians, about an image point.
    private var previewRotation: (angle: CGFloat, center: CGPoint)?
    private let overlay = CanvasOverlayView()
    private var trackingArea: NSTrackingArea?

    private enum ScrollGesture { case undecided, pan, navigate, done }
    private var scrollGesture = ScrollGesture.undecided
    private var swipeDistance: CGFloat = 0
    private var lastSidewaysWheel: TimeInterval = 0
    private var wheelLatch: (overImage: Bool, location: CGPoint, time: TimeInterval)?
    private var isPanningWithMouse = false
    private var isSpaceDown = false
    private var lastDragLocation: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        layer?.masksToBounds = true

        checkerLayer.backgroundColor = Self.checkerColor
        checkerLayer.isHidden = true
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        checkerLayer.actions = imageLayer.actions
        selectionLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        selectionLayer.contentsGravity = .resize
        layer?.addSublayer(checkerLayer)
        layer?.addSublayer(imageLayer)
        layer?.addSublayer(selectionLayer)

        overlay.canvas = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let checkerColor: CGColor = {
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor(white: 0.78, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.62, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }()

    // MARK: Content

    /// Sets the logical pixel size. The picture itself may be a smaller preview.
    func setContentSize(_ size: CGSize, resetView: Bool) {
        let changed = size != contentSize
        contentSize = size
        if resetView || (changed && isFitted) {
            isFitted = true
            fit()
        } else if changed {
            clampFocus()
            updateLayers()
        }
    }

    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func setSurface(_ surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface
        CATransaction.commit()
    }

    func setOverlayNeedsDisplay() {
        overlay.needsDisplay = true
    }

    func setPreviewRotation(_ angle: CGFloat, about center: CGPoint) {
        previewRotation = angle == 0 ? nil : (angle, center)
        updateLayers()
    }

    /// Size of the view in screen pixels.
    var pixelSize: CGSize {
        CGSize(width: (bounds.width * backingScale).rounded(), height: (bounds.height * backingScale).rounded())
    }

    var backingScaleFactor: CGFloat { backingScale }

    // MARK: Geometry

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Scale at which one image pixel covers one screen pixel.
    var actualSizeScale: CGFloat { 1 / backingScale }

    var fitScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        let available = CGSize(
            width: max(bounds.width - fitPadding * 2, 10), height: max(bounds.height - fitPadding * 2, 10)
        )
        let fit = min(available.width / contentSize.width, available.height / contentSize.height)
        // Small images are shown at their real size rather than blown up.
        return min(fit, actualSizeScale)
    }

    var zoomPercent: Int { Int((scale * backingScale * 100).rounded()) }

    /// The longer side of the view in screen pixels; previews are decoded to this size.
    var pixelExtent: Int { Int(max(bounds.width, bounds.height) * backingScale) }

    var imageRect: CGRect {
        CGRect(
            x: bounds.midX - focus.x * scale, y: bounds.midY - focus.y * scale,
            width: contentSize.width * scale, height: contentSize.height * scale
        )
    }

    func viewPoint(fromImage point: CGPoint) -> CGPoint {
        CGPoint(x: bounds.midX + (point.x - focus.x) * scale, y: bounds.midY + (point.y - focus.y) * scale)
    }

    func imagePoint(fromView point: CGPoint) -> CGPoint {
        CGPoint(x: focus.x + (point.x - bounds.midX) / scale, y: focus.y + (point.y - bounds.midY) / scale)
    }

    private func clampFocus() {
        func clamp(_ value: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            let visible = view / scale
            let slack = panSlack * visible
            if content <= visible, slack == 0 { return content / 2 }
            let low = min(visible / 2 - slack, content / 2), high = max(content - visible / 2 + slack, content / 2)
            return min(max(value, low), high)
        }
        focus.x = clamp(focus.x, content: contentSize.width, view: bounds.width)
        focus.y = clamp(focus.y, content: contentSize.height, view: bounds.height)
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = imageRect
        for layer in [imageLayer, checkerLayer] {
            layer.setAffineTransform(.identity)
            layer.frame = rect
        }
        if let previewRotation {
            // Rotate about the given image point: move it to the layer's center, turn, move back.
            let pivot = viewPoint(fromImage: previewRotation.center)
            let offset = CGPoint(x: pivot.x - rect.midX, y: pivot.y - rect.midY)
            let turn = CGAffineTransform(translationX: -offset.x, y: -offset.y)
                .concatenating(CGAffineTransform(rotationAngle: previewRotation.angle))
                .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
            imageLayer.setAffineTransform(turn)
            checkerLayer.setAffineTransform(turn)
        }
        selectionLayer.frame = bounds
        imageLayer.magnificationFilter = scale * backingScale >= 4 ? .nearest : .linear
        CATransaction.commit()
        overlay.needsDisplay = true
        delegate?.canvasViewportDidChange(self)
    }

    override func layout() {
        super.layout()
        if isFitted {
            scale = fitScale
            focus = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        } else {
            clampFocus()
        }
        updateLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // MARK: Zoom

    func fit() {
        isFitted = true
        scale = fitScale
        focus = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        updateLayers()
    }

    func zoomToActualSize(anchor: CGPoint? = nil) {
        setScale(actualSizeScale, anchor: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        setScale(scale * factor, anchor: anchor ?? CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Steps through round zoom levels, the way the + and − buttons should feel.
    func zoomStep(_ direction: Int) {
        let levels: [CGFloat] = [0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 32, 64]
        let current = scale * backingScale
        let target: CGFloat?
        if direction > 0 {
            target = levels.first { $0 > current * 1.01 }
        } else {
            target = levels.last { $0 < current * 0.99 }
        }
        if let target { setScale(target / backingScale, anchor: CGPoint(x: bounds.midX, y: bounds.midY)) }
    }

    /// One notch of a mouse wheel. The levels are evenly spaced inside each doubling: 50, 60 … 100, 120 … 200.
    /// The step does not depend on how fast the wheel turns, so the same notches always land on the same zoom.
    func zoomNotch(_ direction: Int, anchor: CGPoint) {
        guard contentSize.width > 0 else { return }
        let current = scale * backingScale
        // Nudged so that a level reached a moment ago is not chosen again because of rounding.
        let nudged = current * (direction > 0 ? 1.01 : 0.99)
        let base = pow(2, floor(log2(nudged)))
        let step = base / 5
        let index = (nudged - base) / step
        let target = base + step * (direction > 0 ? floor(index) + 1 : ceil(index) - 1)
        // Fit is a stop on the way through, otherwise the wheel could never come back to it.
        let fitted = fitScale * backingScale
        if abs(current - fitted) > fitted * 0.01, (current - fitted) * (target - fitted) < 0 {
            fit()
        } else {
            setScale(target / backingScale, anchor: anchor)
        }
    }

    func toggleFitAndActualSize(anchor: CGPoint) {
        if isFitted {
            // When the fitted image is already at 100%, there is nothing to toggle to except a closer look.
            let target = abs(fitScale - actualSizeScale) < 0.001 ? actualSizeScale * 2 : actualSizeScale
            setScale(target, anchor: anchor)
        } else {
            fit()
        }
    }

    private func setScale(_ newScale: CGFloat, anchor: CGPoint) {
        guard contentSize.width > 0 else { return }
        let minimum = min(fitScale, actualSizeScale) * 0.5
        let maximum = 64 / backingScale
        let clamped = min(max(newScale, minimum), maximum)
        let pinned = imagePoint(fromView: anchor)
        scale = clamped
        // Keep the image point under the cursor where it was.
        focus = CGPoint(
            x: pinned.x - (anchor.x - bounds.midX) / scale, y: pinned.y - (anchor.y - bounds.midY) / scale
        )
        isFitted = false
        clampFocus()
        updateLayers()
    }

    private func pan(by delta: CGPoint) {
        guard !isFitted || panSlack > 0 else { return }
        isFitted = false
        focus.x -= delta.x / scale
        focus.y -= delta.y / scale
        clampFocus()
        updateLayers()
    }

    private var canPanHorizontally: Bool { contentSize.width * scale > bounds.width + 0.5 }

    private func isAtHorizontalEdge(movingContentLeft: Bool) -> Bool {
        let rect = imageRect
        return movingContentLeft ? rect.maxX <= bounds.maxX + 0.5 : rect.minX >= bounds.minX - 0.5
    }

    // MARK: Scrolling and gestures

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard event.hasPreciseScrollingDeltas else {
            mouseWheel(with: event, overImage: wheelIsOverImage(event, at: location))
            return
        }
        if event.modifierFlags.contains(.command) {
            guard event.scrollingDeltaY != 0 else { return }
            zoom(by: exp(event.scrollingDeltaY * 0.01), anchor: location)
            return
        }

        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            scrollGesture = .undecided
            swipeDistance = 0
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if scrollGesture == .undecided {
            guard abs(dx) + abs(dy) > 0 else { return }
            let horizontal = abs(dx) > abs(dy)
            let blocked = !canPanHorizontally || isAtHorizontalEdge(movingContentLeft: dx < 0)
            scrollGesture = allowsNavigation && horizontal && blocked ? .navigate : .pan
        }
        switch scrollGesture {
        case .pan:
            pan(by: CGPoint(x: dx, y: dy))
        case .navigate:
            guard event.momentumPhase.isEmpty else { return }
            swipeDistance += dx
            if abs(swipeDistance) > 40 {
                scrollGesture = .done
                delegate?.canvas(self, navigateBy: swipeDistance < 0 ? 1 : -1)
            }
        case .undecided, .done:
            break
        }
    }

    /// Zooming out and turning the page both change what is under the pointer. While the wheel keeps turning in
    /// one spot it goes on doing what it started with, instead of switching between zooming and paging halfway.
    private func wheelIsOverImage(_ event: NSEvent, at location: CGPoint) -> Bool {
        var overImage = imageRect.intersection(bounds).contains(location)
        if let latch = wheelLatch, event.timestamp - latch.time < 1,
           hypot(location.x - latch.location.x, location.y - latch.location.y) < 4 {
            overImage = latch.overImage
        }
        wheelLatch = (overImage, location, event.timestamp)
        return overImage
    }

    /// A notched mouse wheel. Over the picture it zooms, anywhere else it pages through the folder, and a
    /// sideways wheel always pages. `overImage` is false for the background and for the controls laid over the canvas.
    func mouseWheel(with event: NSEvent, overImage: Bool) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if abs(dx) > abs(dy) {
            guard allowsNavigation else {
                pan(by: CGPoint(x: dx * 10, y: 0))
                return
            }
            // A tilt wheel repeats while it is held and a thumb wheel has no notches; neither should race through the folder.
            guard event.timestamp - lastSidewaysWheel > 0.1 else { return }
            lastSidewaysWheel = event.timestamp
            delegate?.canvas(self, navigateBy: dx < 0 ? 1 : -1)
            return
        }
        guard dy != 0 else { return }
        let zooms = event.modifierFlags.contains(.command)
            || (Settings.shared.wheelZooms && (overImage || !allowsNavigation))
        if zooms {
            zoomNotch(dy > 0 ? 1 : -1, anchor: convert(event.locationInWindow, from: nil))
        } else if allowsNavigation, !overImage || isFitted {
            delegate?.canvas(self, navigateBy: dy < 0 ? 1 : -1)
        } else {
            pan(by: CGPoint(x: 0, y: dy * 10))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, anchor: convert(event.locationInWindow, from: nil))
        if event.phase.contains(.ended), scale < fitScale { fit() }
    }

    override func smartMagnify(with event: NSEvent) {
        toggleFitAndActualSize(anchor: convert(event.locationInWindow, from: nil))
    }

    override func swipe(with event: NSEvent) {
        guard allowsNavigation, event.deltaX != 0 else { return }
        delegate?.canvas(self, navigateBy: event.deltaX < 0 ? 1 : -1)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func usesTool(_ event: NSEvent) -> Bool {
        toolHandler != nil && !isSpaceDown
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if usesTool(event) {
            toolHandler?.toolMouseDown(at: imagePoint(fromView: location), event: event)
            return
        }
        if event.clickCount == 2, toolHandler == nil {
            toggleFitAndActualSize(anchor: location)
            return
        }
        if toolHandler == nil, isFitted {
            // Nothing to pan: let the picture move the window, as a title bar would.
            window?.performDrag(with: event)
            return
        }
        isPanningWithMouse = true
        lastDragLocation = location
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isPanningWithMouse {
            pan(by: CGPoint(x: location.x - lastDragLocation.x, y: location.y - lastDragLocation.y))
            lastDragLocation = location
            return
        }
        toolHandler?.toolMouseDragged(to: imagePoint(fromView: location), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isPanningWithMouse {
            isPanningWithMouse = false
            updateCursor(at: location)
            return
        }
        toolHandler?.toolMouseUp(at: imagePoint(fromView: location), event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        delegate?.canvasPointerDidMove(self)
        guard bounds.contains(location) else { return }
        updateCursor(at: location)
        if usesTool(event) {
            toolHandler?.toolMouseMoved(to: imagePoint(fromView: location), event: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func updateCursor(at location: CGPoint) {
        if isSpaceDown {
            NSCursor.openHand.set()
        } else if let toolHandler {
            toolHandler.toolCursor(at: imagePoint(fromView: location)).set()
        } else if !isFitted {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if toolHandler != nil, event.keyCode == 49 {
            // Holding Space pans in the editor, as in every other image editor.
            if !event.isARepeat {
                isSpaceDown = true
                NSCursor.openHand.set()
            }
            return
        }
        if delegate?.canvas(self, keyDown: event) != true {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, isSpaceDown {
            isSpaceDown = false
            if let window {
                updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
            }
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        toolHandler?.toolFlagsChanged(event)
        super.flagsChanged(with: event)
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let location = convert(sender.draggingLocation, from: nil)
        return delegate?.canvas(self, didReceive: sender.draggingPasteboard, at: imagePoint(fromView: location)) ?? false
    }
}

/// Transparent layer above the image where tools draw handles, frames and guides.
final class CanvasOverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let handler = canvas.toolHandler, let context = NSGraphicsContext.current?.cgContext else { return }
        handler.drawOverlay(in: context, canvas: canvas)
    }
}
