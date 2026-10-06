import AppKit
import CoreImage
import IOSurface
import PixixCodec
import PixixEngine

extension ViewerWindowController {
    /// Saves a picture of the whole window, title bar included, without needing screen-recording permission.
    /// When a sheet is open, the sheet is what gets saved.
    func writeSnapshot(to url: URL) {
        guard let window else { return }
        let target = window.attachedSheet ?? window
        guard let view = target.contentView?.superview ?? target.contentView else { return }
        // Offscreen capture cannot see GPU surfaces, so show the same pixels as ordinary images for the shot.
        if let editor {
            canvas.setImage(editor.document.renderer.makeImage(
                editor.document.composite(), size: editor.document.size, colorSpace: editor.document.colorSpace
            ))
        }
        if let surface = canvas.selectionLayer.contents as? IOSurface {
            let image = CIImage(ioSurface: surface, options: [.colorSpace: NSNull()])
            canvas.selectionLayer.contents = CIContext().createCGImage(image, from: image.extent)
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Scripted scenarios for snapshots.
    func runDemoScript(_ name: String) {
        if name == "mouse" {
            runMouseScript()
            return
        }
        guard let editor else { return }
        let document = editor.document
        let size = document.size
        switch name {
        case "crop":
            editor.model.tool = .crop
            editor.model.cropAspect = .r16x9
            editor.model.straighten = 12
        case "crop-applied":
            editor.model.tool = .crop
            editor.model.cropAspect = .r16x9
            editor.model.straighten = 12
            editor.applyCrop()
        case "tools":
            runToolsScript()
        case "select":
            editor.model.tool = .selectEllipse
            document.setSelection(Selection.ellipse(
                CGRect(x: size.width * 0.2, y: size.height * 0.2, width: size.width * 0.5, height: size.height * 0.4), in: size
            ))
            document.selectSimilar(
                at: CGPoint(x: size.width * 0.9, y: size.height * 0.9), tolerance: 40, contiguous: true,
                sampleAllLayers: true, combine: .add
            )
        case "effect":
            if let effect = EffectCatalog.find("twirl") { editor.beginEffect(effect) }
        case "export":
            exportImage(nil)
        default:
            runMemeScript()
        }
    }

    /// Exercises the editor the way the meme scenario does, so a snapshot shows layers, text and markup at once.
    private func runMemeScript() {
        guard let editor else { return }
        let document = editor.document
        let size = document.size
        // Extend the canvas downward and drop a second picture into the new space.
        document.crop(to: CGRect(x: 0, y: 0, width: size.width, height: size.height * 1.6))
        if let source = document.layers.first?.buffer?.makeImage(), let small = Resampler.resize(source, longEdge: Int(max(size.width, size.height) / 2)) {
            let id = document.addImageLayer(small, name: "Photo", center: CGPoint(x: size.width / 2, y: size.height * 1.3))
            if let id { document.updateLayer(id, name: "Tint") { $0.filter = .noir } }
        }
        var text = TextContent()
        text.string = "TOP TEXT"
        text.fontName = "Impact"
        text.fontSize = Double(size.height / 7)
        text.outlineWidth = Double(size.height / 90)
        text.alignment = .center
        var caption = Layer(name: "Text", content: .text(text))
        let box = caption.localBounds.size
        caption.transform = CGAffineTransform(translationX: (size.width - box.width) / 2, y: size.height * 0.04)
        document.addLayer(caption)

        var arrow = ShapeContent(kind: .arrow, points: [
            CGPoint(x: size.width * 0.15, y: size.height * 0.85), CGPoint(x: size.width * 0.45, y: size.height * 0.55),
        ])
        arrow.strokeWidth = Double(max(size.width / 120, 4))
        document.addLayer(Layer(name: "Arrow", content: .shape(arrow)))

        var region = EffectRegion(effect: .pixelate, size: CGSize(width: size.width * 0.25, height: size.height * 0.25))
        region.amount = Double(max(size.width / 60, 8))
        var hidden = Layer(name: "Pixelate", content: .effect(region))
        hidden.transform = CGAffineTransform(translationX: size.width * 0.65, y: size.height * 0.5)
        document.addLayer(hidden)
        document.setActiveLayer(caption.id)
        editor.model.tool = .move
        canvas.fit()
    }

    /// Turns a mouse wheel over the picture, over the background and sideways, presses the side buttons, and
    /// prints what each of them did. The events go to the window, so they take the same route as the real ones.
    private func runMouseScript() {
        guard let window, let screen = NSScreen.screens.first else { return }
        var clock: TimeInterval = 10
        func state() -> String { "\(canvas.zoomPercent)% \(browser?.current?.lastPathComponent ?? "-")" }
        // An event made from a Core Graphics one belongs to no window, and AppKit reads its place on the screen
        // as the place in the window. Core Graphics counts rows from the top of the main display.
        func location(_ viewPoint: CGPoint) -> CGPoint {
            let inWindow = canvas.convert(viewPoint, to: nil)
            return CGPoint(x: inWindow.x, y: screen.frame.height - inWindow.y)
        }
        func press(_ label: String, button: UInt32) {
            guard let button = CGMouseButton(rawValue: button), let cgEvent = CGEvent(
                mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: location(.zero), mouseButton: button
            ), let event = NSEvent(cgEvent: cgEvent) else { return }
            window.sendEvent(event)
            print("\(label): \(state())")
        }
        func turn(_ label: String, at viewPoint: CGPoint, vertical: Int32 = 0, horizontal: Int32 = 0, notches: Int = 1, pause: TimeInterval = 0.3) {
            var steps: [String] = []
            for _ in 0..<notches {
                guard let cgEvent = CGEvent(
                    scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0
                ) else { return }
                cgEvent.location = location(viewPoint)
                clock += pause
                cgEvent.timestamp = CGEventTimestamp(clock * 1_000_000_000)
                guard let event = NSEvent(cgEvent: cgEvent) else { return }
                window.sendEvent(event)
                steps.append(state())
            }
            print("\(label): \(steps.joined(separator: ", "))")
        }
        let inside = CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY)
        let outside = CGPoint(x: canvas.bounds.minX + 4, y: canvas.bounds.minY + 4)
        let edge = CGPoint(x: canvas.imageRect.minX + 6, y: canvas.imageRect.midY)
        let arrow = CGPoint(x: canvas.bounds.maxX - 38, y: canvas.bounds.midY)
        print("start: \(state()), \(browser?.count ?? 0) files")
        turn("up over the picture", at: inside, vertical: 3, notches: 12)
        turn("down over the picture", at: inside, vertical: -3, notches: 16)
        canvas.fit()
        // The picture shrinks away from the pointer here, and the wheel must go on zooming.
        turn("down at the edge of the picture", at: edge, vertical: -1, notches: 3)
        canvas.fit()
        turn("down over the background", at: outside, vertical: -1, notches: 2)
        turn("up over the background", at: outside, vertical: 1)
        turn("sideways over the picture", at: inside, horizontal: -1, notches: 2)
        turn("sideways the other way, too fast", at: inside, horizontal: 1, notches: 4, pause: 0.03)
        turn("up over the next arrow", at: arrow, vertical: 1)
        press("first side button", button: 3)
        press("second side button", button: 4)
        turn("up over the picture", at: inside, vertical: 1, notches: 3, pause: 2)
    }

    /// Drives the tools through the same entry points the canvas uses for real mouse input.
    private func runToolsScript() {
        guard let editor else { return }
        let document = editor.document
        let model = editor.model
        let w = document.size.width, h = document.size.height

        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 1
            )!
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) {
            editor.toolMouseDown(at: a, event: event(.leftMouseDown, flags))
            for step in 1...10 {
                let t = CGFloat(step) / 10
                editor.toolMouseDragged(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), event: event(.leftMouseDragged, flags))
            }
            editor.toolMouseUp(at: b, event: event(.leftMouseUp, flags))
        }
        func click(_ a: CGPoint, flags: NSEvent.ModifierFlags = []) {
            editor.toolMouseDown(at: a, event: event(.leftMouseDown, flags))
            editor.toolMouseUp(at: a, event: event(.leftMouseUp, flags))
        }

        model.brushSize = Double(w / 30)
        model.tool = .brush
        drag(point(0.08, 0.08), point(0.42, 0.17))
        model.tool = .eraser
        drag(point(0.25, 0.04), point(0.25, 0.25))
        model.tool = .pencil
        model.brushSize = 6
        drag(point(0.08, 0.3), point(0.4, 0.3))

        model.tool = .selectRectangle
        drag(point(0.58, 0.08), point(0.92, 0.33))
        model.tool = .gradient
        drag(point(0.58, 0.08), point(0.92, 0.33))
        document.setSelection(nil)

        model.tool = .fill
        model.primaryColor = RGBAColor(red: 0.1, green: 0.7, blue: 0.3)
        click(point(0.12, 0.92))
        model.primaryColor = RGBAColor(red: 0.9, green: 0.16, blue: 0.13)

        model.strokeWidth = Double(w / 100)
        model.tool = .arrow
        drag(point(0.17, 0.75), point(0.42, 0.5))
        model.tool = .rectangle
        model.fillsShapes = true
        drag(point(0.5, 0.5), point(0.75, 0.66))
        model.tool = .highlighter
        drag(point(0.5, 0.72), point(0.9, 0.72))
        model.tool = .blurRegion
        drag(point(0.04, 0.36), point(0.3, 0.58))

        model.tool = .text
        click(point(0.6, 0.88))
        if let id = document.activeLayerID, document.activeLayer?.text != nil {
            document.updateLayer(id, name: "Edit Text") { layer in
                guard var text = layer.text else { return }
                text.string = "Moved & scaled"
                text.fontSize = Double(h / 20)
                layer.content = .text(text)
            }
            // Move the text, then enlarge it by its bottom-right handle.
            model.tool = .move
            if let layer = document.activeLayer {
                let center = layer.documentBounds.center
                drag(center, CGPoint(x: center.x - w * 0.08, y: center.y - h * 0.05))
            }
            if let layer = document.activeLayer {
                let corner = layer.corners[2]
                drag(corner, CGPoint(x: corner.x + w * 0.12, y: corner.y + h * 0.04))
            }
        }
        model.tool = .wand
        click(point(0.75, 0.2))
        model.tool = .move
        model.expandedSections = ["layers", "history"]
    }
}
