import AppKit
import Carbon.HIToolbox
import PixixCodec
import PixixEngine
import SwiftUI
import VisionKit

/// The borderless window that covers one display during a capture.
final class CapturePanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var cancelHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyEquivalentHandler?(event) == true || super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

/// Holds the frozen screen and the panels on it. Flipped, so panels are placed in the canvas's own coordinates.
final class CaptureContentView: NSView {
    var onMouseEntered: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }
}

/// One display during a capture: the frozen picture of it, the selection drawn on it, and the small editor
/// that marks the selection up. The picture becomes an ordinary document, so the markup tools are the
/// editor's own and the result can move into a full editor window with its layers intact.
@MainActor
final class CaptureScreenController: NSObject, CanvasToolHandler, CanvasViewDelegate, EditorHost {
    unowned let session: CaptureSession
    let shot: ScreenShot
    let panel: CapturePanel
    let canvas = CanvasView()
    let model = CaptureModel()
    private(set) var editor: EditorController?
    var window: NSWindow? { panel }

    /// The chosen part of the screen in image pixels. Nil until one is drawn.
    private(set) var selection: CGRect?

    private enum Drag {
        /// A new selection pulled out from a corner. `previous` comes back if it turns out to be a stray click.
        case new(anchor: CGPoint, previous: CGRect?, moved: Bool)
        case handle(Int, original: CGRect)
        case move(start: CGPoint, original: CGRect)
        case tool
    }

    private let content = CaptureContentView()
    private var drag: Drag?
    private var hoveredWindow: CGRect?
    private var statusWork: DispatchWorkItem?
    private var isClosed = false

    private var sizeView: NSView?
    private var toolsView: NSView?
    private var actionsView: NSView?
    private var toolsSize = CGSize.zero
    private var actionsSize = CGSize.zero
    private var sizeLeading, sizeTop, toolsTrailing, toolsBottom, actionsTrailing, actionsTop: NSLayoutConstraint?

    private var bounds: CGRect { CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height) }
    /// How far from a handle or an edge still counts as on it, in image pixels.
    private var reach: CGFloat { 7 / max(canvas.scale, 0.0001) }
    private var ratio: CGFloat? { model.aspect?.ratio }

    init(session: CaptureSession, shot: ScreenShot) {
        self.session = session
        self.shot = shot
        panel = CapturePanel(contentRect: shot.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        model.screen = self

        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        // Above the Dock and the menu bar, and just under menus, so the size menu can open over it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.keyEquivalentHandler = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
        panel.cancelHandler = { [weak self] in self?.cancel() }

        content.frame = CGRect(origin: .zero, size: shot.frame.size)
        content.onMouseEntered = { [weak self] in self?.pointerEntered() }
        panel.contentView = content
        canvas.frame = content.bounds
        canvas.autoresizingMask = [.width, .height]
        content.addSubview(canvas)
        canvas.delegate = self
        canvas.toolHandler = self
        canvas.allowsNavigation = false
        canvas.locksView = true
        canvas.acceptsFirstClick = true
        canvas.setContentSize(bounds.size, resetView: true)
        canvas.setImage(shot.image)

        let size = host(CaptureSizeView(model: model, screen: self))
        sizeLeading = size.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        sizeTop = size.topAnchor.constraint(equalTo: content.topAnchor)
        NSLayoutConstraint.activate([sizeLeading, sizeTop].compactMap { $0 })
        sizeView = size
    }

    // MARK: Showing and closing

    func show() {
        panel.setFrame(shot.frame, display: false)
        if session.isUnattended {
            // A scripted run draws its overlay where no screen is, as the viewer windows of such runs do.
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderBack(nil)
            panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        } else {
            panel.orderFrontRegardless()
        }
        panel.makeFirstResponder(canvas)
    }

    func setHidden(_ hidden: Bool) {
        if hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        statusWork?.cancel()
        // A scripted run leaves the user's preferences as it found them.
        if let tools = editor?.model, !session.isUnattended {
            if CaptureToolGroup.allTools.contains(tools.tool) { Settings.shared.captureTool = tools.tool.rawValue }
            Settings.shared.captureColor = tools.primaryColor
        }
        editor?.deactivate()
        editor = nil
        canvas.toolHandler = nil
        canvas.delegate = nil
        // The panels hold this object; without them nothing keeps the window and its pictures alive.
        for view in [sizeView, toolsView, actionsView] { view?.removeFromSuperview() }
        sizeView = nil
        toolsView = nil
        actionsView = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// The pointer came onto this display: its overlay takes the keyboard.
    private func pointerEntered() {
        guard !session.isUnattended, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    func cancel() {
        session.end()
    }

    // MARK: The selection

    var hasMarkup: Bool { (editor?.document.layers.count ?? 0) > 1 }

    private func rounded(_ rect: CGRect) -> CGRect {
        let whole = CGRect(
            x: rect.minX.rounded(), y: rect.minY.rounded(), width: max(rect.width.rounded(), 1), height: max(rect.height.rounded(), 1)
        )
        return FrameGeometry.moved(whole, into: bounds)
    }

    private func setSelection(_ rect: CGRect?) {
        selection = rect
        model.width = Int((rect?.width ?? 0).rounded())
        model.height = Int((rect?.height ?? 0).rounded())
        layoutPanels()
        canvas.setOverlayNeedsDisplay()
    }

    /// Another display starts a selection of its own.
    func clearSelection() {
        guard selection != nil else { return }
        drag = nil
        model.flyout = nil
        setSelection(nil)
    }

    /// The selection is final for now: the editor comes up and the panels appear.
    private func settle(_ rect: CGRect) {
        setSelection(rounded(rect))
        ensureEditor()
        layoutPanels()
    }

    func selectWholeScreen() {
        guard session.maySelect(on: self) else { return }
        session.willSelect(on: self)
        settle(bounds)
    }

    func aspectDidChange() {
        guard let selection, let ratio else {
            canvas.setOverlayNeedsDisplay()
            return
        }
        setSelection(rounded(FrameGeometry.fitted(selection, ratio: ratio)))
    }

    /// Holds the selection to the proportions it has now.
    func lockProportions() {
        guard let selection else { return }
        model.aspect = CaptureAspect(reducing: selection.size)
    }

    /// Takes the size typed into the label.
    func applyTypedSize() {
        focusCanvas()
        guard let selection else { return }
        let size = CGSize(width: max(model.width, 1), height: max(model.height, 1))
        guard size != selection.size else { return }
        // An exact size wins over proportions it does not have.
        if let ratio, abs(size.width / size.height - ratio) > 0.01 { model.aspect = nil }
        setSelection(FrameGeometry.sized(selection, to: size, within: bounds))
    }

    func apply(_ size: CaptureSize) {
        let center = (selection ?? bounds).center
        let rect = CGRect(
            x: center.x - CGFloat(size.width) / 2, y: center.y - CGFloat(size.height) / 2, width: CGFloat(size.width),
            height: CGFloat(size.height)
        )
        model.aspect = nil
        settle(rect)
    }

    func focusCanvas() {
        panel.makeFirstResponder(canvas)
    }

    private func nudgeSelection(with event: NSEvent) {
        guard let selection else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var moved = selection
        switch Int(event.keyCode) {
        case kVK_LeftArrow: moved.origin.x -= step
        case kVK_RightArrow: moved.origin.x += step
        case kVK_UpArrow: moved.origin.y -= step
        default: moved.origin.y += step
        }
        setSelection(FrameGeometry.moved(moved, into: bounds))
    }

    /// 0...3 corners clockwise from top-left, 4...7 edges from the top. An edge is caught anywhere along it.
    private func handle(at point: CGPoint) -> Int? {
        guard let selection else { return nil }
        let points = FrameGeometry.handlePoints(selection)
        if let nearest = (0..<4).min(by: { points[$0].distance(to: point) < points[$1].distance(to: point) }),
           points[nearest].distance(to: point) <= reach * 1.3 {
            return nearest
        }
        guard selection.insetBy(dx: -reach, dy: -reach).contains(point) else { return nil }
        let distances = [
            abs(point.y - selection.minY), abs(point.x - selection.maxX), abs(point.y - selection.maxY), abs(point.x - selection.minX),
        ]
        guard let edge = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[edge] <= reach * 0.7 else { return nil }
        return 4 + edge
    }

    /// The markup under a point, or close enough to the active one to be meant.
    private func markup(at point: CGPoint) -> Bool {
        guard let document = editor?.document else { return false }
        if let active = document.activeLayer, !active.isLocked,
           active.documentBounds.insetBy(dx: -reach * 4, dy: -reach * 4).contains(point) {
            return true
        }
        return document.layers.dropFirst().contains { $0.isVisible && $0.contains(documentPoint: point) }
    }

    // MARK: The editor

    private func ensureEditor() {
        guard editor == nil, let document = Document(image: shot.image, layerName: "Screenshot", isLocked: true) else { return }
        let editor = EditorController(host: self, document: document, fileURL: nil, properties: nil, startsUnsaved: true)
        self.editor = editor
        let tools = editor.model
        let scale = shot.scale
        // Sizes are chosen in points and drawn in pixels, so markup looks the same on any display.
        tools.primaryColor = Settings.shared.captureColor ?? CaptureModel.palette[0]
        tools.strokeWidth = Settings.shared.captureLineWidth * scale
        tools.textDefaults.fontSize = 18 * scale
        tools.textDefaults.isBold = true
        tools.badgeSize = 26 * scale
        tools.fixedRegionAmount = 7 * scale
        let last = Settings.shared.captureTool.flatMap(ToolKind.init(rawValue:))
        tools.tool = last.flatMap { CaptureToolGroup.allTools.contains($0) ? $0 : nil } ?? .arrow
        if let group = CaptureToolGroup.group(of: tools.tool) { model.chosen[group] = tools.tool }
        editor.activate()
        // The editor sets the canvas up for a picture in a window. Here the picture is the screen itself.
        canvas.toolHandler = self
        canvas.showsCheckerboard = false
        canvas.fitPadding = 0
        canvas.panSlack = 0

        let toolsView = host(CaptureToolsView(model: model, tools: tools, screen: self))
        toolsTrailing = toolsView.trailingAnchor.constraint(equalTo: content.leadingAnchor)
        toolsBottom = toolsView.bottomAnchor.constraint(equalTo: content.topAnchor)
        let actionsView = host(CaptureActionsView(model: model, screen: self))
        actionsTrailing = actionsView.trailingAnchor.constraint(equalTo: content.leadingAnchor)
        actionsTop = actionsView.topAnchor.constraint(equalTo: content.topAnchor)
        NSLayoutConstraint.activate([toolsTrailing, toolsBottom, actionsTrailing, actionsTop].compactMap { $0 })
        // Measured once, with nothing open: an open strip grows away from the anchored corner.
        toolsSize = toolsView.fittingSize
        actionsSize = actionsView.fittingSize
        self.toolsView = toolsView
        self.actionsView = actionsView
        focusCanvas()
    }

    private func host<Content: View>(_ view: Content) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.isHidden = true
        content.addSubview(hosting)
        return hosting
    }

    var canUndo: Bool { editor?.document.history.canUndo ?? false }

    func undo() {
        editor?.finishTyping()
        editor?.document.undo()
        focusCanvas()
    }

    func redo() {
        editor?.document.redo()
    }

    /// A click on a group's button: picks its tool, or opens the rest of the group when it is picked already.
    func choose(_ group: CaptureToolGroup) {
        guard let tools = editor?.model else { return }
        let tool = model.tool(of: group)
        if tools.tool == tool, group.tools.count > 1 {
            model.flyout = model.flyout == .tools(group) ? nil : .tools(group)
        } else {
            model.flyout = nil
            tools.tool = tool
        }
        focusCanvas()
    }

    func choose(_ tool: ToolKind, in group: CaptureToolGroup) {
        model.chosen[group] = tool
        model.flyout = nil
        editor?.model.tool = tool
        focusCanvas()
    }

    /// The color of what is drawn next, and of the text being typed.
    func setColor(_ color: RGBAColor) {
        guard let editor else { return }
        editor.model.primaryColor = color
        model.flyout = nil
        if editor.toolHoldsKeyboard, let layer = editor.document.activeLayer, layer.text != nil {
            editor.document.updateLayer(layer.id, name: "Text Color") { layer in
                guard var text = layer.text else { return }
                text.color = color
                layer.content = .text(text)
            }
        } else {
            focusCanvas()
        }
    }

    /// The line width in points.
    var lineWidth: Double { Settings.shared.captureLineWidth }

    /// The folder Save writes to, as the hint on the button names it.
    var saveFolderName: String { Settings.shared.captureFolder.lastPathComponent }

    func setLineWidth(_ width: Double) {
        if !session.isUnattended { Settings.shared.captureLineWidth = width }
        editor?.model.strokeWidth = width * shot.scale
        model.flyout = nil
        focusCanvas()
    }

    // MARK: Panels

    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(
            from: canvas.viewPoint(fromImage: rect.origin), to: canvas.viewPoint(fromImage: CGPoint(x: rect.maxX, y: rect.maxY))
        )
    }

    private var isPlacing: Bool {
        if case .new = drag { return true }
        return false
    }

    /// Puts the size label at the top-left corner of the selection, the tools beside it and the actions under
    /// it, and moves whatever has no room there to the other side or inside.
    private func layoutPanels() {
        guard let selection, let sizeView else {
            for view in [sizeView, toolsView, actionsView] { view?.isHidden = true }
            return
        }
        let frame = viewRect(selection)
        let area = content.bounds.insetBy(dx: 6, dy: 6)
        let gap: CGFloat = 8

        let labelSize = sizeView.fittingSize
        var label = CGPoint(x: frame.minX, y: frame.minY - labelSize.height - 6)
        if label.y < area.minY { label = CGPoint(x: frame.minX + 6, y: frame.minY + 6) }
        label.x = min(max(label.x, area.minX), max(area.maxX - labelSize.width, area.minX))
        sizeLeading?.constant = label.x
        sizeTop?.constant = label.y
        sizeView.isHidden = false

        guard let toolsView, let actionsView, !isPlacing else {
            toolsView?.isHidden = true
            actionsView?.isHidden = true
            return
        }
        // The actions: under the selection, else over it, else inside along its bottom edge.
        var actionsInside = false
        var actionsY = frame.maxY + gap
        if actionsY + actionsSize.height > area.maxY {
            actionsY = frame.minY - actionsSize.height - gap
            // The size label is up there too, on the left.
            if frame.maxX - actionsSize.width < label.x + labelSize.width + gap { actionsY -= labelSize.height + 6 }
            if actionsY < area.minY {
                actionsY = frame.maxY - actionsSize.height - gap
                actionsInside = true
            }
        }
        // The tools: to the right, else to the left, else inside along the right edge.
        var toolsInside = false
        var toolsRight = frame.maxX + gap + toolsSize.width
        if toolsRight > area.maxX {
            toolsRight = frame.minX - gap
            if toolsRight - toolsSize.width < area.minX {
                toolsRight = frame.maxX - gap
                toolsInside = true
            }
        }
        var toolsBottomY = toolsInside ? frame.maxY - gap : frame.maxY
        if toolsInside, actionsInside { toolsBottomY = actionsY - gap }
        toolsBottomY = min(max(toolsBottomY, area.minY + toolsSize.height), area.maxY)
        let actionsRight = min(max(actionsInside ? frame.maxX - gap : frame.maxX, area.minX + actionsSize.width), area.maxX)

        toolsTrailing?.constant = min(max(toolsRight, area.minX + toolsSize.width), area.maxX)
        toolsBottom?.constant = toolsBottomY
        actionsTrailing?.constant = actionsRight
        actionsTop?.constant = min(max(actionsY, area.minY), area.maxY - actionsSize.height)
        toolsView.isHidden = false
        actionsView.isHidden = false
    }

    // MARK: Mouse

    func toolMouseDown(at point: CGPoint, event: NSEvent) {
        guard !model.isBusy else { return }
        model.flyout = nil
        guard let selection else {
            guard session.maySelect(on: self) else { return }
            session.willSelect(on: self)
            drag = .new(anchor: clamped(point), previous: nil, moved: false)
            return
        }
        // A size typed into the label and left there counts once the pointer goes back to the picture.
        if model.width != Int(selection.width) || model.height != Int(selection.height) { applyTypedSize() }
        guard let editor, let selection = self.selection else { return }
        if editor.toolHoldsKeyboard {
            drag = .tool
            editor.toolMouseDown(at: point, event: event)
        } else if let handle = handle(at: point) {
            drag = .handle(handle, original: selection)
        } else if selection.contains(point) {
            if editor.model.tool == .move, !markup(at: point) {
                // The pointer on bare screen moves the selection itself.
                editor.document.setActiveLayer(editor.document.layers.first?.id)
                drag = .move(start: point, original: selection)
            } else {
                drag = .tool
                editor.toolMouseDown(at: point, event: event)
            }
        } else {
            drag = .new(anchor: clamped(point), previous: selection, moved: false)
        }
    }

    func toolMouseDragged(to point: CGPoint, event: NSEvent) {
        guard let drag else { return }
        switch drag {
        case .new(let anchor, let previous, let moved):
            guard moved || anchor.distance(to: point) * canvas.scale > 3 else { return }
            if !moved {
                self.drag = .new(anchor: anchor, previous: previous, moved: true)
                hoveredWindow = nil
            }
            setSelection(FrameGeometry.frame(anchor: anchor, to: point, ratio: ratio, within: bounds))
        case .handle(let index, let original):
            if index < 4 {
                let anchor = FrameGeometry.handlePoints(original)[(index + 2) % 4]
                setSelection(FrameGeometry.frame(anchor: anchor, to: point, ratio: ratio, within: bounds))
            } else {
                setSelection(FrameGeometry.frame(original, draggingEdge: index - 4, to: point, ratio: ratio, within: bounds))
            }
        case .move(let start, let original):
            setSelection(FrameGeometry.moved(original.offsetBy(dx: point.x - start.x, dy: point.y - start.y), into: bounds))
        case .tool:
            editor?.toolMouseDragged(to: point, event: event)
        }
    }

    func toolMouseUp(at point: CGPoint, event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .new(_, let previous, let moved):
            if moved, let selection, selection.width >= 2, selection.height >= 2 {
                settle(selection)
            } else if let previous {
                // A stray click beside the selection leaves it as it was.
                setSelection(previous)
            } else {
                // A click instead of a drag takes the window under the pointer, or the whole display.
                settle(hoveredWindow ?? shot.windows.first { $0.contains(point) } ?? bounds)
            }
            hoveredWindow = nil
        case .handle, .move:
            if let selection { setSelection(rounded(selection)) }
        case .tool:
            editor?.toolMouseUp(at: point, event: event)
        }
    }

    func toolMouseMoved(to point: CGPoint, event: NSEvent) {
        guard let selection else {
            let window = shot.windows.first { $0.contains(point) }
            if window != hoveredWindow {
                hoveredWindow = window
                canvas.setOverlayNeedsDisplay()
            }
            return
        }
        if selection.contains(point) { editor?.toolMouseMoved(to: point, event: event) }
    }

    func toolCursor(at point: CGPoint) -> NSCursor {
        guard let selection, let editor else { return .crosshair }
        if editor.toolHoldsKeyboard { return editor.toolCursor(at: point) }
        if let handle = handle(at: point) {
            let positions: [NSCursor.FrameResizePosition] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
            return NSCursor.frameResize(position: positions[handle], directions: .all)
        }
        guard selection.contains(point) else { return .crosshair }
        if editor.model.tool == .move, !markup(at: point) { return .openHand }
        return editor.toolCursor(at: point)
    }

    func toolFlagsChanged(_ event: NSEvent) {}

    var toolHoldsKeyboard: Bool { editor?.toolHoldsKeyboard ?? false }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    // MARK: Drawing

    func drawOverlay(in context: CGContext, canvas: CanvasView) {
        let view = canvas.bounds
        guard let selection else {
            // Nothing chosen yet: the window under the pointer is offered, lit up against the rest.
            context.saveGState()
            context.addRect(view)
            if let hoveredWindow { context.addRect(viewRect(hoveredWindow)) }
            context.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
            context.fillPath(using: .evenOdd)
            if let hoveredWindow {
                context.setStrokeColor(NSColor.controlAccentColor.cgColor)
                context.setLineWidth(2)
                context.stroke(viewRect(hoveredWindow).insetBy(dx: 1, dy: 1))
            }
            context.restoreGState()
            return
        }
        let frame = viewRect(selection)
        context.saveGState()
        context.addRect(view)
        context.addRect(frame)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        editor?.drawOverlay(in: context, canvas: canvas)

        context.saveGState()
        // A dark line under the white one keeps the frame visible on a white page.
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(3)
        context.stroke(frame)
        context.setStrokeColor(.white)
        context.setLineWidth(1.5)
        context.stroke(frame)
        if !isPlacing {
            context.setFillColor(.white)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            // A small selection keeps its corners only; edge handles would crowd it.
            let points = FrameGeometry.handlePoints(frame)
            for point in min(frame.width, frame.height) < 40 ? Array(points.prefix(4)) : points {
                let box = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.fill(box)
                context.stroke(box)
            }
        }
        context.restoreGState()
    }

    // MARK: Canvas delegate

    func canvas(_ canvas: CanvasView, navigateBy delta: Int) {}
    func canvasPointerDidMove(_ canvas: CanvasView) {}

    func canvasViewportDidChange(_ canvas: CanvasView) {
        editor?.viewportDidChange()
        layoutPanels()
    }

    func canvas(_ canvas: CanvasView, didReceive pasteboard: NSPasteboard, at imagePoint: CGPoint) -> Bool { false }

    /// A right click backs out, unless there is markup that it would throw away.
    func canvas(_ canvas: CanvasView, menuAt imagePoint: CGPoint) -> NSMenu? {
        if !hasMarkup, !toolHoldsKeyboard {
            DispatchQueue.main.async { [weak self] in self?.cancel() }
        }
        return nil
    }

    /// Keys are told apart by where they are on the keyboard, so they work with any input language.
    private static let toolKeys: [Int: Character] = [
        kVK_ANSI_V: "v", kVK_ANSI_A: "a", kVK_ANSI_Backslash: "\\", kVK_ANSI_P: "p", kVK_ANSI_H: "h", kVK_ANSI_R: "r",
        kVK_ANSI_U: "u", kVK_ANSI_T: "t", kVK_ANSI_Q: "q", kVK_ANSI_J: "j", kVK_ANSI_K: "k",
    ]

    func canvas(_ canvas: CanvasView, keyDown event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let code = Int(event.keyCode)
        switch code {
        case kVK_Escape:
            cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            copyImage()
        case kVK_Delete, kVK_ForwardDelete:
            if let document = editor?.document, let layer = document.activeLayer, !layer.isLocked {
                document.removeLayer(layer.id)
            } else {
                NSSound.beep()
            }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            // Markup that is picked moves first; with none picked the selection does.
            if editor?.toolKeyDown(event) != true { nudgeSelection(with: event) }
        default:
            if let key = Self.toolKeys[code], let tool = CaptureToolGroup.allTools.first(where: { $0.shortcut == key }),
               let group = CaptureToolGroup.group(of: tool), editor != nil {
                choose(tool, in: group)
            }
        }
        // Every other key is swallowed: there is nothing here for it to type into.
        return true
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // While a size or a text on the picture is being typed, the keys belong to the text.
        if panel.firstResponder is NSText { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (flags, Int(event.keyCode)) {
        case ([.command], kVK_ANSI_C): copyImage()
        case ([.command, .shift], kVK_ANSI_C): copyText()
        case ([.command], kVK_ANSI_S): save()
        case ([.command, .shift], kVK_ANSI_S): saveAs()
        case ([.command], kVK_ANSI_E): openInEditor()
        case ([.command], kVK_ANSI_A): selectWholeScreen()
        case ([.command], kVK_ANSI_Z): undo()
        case ([.command, .shift], kVK_ANSI_Z): redo()
        case ([.command], kVK_ANSI_W): cancel()
        default: return false
        }
        return true
    }

    // MARK: Editor host

    func updateTitle() {}
    func presentEditorDialog(_ dialog: EditorDialog) {}
    func addImageLayer(_ sender: Any?) {}

    func present(_ error: Error) {
        NSSound.beep()
        showToast(error.localizedDescription)
    }

    /// A line beside the buttons that goes away by itself.
    func showToast(_ text: String) {
        statusWork?.cancel()
        model.status = text
        let work = DispatchWorkItem { [weak self] in self?.model.status = nil }
        statusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    // MARK: Results

    /// The selection as a picture, with or without what was drawn on it.
    func renderedImage(withMarkup: Bool = true) -> CGImage? {
        guard let selection else { return nil }
        editor?.finishTyping()
        let whole = withMarkup ? editor?.flattenedImage() ?? shot.image : shot.image
        return whole.cropping(to: selection)
    }

    /// Puts the picture on a pasteboard at the size it had on screen, as the screenshots of macOS are.
    @discardableResult
    func writeImage(to pasteboard: NSPasteboard) -> Bool {
        guard let image = renderedImage() else { return false }
        let size = NSSize(width: CGFloat(image.width) / shot.scale, height: CGFloat(image.height) / shot.scale)
        pasteboard.clearContents()
        return pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
    }

    func copyImage() {
        guard writeImage(to: .general) else {
            NSSound.beep()
            return
        }
        session.end()
        CaptureOutput.announce("Copied")
    }

    /// Writes the picture into the screenshots folder without asking anything.
    func save() {
        guard let image = renderedImage() else { return }
        let scale = shot.scale
        session.end()
        CaptureOutput.save(image, scale: scale)
    }

    func saveAs() {
        guard let image = renderedImage() else { return }
        let scale = shot.scale, format = Settings.shared.captureFormat
        // A save panel would open under the overlay, so the overlay steps aside for it.
        session.setHidden(true)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = CaptureOutput.fileName(format: format)
        NSApp.activate()
        savePanel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = savePanel.url else {
                self.session.setHidden(false)
                return
            }
            self.session.end()
            CaptureOutput.write(image, scale: scale, format: ImageFormat(url: url) ?? format, to: url)
        }
    }

    /// Recognizes the text in the selection and copies it.
    func copyText() {
        guard !model.isBusy, let image = renderedImage(withMarkup: false) else { return }
        guard ImageAnalyzer.isSupported else {
            showToast("Text recognition is not available on this Mac")
            return
        }
        model.isBusy = true
        statusWork?.cancel()
        model.status = "Reading the text…"
        Task { [weak self] in
            let text = await Self.readText(in: image)
            guard let self, !self.isClosed else { return }
            self.model.isBusy = false
            guard !text.isEmpty else {
                self.showToast("No text found here")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.session.end()
            CaptureOutput.announce("Text copied")
        }
    }

    /// The text macOS recognizes in a picture, or nothing.
    static func readText(in image: CGImage) async -> String {
        let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: .init([.text]))
        return (analysis?.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The selection as a document for a full editor window: cropped, with the markup still editable.
    func makeDocument() -> Document? {
        guard let selection, let editor else { return nil }
        editor.finishTyping()
        let document = editor.document
        document.crop(to: selection)
        // The screen outside the selection is cut off for good, so the layer is exactly the picture.
        if let background = document.layers.first { document.rasterizeLayer(background.id) }
        var state = document.state
        for index in state.layers.indices { state.layers[index].isLocked = false }
        state.activeLayerID = state.layers.last?.id
        // A document of its own, so the editor starts with a clean history.
        let fresh = Document(size: state.size, colorSpace: document.colorSpace)
        fresh.load(state)
        return fresh
    }

    func openInEditor() {
        guard let document = makeDocument() else { return }
        session.end(returningFocus: false)
        (NSApp.delegate as? AppDelegate)?.newWindow(editing: document)
    }

    // MARK: Diagnostics

    /// Saves a picture of the overlay with its panels, for checking it without a person looking.
    func writeSnapshot(to url: URL) {
        // Offscreen capture cannot see GPU surfaces, so show the same pixels as an ordinary image for the shot.
        if let editor {
            canvas.setImage(editor.document.renderer.makeImage(
                editor.document.composite(), size: editor.document.size, colorSpace: editor.document.colorSpace
            ))
        }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
