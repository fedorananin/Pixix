import AppKit
import CoreImage
import IOSurface
import PixixCodec
import PixixEngine
import SwiftUI

/// A window a scenario made for its own picture, such as Settings laid out off the screen.
@MainActor private var scenarioWindow: NSWindow?

extension ViewerWindowController {
    /// Saves a picture of the whole window, title bar included, without needing screen-recording permission.
    /// When a sheet is open, the sheet is what gets saved.
    func writeSnapshot(to url: URL) {
        guard let window else { return }
        // A screenshot overlay is a window of its own, and during a capture it is what there is to see.
        if let overlay = CaptureAgent.shared.session?.screens.first {
            overlay.writeSnapshot(to: url)
            return
        }
        if let overlay = CaptureAgent.shared.picker?.screens.first {
            overlay.writeSnapshot(to: url)
            return
        }
        let target = scenarioWindow ?? window.attachedSheet ?? infoWindow ?? window
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
    /// In the viewer: `mouse`, `windows`, `files`, `livetext`, `info`, `menu`, and for screenshots `capture`,
    /// `capture-full`, `capture-window`, `capture-edit`, `capture-save`, `capture-text`, and for measuring
    /// memory `capture-open` (the overlay alone), `capture-closed` (after it is dismissed) and `capture-repeat`
    /// (eight captures in a row); for the color picker `picker` (the magnifier moved by the pointer and the
    /// arrow keys, with the color printed at each step), `picker-all` (the same with every notation on show), `picker-closed` (after it is dismissed, for memory) and
    /// `picker-window` (the window with the values); `settings` is the Settings window on the page of the
    /// screenshot options, `settings-colors` and `settings-general` are its other pages, and `shortcut` records
    /// shortcuts on it.
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
        case "capture-repeat":
            // One capture after another, each marked up and dismissed: memory that climbs with every round is a leak.
            func round(_ number: Int) {
                guard number <= 8 else { return done() }
                runCaptureScript("capture-closed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    print(String(format: "after capture %d: %.0f MB", number, LaunchOptions.memoryFootprint()?.now ?? 0))
                    round(number + 1)
                }
            }
            print(String(format: "before any capture: %.0f MB", LaunchOptions.memoryFootprint()?.now ?? 0))
            round(1)
            return
        case "capture-open":
            // The overlay alone, before anything is selected: what a press of the shortcut costs.
            _ = beginScriptedCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done() }
            return
        case "capture", "capture-full", "capture-window", "capture-edit", "capture-closed":
            runCaptureScript(name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done() }
            return
        case "capture-save":
            runCaptureSaveScript(done: done)
            return
        case "picker", "picker-all", "picker-closed":
            runPickerScript(name)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
            return
        case "picker-window":
            // The window a click opens, with the color of the middle of the picture, out of sight.
            guard let (screen, size) = beginScriptedPicking() else { break }
            screen.pointerMoved(to: CGPoint(x: size.width * 0.5 / screen.shot.scale, y: size.height * 0.5 / screen.shot.scale))
            let color = screen.color ?? .black
            CaptureAgent.shared.picker?.end()
            let controller = ColorWindowController(color: color)
            controller.model.isLive = false
            controller.panel.alphaValue = 0
            controller.panel.ignoresMouseEvents = true
            controller.panel.orderBack(nil)
            controller.panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            scenarioWindow = controller.panel
            // Every notation, whatever Settings shows: the picture is of the window at its fullest.
            controller.model.notations = ColorNotation.allCases
            print("color window: \(controller.model.notations.map(controller.model.text).joined(separator: "  "))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // Once the rows have been laid out again.
                controller.panel.setContentSize(controller.panel.contentView?.fittingSize ?? .zero)
                done()
            }
            return
        case "settings", "settings-general", "settings-colors", "shortcut":
            // Out of sight like every scripted window, and without switching anything on.
            let settings = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            settings.title = "Pixix Settings"
            let tab: SettingsTab = name == "settings-general" ? .general : name == "settings-colors" ? .colors : .screenshots
            settings.contentViewController = NSHostingController(rootView: SettingsView(model: SettingsModel(tab: tab, previewingOptions: true)))
            settings.alphaValue = 0
            settings.ignoresMouseEvents = true
            settings.orderBack(nil)
            settings.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            scenarioWindow = settings
            if name == "shortcut" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.runShortcutScript(in: settings, done: done) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
            }
            return
        case "capture-text":
            // Reads the text in the picture the way Copy Text does, without touching the clipboard.
            guard let image = displayed?.loaded.image else { break }
            Task {
                let text = await CaptureScreenController.readText(in: image)
                print("text: \(text.replacingOccurrences(of: "\n", with: " | "))")
                done()
            }
            return
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

    /// Records shortcuts the way a person does: a click on the button in Settings, then key presses that arrive
    /// through the app's event queue. Prints what the button says after each, and puts the saved shortcut back.
    private func runShortcutScript(in settings: NSWindow, done: @escaping @MainActor () -> Void) {
        func find(_ view: NSView) -> ShortcutRecorderButton? {
            if let button = view as? ShortcutRecorderButton { return button }
            for subview in view.subviews {
                if let button = find(subview) { return button }
            }
            return nil
        }
        guard let button = settings.contentView.flatMap(find) else {
            print("shortcut: the button is not in the window")
            return done()
        }
        let savedCombo = UserDefaults.standard.data(forKey: "captureHotKey")
        let savedCleared = UserDefaults.standard.object(forKey: "captureHotKeyCleared") as? Bool
        print("shortcut: button says \"\(button.title)\", enabled \(button.isEnabled)")
        let number = settings.windowNumber
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: number, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            )
        }
        let steps: [(String, NSEvent?)] = [
            ("K alone", key(40, "k", [])),
            ("⌃⌥ held", key(59, "", [.control, .option], type: .flagsChanged)),
            ("⌃⌥K", key(40, "k", [.control, .option])),
            ("⇧⌘4", key(21, "$", [.command, .shift])),
            ("⇧⌘5", key(23, "%", [.command, .shift])),
            ("F13", key(105, "", [])),
            ("⌥⌫", key(51, "", [.option])),
            ("Delete", key(51, "", [])),
        ]
        func run(_ index: Int) {
            guard index < steps.count else {
                if let savedCombo { UserDefaults.standard.set(savedCombo, forKey: "captureHotKey") } else { UserDefaults.standard.removeObject(forKey: "captureHotKey") }
                if let savedCleared { UserDefaults.standard.set(savedCleared, forKey: "captureHotKeyCleared") } else { UserDefaults.standard.removeObject(forKey: "captureHotKeyCleared") }
                return done()
            }
            if !button.isRecording { button.performClick(nil) }
            if let event = steps[index].1 { NSApp.postEvent(event, atStart: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let saved = Settings.shared.captureHotKey
                print("\(steps[index].0): button \"\(button.title)\", recording \(button.isRecording), saved \(saved?.title ?? "none"), used by macOS \(saved?.isUsedByMacOS ?? false)")
                run(index + 1)
            }
        }
        run(0)
    }

    /// What the panels say under the pointer. No pointer is there, so the views that watch for it are told that
    /// it came, the way the system tells them. One hint is left showing for the picture.
    private func reportHints(on screen: CaptureScreenController, scenario name: String) {
        let moved = NSEvent.mouseEvent(
            with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        )!
        var watchers: [HoverView] = []
        func collect(_ view: NSView) {
            if let watcher = view as? HoverView { watchers.append(watcher) }
            view.subviews.forEach(collect)
        }
        if let content = screen.panel.contentView { collect(content) }
        var hints: [String] = []
        for watcher in watchers {
            watcher.mouseEntered(with: moved)
            if let hint = screen.model.hint { hints.append(hint.text) }
            watcher.mouseExited(with: moved)
        }
        print("hints, \(watchers.count) controls, \(screen.model.hint == nil ? "cleared on leaving" : "stuck"): \(hints.joined(separator: " | "))")
        let shown = name == "capture" ? "Pen (P)" : name == "capture-full" ? "Copy (" : "Proportions"
        for watcher in watchers {
            watcher.mouseEntered(with: moved)
            if screen.model.hint?.text.hasPrefix(shown) == true { break }
            watcher.mouseExited(with: moved)
        }
    }

    /// A screenshot session on the picture in the window instead of on the screen. It needs no permission and
    /// its overlay is out of sight.
    private func beginScriptedCapture() -> (screen: CaptureScreenController, size: CGSize)? {
        guard let image = displayed?.loaded.image else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var shot = ScreenShot(frame: CGRect(x: 0, y: 0, width: w / scale, height: h / scale), image: image)
        shot.windows = [CGRect(x: (w * 0.1).rounded(), y: (h * 0.15).rounded(), width: (w * 0.5).rounded(), height: (h * 0.6).rounded())]
        let session = CaptureAgent.shared.beginSession(shots: [shot], unattended: true)
        return session.screens.first.map { ($0, CGSize(width: w, height: h)) }
    }

    /// A color pick on the picture in the window instead of on the screen. Like a scripted screenshot, it needs
    /// no permission and its overlay is out of sight.
    private func beginScriptedPicking() -> (screen: PickerScreenController, size: CGSize)? {
        guard let image = displayed?.loaded.image else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: image.width, height: image.height)
        let shot = ScreenShot(frame: CGRect(x: 0, y: 0, width: size.width / scale, height: size.height / scale), image: image)
        let session = CaptureAgent.shared.beginPicking(shots: [shot], unattended: true)
        return session.screens.first.map { ($0, size) }
    }

    /// Moves the pointer over the picture and presses the arrow keys, through the entry points the real mouse
    /// and keyboard use, and prints the pixel, its color in every notation and where the magnifier went.
    private func runPickerScript(_ name: String) {
        guard let (screen, size) = beginScriptedPicking() else { return }
        let scale = screen.shot.scale
        func report(_ label: String) {
            guard let pixel = screen.pixel, let color = screen.color, let frame = screen.loupeFrame else {
                print("\(label): nothing under the pointer")
                return
            }
            let values = ColorNotation.allCases.map { $0.text(of: color) }.joined(separator: "  ")
            print("\(label): pixel \(pixel.x),\(pixel.y)  \(values)  magnifier at \(Int(frame.minX)),\(Int(frame.minY))")
        }
        func move(_ x: CGFloat, _ y: CGFloat) {
            screen.pointerMoved(to: CGPoint(x: size.width * x / scale, y: size.height * y / scale))
        }
        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
            ) else { return }
            screen.keyDown(event)
        }
        print("picture \(Int(size.width))×\(Int(size.height)) px, \(Int(size.width / scale))×\(Int(size.height / scale)) pt")
        if name == "picker-all" { screen.show(ColorNotation.allCases) }
        move(0.3, 0.4)
        report("pointer at 30%, 40%")
        press(124)
        report("→")
        press(125, .shift)
        report("⇧↓")
        // The pointer has not moved since the keys did: the pixel they chose stands.
        if let pixel = screen.pixel { screen.pointerMoved(to: CGPoint(x: (CGFloat(pixel.x) + 0.2) / scale, y: (CGFloat(pixel.y) + 0.2) / scale)) }
        report("pointer still")
        move(0, 0)
        report("top-left corner")
        press(123)
        report("← at the edge")
        move(1, 1)
        report("bottom-right corner")
        move(0.62, 0.45)
        report("pointer at 62%, 45%")
        let settings = Settings.shared
        print("a click: \(settings.pickerAction.title.lowercased()), as \(screen.color.map { settings.pickerCopyNotation.text(of: $0, bareHex: settings.pickerBareHex) } ?? "-"); shown \(settings.pickerNotations.map(\.title)); shortcut \(settings.pickerHotKey?.title ?? "none")")
        // Two shortcuts claimed and let go at once: a press of one must reach its own handler and no other.
        var presses = [0, 0]
        let first = GlobalHotKey(id: 1) { presses[0] += 1 }
        let second = GlobalHotKey(id: 2) { presses[1] += 1 }
        let granted = [first.register(settings.captureHotKey ?? .standard), second.register(settings.pickerHotKey ?? .pickerStandard)]
        let delivered = second.simulatePress()
        let afterSecond = presses
        _ = first.simulatePress()
        first.unregister()
        second.unregister()
        print("two shortcuts granted by macOS: \(granted); a press of the second delivered: \(delivered), handled \(afterSecond); then one of the first: \(presses)")
        if name == "picker-closed" { CaptureAgent.shared.picker?.end() }
    }

    /// Saves a part of the picture the way the Save button does, into a folder next to the picture, and prints
    /// what landed there. Run it on a scratch copy.
    private func runCaptureSaveScript(done: @escaping @MainActor () -> Void) {
        guard let url = currentURL, let (screen, size) = beginScriptedCapture() else { return done() }
        let press = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
        screen.toolMouseDown(at: CGPoint(x: size.width * 0.2, y: size.height * 0.2), event: press)
        screen.toolMouseDragged(to: CGPoint(x: size.width * 0.6, y: size.height * 0.5), event: press)
        screen.toolMouseUp(at: CGPoint(x: size.width * 0.6, y: size.height * 0.5), event: press)
        guard let image = screen.renderedImage() else { return done() }
        let target = url.deletingLastPathComponent().appendingPathComponent("captured/Screenshot.png")
        try? FileManager.default.removeItem(at: target)
        CaptureOutput.write(image, scale: screen.shot.scale, format: .png, to: target)
        wait(for: { FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) }) {
            let info = (try? ImageSource(url: target))?.properties() ?? [:]
            print("saved: \(target.lastPathComponent), \(info[kCGImagePropertyPixelWidth] ?? "?")×\(info[kCGImagePropertyPixelHeight] ?? "?") px at \(info[kCGImagePropertyDPIWidth] ?? "?") dpi")
            done()
        }
    }

    /// Selects a part of the picture, marks it up through the entry points real mouse input uses, and prints
    /// what would be copied. `capture-full` takes the whole display, where the panels have to move inside;
    /// `capture-window` clicks a window; `capture-edit` then hands the result to the editor in this window.
    private func runCaptureScript(_ name: String) {
        guard let (screen, size) = beginScriptedCapture() else { return }
        let w = size.width, h = size.height

        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
        func drag(_ a: CGPoint, _ b: CGPoint) {
            screen.toolMouseDown(at: a, event: event(.leftMouseDown))
            for step in 1...8 {
                let t = CGFloat(step) / 8
                screen.toolMouseDragged(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), event: event(.leftMouseDragged))
            }
            screen.toolMouseUp(at: b, event: event(.leftMouseUp))
        }
        func report(_ label: String) {
            let selection = screen.selection ?? .zero
            print("\(label): \(Int(selection.minX)),\(Int(selection.minY)) \(Int(selection.width))×\(Int(selection.height))")
        }

        // The proportions are a saved preference; a scripted run must leave it as it found it.
        let savedAspect = Settings.shared.captureAspect
        defer { Settings.shared.captureAspect = savedAspect }
        screen.model.aspect = nil
        // Later, once the panels have been laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.reportHints(on: screen, scenario: name) }
        switch name {
        case "capture-full":
            screen.selectWholeScreen()
            report("whole screen")
        case "capture-window":
            screen.toolMouseMoved(to: point(0.3, 0.4), event: event(.mouseMoved))
            drag(point(0.3, 0.4), point(0.3, 0.4))
            report("click on a window")
        default:
            drag(point(0.25, 0.2), point(0.7, 0.8))
            report("free drag")
            screen.model.aspect = CaptureAspect(width: 16, height: 9)
            report("16 : 9 chosen")
            // The bottom-right corner, pulled outward past the screen.
            if let corner = screen.selection.map({ CGPoint(x: $0.maxX, y: $0.maxY) }) { drag(corner, point(1.2, 1.2)) }
            report("corner dragged out")
            screen.model.width = 800
            screen.model.height = 500
            screen.applyTypedSize()
            report("800 × 500 typed, proportions \(screen.model.aspect?.title ?? "free")")
            screen.apply(CaptureSize.presets[1])
            report("preset \(CaptureSize.presets[1].name)")
        }
        guard let editor = screen.editor, let selection = screen.selection else { return }
        func inside(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: selection.minX + selection.width * x, y: selection.minY + selection.height * y)
        }
        screen.choose(.arrow, in: .arrow)
        drag(inside(0.15, 0.8), inside(0.45, 0.45))
        screen.choose(.rectangle, in: .shape)
        drag(inside(0.5, 0.15), inside(0.9, 0.5))
        screen.choose(.badge, in: .badge)
        drag(inside(0.12, 0.2), inside(0.12, 0.2))
        drag(inside(0.25, 0.2), inside(0.25, 0.2))
        screen.setColor(CaptureModel.palette[4])
        screen.choose(.highlighter, in: .draw)
        drag(inside(0.1, 0.92), inside(0.6, 0.92))
        screen.choose(.pixelateRegion, in: .hide)
        drag(inside(0.55, 0.6), inside(0.9, 0.85))
        screen.choose(.text, in: .text)
        drag(inside(0.3, 0.32), inside(0.3, 0.32))
        editor.typeText("Typed here")
        screen.setColor(CaptureModel.palette[0])
        // The pointer on bare screen moves the selection; on markup it moves the markup.
        screen.choose(.move, in: .pointer)
        let before = screen.selection ?? .zero
        drag(inside(0.75, 0.05), CGPoint(x: inside(0.75, 0.05).x - 40, y: inside(0.75, 0.05).y + 20))
        report("selection moved by \(Int((screen.selection ?? .zero).minX - before.minX)),\(Int((screen.selection ?? .zero).minY - before.minY))")
        screen.model.flyout = name == "capture-full" ? .color : nil

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pixix.diagnostics.capture"))
        let copied = screen.writeImage(to: pasteboard)
        let picture = NSImage(pasteboard: pasteboard)
        print("copy: \(copied), \(Int(picture?.size.width ?? 0))×\(Int(picture?.size.height ?? 0)) pt")
        pasteboard.releaseGlobally()
        if let rendered = screen.renderedImage() { print("picture: \(rendered.width)×\(rendered.height) px") }
        print("layers: \(editor.document.layers.map(\.name)), undo \(editor.document.history.entries.map(\.name))")
        print("shortcut: \(Settings.shared.captureHotKey?.title ?? "none"), file \(CaptureOutput.fileName(format: .png, date: Date(timeIntervalSince1970: 0)))")
        // Claimed and let go at once: this only asks macOS whether the shortcut is free.
        var presses = 0
        let probe = GlobalHotKey { presses += 1 }
        let granted = probe.register(Settings.shared.captureHotKey ?? .standard)
        // The press is handed to the app the way macOS hands it over; nobody presses anything.
        let delivered = probe.simulatePress()
        probe.unregister()
        print("shortcut granted by macOS: \(granted), a press delivered: \(delivered), handled \(presses) time(s), screen access: \(ScreenGrabber.hasAccess)")
        // The capture is over: what it held should be given back.
        if name == "capture-closed" { CaptureAgent.shared.session?.end() }
        if name == "capture-edit", let document = screen.makeDocument() {
            CaptureAgent.shared.session?.end(returningFocus: false)
            openDocument(document)
            self.editor?.model.tool = .move
            self.editor?.model.expandedSections = ["layers", "history"]
            print("editor: \(Int(document.size.width))×\(Int(document.size.height)), layers \(document.layers.map(\.name)), locked \(document.layers.filter(\.isLocked).count), dirty \(self.editor?.isDirty ?? false)")
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
