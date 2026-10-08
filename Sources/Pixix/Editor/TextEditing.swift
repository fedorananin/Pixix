import AppKit
import PixixEngine

/// Typing straight onto the picture.
///
/// The letters are drawn by the document, as always, so what is typed looks exactly like the result. The
/// keyboard goes to a text view nobody sees: it brings everything a Mac text field knows (input methods,
/// dead keys, word and line movement, copy and paste) and its text and selection are mirrored onto the
/// layer, where this class draws the caret and the selection.
@MainActor
final class TextEditingSession: NSObject, NSTextViewDelegate {
    private unowned let editor: EditorController
    let layerID: LayerID
    private let proxy = NSTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private var blink: Timer?
    private var caretIsOn = true
    /// Where a drag that selects text started.
    private var dragAnchor = 0
    private var hasEnded = false
    /// Called once, when typing is over for whatever reason.
    var onEnd: (() -> Void)?

    private var document: Document { editor.document }
    private var canvas: CanvasView { editor.canvas }

    /// Starts typing into a text layer. `caretAt` is a point on the picture; without it all the text is selected,
    /// so that typing replaces a placeholder.
    init?(editor: EditorController, layerID: LayerID, caretAt point: CGPoint? = nil) {
        guard let layer = editor.document.layer(layerID), let text = layer.text, !layer.isLocked else { return nil }
        self.editor = editor
        self.layerID = layerID
        super.init()

        proxy.isRichText = false
        proxy.importsGraphics = false
        // Undo belongs to the document's history, which sees every change made here.
        proxy.allowsUndo = false
        proxy.isAutomaticQuoteSubstitutionEnabled = false
        proxy.isAutomaticDashSubstitutionEnabled = false
        proxy.isAutomaticTextReplacementEnabled = false
        proxy.isAutomaticSpellingCorrectionEnabled = false
        proxy.isContinuousSpellCheckingEnabled = false
        proxy.isVerticallyResizable = false
        // Lines break only where the text has line breaks, as on the canvas.
        proxy.textContainer?.widthTracksTextView = false
        proxy.textContainer?.containerSize = NSSize(width: 1e7, height: 1e7)
        proxy.font = ObjectRenderer.font(for: text) as NSFont
        proxy.string = text.string
        proxy.alphaValue = 0
        proxy.delegate = self
        canvas.addSubview(proxy)
        if let point {
            proxy.setSelectedRange(NSRange(location: position(at: point) ?? (text.string as NSString).length, length: 0))
        } else {
            proxy.selectAll(nil)
        }
        canvas.window?.makeFirstResponder(proxy)
        restartBlink()
        placeProxy()
    }

    // MARK: Ending

    /// Stops typing and hands the keyboard back to the canvas. A text left empty is removed.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        blink?.invalidate()
        proxy.delegate = nil
        if proxy.window?.firstResponder === proxy { canvas.window?.makeFirstResponder(canvas) }
        proxy.removeFromSuperview()
        document.endInteraction()
        if let text = document.layer(layerID)?.text,
           text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, document.layers.count > 1 {
            document.removeLayer(layerID)
        }
        canvas.setOverlayNeedsDisplay()
        onEnd?()
    }

    func textDidEndEditing(_ notification: Notification) {
        // The keyboard went somewhere else: a panel, a field in the inspector.
        end()
    }

    // MARK: Mirroring

    func textDidChange(_ notification: Notification) {
        guard let layer = document.layer(layerID), var text = layer.text, text.string != proxy.string else { return }
        text.string = proxy.string
        // The side the lines are aligned to stays where it is while the box grows; a bubble grows around its middle.
        let anchor: CGPoint
        if text.tail != nil {
            anchor = CGPoint(x: 0.5, y: 0.5)
        } else {
            switch text.alignment {
            case .left: anchor = .zero
            case .center: anchor = CGPoint(x: 0.5, y: 0)
            case .right: anchor = CGPoint(x: 1, y: 0)
            }
        }
        document.updateLayer(layerID, name: "Edit Text", key: "typing") { $0.setText(text, keeping: anchor) }
        restartBlink()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        restartBlink()
        placeProxy()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            end()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }

    /// The document changed behind the typing: an undo, a font change, a deleted layer.
    func documentDidChange() {
        guard !hasEnded else { return }
        guard let text = document.layer(layerID)?.text else {
            end()
            return
        }
        if proxy.string != text.string {
            let selection = proxy.selectedRange()
            proxy.string = text.string
            let length = (text.string as NSString).length
            proxy.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        proxy.font = ObjectRenderer.font(for: text) as NSFont
        placeProxy()
    }

    /// Types text as the keyboard would, or selects part of it. For scripted scenarios.
    func insert(_ string: String) {
        proxy.insertText(string, replacementRange: proxy.selectedRange())
    }

    func select(_ range: NSRange) {
        proxy.setSelectedRange(range)
    }

    // MARK: Pointer

    /// The text position under a point on the picture, or nil when the point is off the text box.
    private func position(at point: CGPoint) -> Int? {
        guard let layer = document.layer(layerID), let text = layer.text,
              abs(layer.transform.a * layer.transform.d - layer.transform.b * layer.transform.c) > 1e-9
        else { return nil }
        let local = point.applying(layer.transform.inverted())
        let slack = 6 / max(canvas.scale * layer.transform.scaleMagnitude, 0.0001)
        guard layer.frameBounds.insetBy(dx: -slack, dy: -slack).contains(local) else { return nil }
        return ObjectRenderer.layout(text).position(at: local)
    }

    func contains(_ point: CGPoint) -> Bool {
        position(at: point) != nil
    }

    /// Puts the caret where the click landed. Returns false for a click off the text.
    func mouseDown(at point: CGPoint, event: NSEvent) -> Bool {
        guard let position = position(at: point) else { return false }
        if event.modifierFlags.contains(.shift) {
            dragAnchor = proxy.selectedRange().location
            select(from: dragAnchor, to: position)
        } else {
            dragAnchor = position
            proxy.setSelectedRange(NSRange(location: position, length: 0))
            if event.clickCount == 2 { proxy.selectWord(nil) }
            if event.clickCount >= 3 { proxy.selectAll(nil) }
        }
        return true
    }

    func mouseDragged(to point: CGPoint) {
        guard let layer = document.layer(layerID), let text = layer.text else { return }
        // A drag may leave the box; the nearest position still counts.
        let local = point.applying(layer.transform.inverted())
        select(from: dragAnchor, to: ObjectRenderer.layout(text).position(at: local))
    }

    private func select(from anchor: Int, to position: Int) {
        proxy.setSelectedRange(NSRange(location: min(anchor, position), length: abs(position - anchor)))
    }

    // MARK: Drawing

    private func restartBlink() {
        caretIsOn = true
        blink?.invalidate()
        blink = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.caretIsOn.toggle()
                self.canvas.setOverlayNeedsDisplay()
            }
        }
        canvas.setOverlayNeedsDisplay()
    }

    /// Keeps the unseen text view at the caret, which is where input method windows open.
    private func placeProxy() {
        guard let layer = document.layer(layerID), let text = layer.text else { return }
        let caret = ObjectRenderer.layout(text).caret(at: proxy.selectedRange().location)
        let spot = canvas.viewPoint(fromImage: CGPoint(x: caret.minX, y: caret.maxY).applying(layer.transform))
        proxy.setFrameOrigin(spot)
    }

    func draw(in context: CGContext, canvas: CanvasView) {
        guard !hasEnded, let layer = document.layer(layerID), let text = layer.text else { return }
        let layout = ObjectRenderer.layout(text)
        let selection = proxy.selectedRange()
        func onScreen(_ point: CGPoint) -> CGPoint { canvas.viewPoint(fromImage: point.applying(layer.transform)) }
        context.saveGState()
        if selection.length > 0 {
            context.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).cgColor)
            for rect in layout.rects(for: selection) {
                // Four corners rather than a rectangle: the text may be turned.
                context.addLines(between: [
                    onScreen(CGPoint(x: rect.minX, y: rect.minY)), onScreen(CGPoint(x: rect.maxX, y: rect.minY)),
                    onScreen(CGPoint(x: rect.maxX, y: rect.maxY)), onScreen(CGPoint(x: rect.minX, y: rect.maxY)),
                ])
                context.closePath()
                context.fillPath()
            }
        } else if caretIsOn {
            let caret = layout.caret(at: selection.location)
            let top = onScreen(CGPoint(x: caret.minX, y: caret.minY)), bottom = onScreen(CGPoint(x: caret.minX, y: caret.maxY))
            // Dark under light, so the caret shows on any picture.
            for (color, width) in [(NSColor.black.withAlphaComponent(0.6).cgColor, CGFloat(3.5)), (CGColor.white, CGFloat(1.5))] {
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.move(to: top)
                context.addLine(to: bottom)
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}
