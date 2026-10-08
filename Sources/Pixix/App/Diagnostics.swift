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
        let target = window.attachedSheet ?? infoWindow ?? window
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

    /// Scripted scenarios for snapshots. `done` is called when the window is ready to be photographed.
    ///
    /// In the viewer: `mouse`, `windows`, `files`, `livetext`, `info`, `menu`.
    /// With `--edit`: `meme`, `tools`, `markup`, `text`, `layers`, `append`, `subject`, `cutout`, `save`, `crop`,
    /// `crop-applied`, `select`, `effect`, `export`, `menu`.
    func runDemoScript(_ name: String, done: @escaping @MainActor () -> Void) {
        switch name {
        case "mouse":
            runMouseScript()
        case "windows":
            runWindowsScript()
        case "files":
            runFilesScript()
        case "menu":
            // What a right click offers, with the items that are switched off in brackets.
            let menu = canvas(canvas, menuAt: .zero)
            for item in menu?.items ?? [] {
                if item.isSeparatorItem { print("--") } else { print(validateMenuItem(item) ? item.title : "[\(item.title)]") }
            }
        case "info":
            showInfo(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
            return
        case "livetext":
            runLiveTextScript(done: done)
            return
        case "subject":
            editor?.selectSubject()
            wait(for: { [weak self] in self?.editor?.document.selection != nil }, then: done)
            return
        case "cutout":
            editor?.removeBackground()
            wait(for: { [weak self] in self?.editor?.document.history.undoName == "Remove Background" }, then: done)
            return
        case "save":
            // Changes the file it is given: run it on a scratch copy.
            editor?.flipCanvas(horizontal: true)
            saveDocument(nil)
            wait(for: { [weak self] in self?.editor?.isDirty == false }, then: done)
            return
        default:
            runEditorScript(name)
        }
        done()
    }

    /// Calls `done` once the condition holds, or after ten seconds if it never does.
    private func wait(for condition: @escaping @MainActor () -> Bool, attempts: Int = 0, then done: @escaping @MainActor () -> Void) {
        if condition() || attempts >= 100 {
            if attempts >= 100 { print("gave up waiting") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wait(for: condition, attempts: attempts + 1, then: done)
        }
    }

    /// Opens the next picture the way Finder would, and prints which windows there are and where.
    private func runWindowsScript() {
        guard let app = NSApp.delegate as? AppDelegate, let browser, let next = browser.neighbor(offset: 1, wrap: true) else { return }
        func report(_ label: String) {
            let windows = NSApp.windows.compactMap { $0.windowController as? ViewerWindowController }
            let lines = windows.map { controller -> String in
                let frame = controller.window?.frame ?? .zero
                return "\(controller.currentURL?.lastPathComponent ?? "-") at \(Int(frame.minX)),\(Int(frame.maxY)) \(Int(frame.width))×\(Int(frame.height))"
            }
            print("\(label): \(windows.count) window(s): \(lines.joined(separator: "; "))")
        }
        report("start")
        app.open([next])
        report("opened the next file")
        app.open([next])
        report("opened it again")
        Settings.shared.opensNewWindows = false
        if let third = browser.neighbor(offset: 2, wrap: true) { app.open([third]) }
        report("with one window per picture switched off")
        Settings.shared.opensNewWindows = true
        app.newWindow(nil)
        report("File › New Window")
    }

    /// Renames, duplicates, copies and moves the file on screen and undoes it all, printing the folder each time.
    /// Run it on a scratch copy: it changes files.
    private func runFilesScript() {
        guard let url = currentURL else { return }
        let folder = url.deletingLastPathComponent()
        func report(_ label: String) {
            let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            print("\(label): showing \(currentURL?.lastPathComponent ?? "-"), list \(browser?.files.map(\.lastPathComponent) ?? []), disk \(onDisk)")
        }
        report("start")
        let renamed = rename(url, to: "renamed picture")
        report("rename")
        if let renamed { rename(renamed, to: "RENAMED picture." + renamed.pathExtension) }
        report("rename, case only and with the extension typed")
        duplicateFile(nil)
        report("duplicate")
        let sub = folder.appendingPathComponent("sorted", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        if let current = currentURL { transfer(current, to: sub, moving: false) }
        report("copy to folder")
        if let current = currentURL { transfer(current, to: sub, moving: true) }
        report("move to folder")
        print("sorted: \(((try? FileManager.default.contentsOfDirectory(atPath: sub.path)) ?? []).sorted())")
        for step in 1...4 {
            guard window?.undoManager?.canUndo == true else { break }
            let name = window?.undoManager?.undoActionName ?? ""
            window?.undoManager?.undo()
            report("undo \(step) (\(name))")
        }
    }

    /// Waits for the text in the picture to be recognized, prints it and marks where it is.
    private func runLiveTextScript(done: @escaping @MainActor () -> Void, attempts: Int = 0) {
        guard let liveText, liveText.isReady else {
            guard attempts < 100 else {
                print("live text: nothing recognized")
                done()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.runLiveTextScript(done: done, attempts: attempts + 1)
            }
            return
        }
        print("live text: \(liveText.transcript.replacingOccurrences(of: "\n", with: " | "))")
        liveText.highlightAll(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() }
    }

    private func runEditorScript(_ name: String) {
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
        case "markup":
            runMarkupScript()
        case "text":
            // Click with the text tool and type, the way a person would.
            editor.model.tool = .text
            editor.model.textDefaults.fontSize = Double(size.height / 9)
            let press = NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!
            editor.toolMouseDown(at: CGPoint(x: size.width * 0.5, y: size.height * 0.4), event: press)
            editor.toolMouseUp(at: CGPoint(x: size.width * 0.5, y: size.height * 0.4), event: press)
            // The last word ends up selected, so the picture shows where the selection is drawn.
            editor.typeText("Typed on\nthe canva")
            // The last letter comes in as a key press, by the road a real keyboard takes.
            if let key = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
            ) {
                window?.sendEvent(key)
            }
            editor.typeText("", selecting: NSRange(location: 13, length: 6))
            print("text: \(document.activeLayer?.text?.string.replacingOccurrences(of: "\n", with: " | ") ?? "-"), history \(document.history.entries.map(\.name))")
        case "layers":
            if let source = document.layers.first?.buffer?.makeImage(), let small = Resampler.resize(source, longEdge: Int(max(size.width, size.height) / 3)) {
                let id = document.addImageLayer(small, name: "Photo", center: CGPoint(x: size.width * 0.7, y: size.height * 0.3))
                if let id { document.updateLayer(id, name: "Rename Layer") { $0.name = "Inset picture" } }
            }
            document.addEmptyLayer()
            var text = TextContent()
            text.string = "Caption"
            text.fontSize = Double(size.height / 12)
            var caption = Layer(name: "Text", content: .text(text))
            caption.transform = CGAffineTransform(translationX: size.width * 0.1, y: size.height * 0.75)
            document.addLayer(caption)
            // Drag and drop cannot be scripted; this is the call a drop makes.
            document.moveLayer(caption.id, toIndex: 1)
            print("layers, bottom first: \(document.layers.map(\.name))")
            editor.model.tool = .move
            editor.model.expandedSections = ["layers"]
            if let photo = document.layers.first(where: { $0.name == "Inset picture" }) {
                editor.model.layerNameDraft = photo.name
                editor.model.renamingLayer = photo.id
            }
        case "append":
            if let url = currentURL {
                editor.appendImages(from: [url], to: .bottom)
                editor.appendImages(from: [url], to: .right)
            }
            print("append: canvas \(Int(document.size.width))×\(Int(document.size.height)), layers \(document.layers.map(\.name))")
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

    /// Numbered badges, a speech bubble, a spotlight and a shadow, each made the way the tools make them.
    private func runMarkupScript() {
        guard let editor else { return }
        let document = editor.document
        let model = editor.model
        let w = document.size.width, h = document.size.height
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            editor.toolMouseDown(at: a, event: event(.leftMouseDown))
            editor.toolMouseDragged(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), event: event(.leftMouseDragged))
            editor.toolMouseDragged(to: b, event: event(.leftMouseDragged))
            editor.toolMouseUp(at: b, event: event(.leftMouseUp))
        }

        model.tool = .spotlightRegion
        drag(CGPoint(x: w * 0.08, y: h * 0.1), CGPoint(x: w * 0.45, y: h * 0.5))
        drag(CGPoint(x: w * 0.6, y: h * 0.6), CGPoint(x: w * 0.9, y: h * 0.9))
        if let id = document.activeLayerID {
            document.updateLayer(id, name: "Shape") { layer in
                guard var region = layer.effectRegion else { return }
                region.isEllipse = true
                layer.content = .effect(region)
            }
        }

        model.tool = .badge
        for spot in [CGPoint(x: w * 0.12, y: h * 0.16), CGPoint(x: w * 0.3, y: h * 0.16), CGPoint(x: w * 0.66, y: h * 0.66)] {
            drag(spot, spot)
        }
        model.primaryColor = RGBAColor(red: 1, green: 0.8, blue: 0)
        // Pulled out by hand, so larger than the rest.
        drag(CGPoint(x: w * 0.82, y: h * 0.2), CGPoint(x: w * 0.82 + w * 0.05, y: h * 0.2))
        model.primaryColor = RGBAColor(red: 0.9, green: 0.16, blue: 0.13)

        model.textDefaults.fontSize = Double(h / 16)
        model.tool = .callout
        drag(CGPoint(x: w * 0.3, y: h * 0.42), CGPoint(x: w * 0.62, y: h * 0.3))
        editor.typeText("Look here")

        model.tool = .rectangle
        model.strokeWidth = Double(w / 120)
        drag(CGPoint(x: w * 0.1, y: h * 0.62), CGPoint(x: w * 0.4, y: h * 0.88))
        if let id = document.activeLayerID {
            document.updateLayer(id, name: "Shadow") { layer in
                guard var shape = layer.shape else { return }
                shape.shadow = Double(w / 60)
                shape.fillColor = .white
                layer.content = .shape(shape)
            }
        }
        print("markup: \(document.layers.map(\.name))")
        print("badges: \(document.layers.compactMap { $0.shape?.label })")
        if let bubble = document.layers.first(where: { $0.text?.tail != nil }) { document.setActiveLayer(bubble.id) }
        model.tool = .callout
        model.expandedSections = ["layer", "layers"]
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
