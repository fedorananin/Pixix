import AppKit
import PixixCodec
import PixixEngine

/// One Pixix window: browses a folder of images and hosts the editor.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, CanvasViewDelegate {
    let canvas = CanvasView()
    private(set) var browser: FolderBrowser?
    private var loadTask: Task<Void, Never>?
    private var player: AnimationPlayer?
    /// What is on screen right now.
    private(set) var displayed: (url: URL, loaded: LoadedImage)?
    /// The frame of an animation that is currently showing.
    private(set) var currentFrameImage: CGImage?

    private let previousButton = FloatingButton(symbol: "chevron.left", toolTip: "Previous Image")
    private let nextButton = FloatingButton(symbol: "chevron.right", toolTip: "Next Image")
    private let zoomBar = ZoomBar()
    private let message = MessageView()
    private var chromeTimer: Timer?
    private var chromeVisible = true

    let leftPanel = NSView()
    let rightPanel = NSView()
    let bottomPanel = NSView()
    private var leftWidth: NSLayoutConstraint!
    private var rightWidth: NSLayoutConstraint!
    private var bottomHeight: NSLayoutConstraint!

    var editor: EditorController?
    private var filmstrip: FilmstripView?
    private var slideshowTimer: Timer?
    private var infoPopover: NSPopover?
    /// Text recognition over the picture. Made on first use, so it costs nothing until a picture is up.
    private(set) var liveText: LiveTextController?
    lazy var viewerToolbar = makeToolbar(identifier: "viewer")
    lazy var editorToolbar = makeToolbar(identifier: "editor")

    /// Called once, the first time an image reaches the screen.
    var onFirstImage: (() -> Void)?

    var isEditing: Bool { editor != nil }
    var currentURL: URL? { browser?.current }
    /// The Info popover's window while it is up.
    var infoWindow: NSWindow? { infoPopover?.isShown == true ? infoPopover?.contentViewController?.view.window : nil }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 480, height: 360)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.11, alpha: 1)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Pixix"
        super.init(window: window)
        window.delegate = self
        buildLayout()
        window.toolbar = viewerToolbar
        window.toolbarStyle = .unified
        if !window.setFrameUsingName("ViewerWindow") { window.center() }
        window.setFrameAutosaveName("ViewerWindow")
        window.makeFirstResponder(canvas)
        showEmptyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        canvas.delegate = self
        for view in [canvas, leftPanel, rightPanel, bottomPanel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        leftWidth = leftPanel.widthAnchor.constraint(equalToConstant: 0)
        rightWidth = rightPanel.widthAnchor.constraint(equalToConstant: 0)
        bottomHeight = bottomPanel.heightAnchor.constraint(equalToConstant: 0)
        let guide = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            leftWidth, rightWidth, bottomHeight,
            leftPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            leftPanel.topAnchor.constraint(equalTo: guide.topAnchor),
            leftPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rightPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: guide.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomPanel.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            bottomPanel.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            bottomPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            canvas.topAnchor.constraint(equalTo: guide.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomPanel.topAnchor),
        ])

        for view in [previousButton, nextButton, zoomBar, message] as [NSView] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            previousButton.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 16),
            previousButton.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -16),
            nextButton.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            zoomBar.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            zoomBar.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -16),
            message.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            message.widthAnchor.constraint(equalToConstant: 420),
            message.heightAnchor.constraint(equalToConstant: 200),
        ])
        previousButton.target = self
        previousButton.action = #selector(previousImage(_:))
        nextButton.target = self
        nextButton.action = #selector(nextImage(_:))
        zoomBar.zoomIn.target = self
        zoomBar.zoomIn.action = #selector(zoomIn(_:))
        zoomBar.zoomOut.target = self
        zoomBar.zoomOut.action = #selector(zoomOut(_:))
        zoomBar.fit.target = self
        zoomBar.fit.action = #selector(zoomToFit(_:))
        zoomBar.actual.target = self
        zoomBar.actual.action = #selector(zoomActualSize(_:))
        zoomBar.playPause.target = self
        zoomBar.playPause.action = #selector(togglePlayback(_:))
    }

    func setPanels(left: CGFloat, right: CGFloat) {
        leftWidth.constant = left
        rightWidth.constant = right
    }

    // MARK: Opening

    /// One file browses its whole folder; several browse just those files. A folder browses what is in it.
    func open(_ urls: [URL]) {
        var images: [URL] = [], folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            if isDirectory.boolValue { folders.append(url) } else { images.append(url) }
        }
        guard !images.isEmpty else {
            // A project is a folder on disk too.
            if let project = folders.first(where: { $0.pathExtension.lowercased() == ProjectFile.fileExtension }) {
                openProject(project)
            } else if let folder = folders.first {
                openFolder(folder)
            }
            return
        }
        browser?.stop()
        let browser = FolderBrowser(urls: images)
        browser.onChange = { [weak self] currentChanged in
            guard let self else { return }
            if currentChanged { self.showCurrent() } else { self.updateTitle() }
            // The folder listing arrives after the first picture; the arrows depend on how many files there are.
            self.updateChromeState()
            self.filmstrip?.reload(files: browser.files, index: browser.index)
        }
        self.browser = browser
        showCurrent()
        filmstrip?.reload(files: browser.files, index: browser.index)
        for url in images { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    /// Starts browsing a folder from its first picture, in the order chosen in Settings.
    private func openFolder(_ folder: URL) {
        let order = Settings.shared.sortOrder, descending = Settings.shared.sortDescending
        Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) {
                FolderBrowser.list(folder: folder, order: order, descending: descending)
            }.value
            guard let self, !self.isEditing else { return }
            if let first = listed.first {
                self.open([first])
            } else {
                self.browser?.stop()
                self.browser = nil
                self.showEmptyState(
                    symbol: "folder", title: "No Images",
                    detail: "“\(folder.lastPathComponent)” has no pictures that Pixix can open."
                )
                self.onFirstImage?()
                self.onFirstImage = nil
            }
        }
    }

    private func showEmptyState(
        symbol: String = "photo.on.rectangle.angled", title: String = "No Image",
        detail: String = "Drop an image or a folder here, or choose File › Open."
    ) {
        canvas.setImage(nil)
        canvas.setContentSize(.zero, resetView: true)
        displayed = nil
        liveText?.clear()
        message.show(symbol: symbol, title: title, detail: detail)
        window?.title = "Pixix"
        window?.subtitle = ""
        window?.representedURL = nil
        updateChromeState()
    }

    func showCurrent() {
        loadTask?.cancel()
        player?.stop()
        player = nil
        liveText?.clear()
        guard let browser, let url = browser.current else {
            showEmptyState()
            return
        }
        message.isHidden = true
        updateTitle()

        let loader = ImageLoader.shared
        let extent = max(canvas.pixelExtent, 512)
        var shown = false
        if let hit = loader.cached(url) {
            display(hit, url: url, resetView: true)
            shown = true
            if hit.isFull {
                prefetchNeighbors()
                return
            }
        }
        loadTask = Task { [weak self] in
            do {
                let preview = try await loader.load(url, maxPixel: extent)
                guard let self, !Task.isCancelled, self.browser?.current == url else { return }
                self.display(preview, url: url, resetView: !shown)
                self.prefetchNeighbors()
                guard !preview.isFull else { return }
                // Wait a moment before the expensive decode, so flipping through a folder stays cheap.
                try await Task.sleep(for: .milliseconds(140))
                let full = try await loader.load(url, maxPixel: nil)
                guard !Task.isCancelled, self.browser?.current == url else { return }
                self.display(full, url: url, resetView: false)
            } catch {
                guard let self, !Task.isCancelled, self.browser?.current == url else { return }
                self.showFailure(url: url, error: error)
            }
        }
    }

    private func display(_ loaded: LoadedImage, url: URL, resetView: Bool) {
        guard !isEditing else { return }
        let first = displayed == nil
        displayed = (url, loaded)
        currentFrameImage = nil
        canvas.setContentSize(loaded.info.pixelSize, resetView: resetView)
        canvas.setImage(loaded.image)
        message.isHidden = true
        updateTitle()
        if loaded.info.isAnimated, player == nil, let source = try? ImageSource(url: url) {
            let player = AnimationPlayer(source: source, firstFrame: loaded.image) { [weak self] image, _ in
                guard let self, self.displayed?.url == url, !self.isEditing else { return }
                self.currentFrameImage = image
                self.canvas.setImage(image)
            }
            self.player = player
            player.play()
        }
        // On the next turn of the run loop, so that reading text never stands between a picture and the screen.
        liveText?.clear()
        DispatchQueue.main.async { [weak self] in self?.updateLiveText() }
        updateChromeState()
        if first || onFirstImage != nil {
            trace("image on screen (\(loaded.isFull ? "full" : "preview"), \(loaded.image.width)×\(loaded.image.height))")
            onFirstImage?()
            onFirstImage = nil
        }
    }

    private func showFailure(url: URL, error: Error) {
        canvas.setImage(nil)
        canvas.setContentSize(.zero, resetView: true)
        displayed = nil
        liveText?.clear()
        message.show(
            symbol: "exclamationmark.triangle", title: "Cannot Open Image",
            detail: "\(url.lastPathComponent)\n\(error.localizedDescription)"
        )
        updateChromeState()
        onFirstImage?()
        onFirstImage = nil
    }

    private func prefetchNeighbors() {
        guard let browser else { return }
        let wrap = Settings.shared.wrapAround
        let neighbors = [1, -1, 2, -2].compactMap { browser.neighbor(offset: $0, wrap: wrap) }
        var keep = Set(neighbors)
        if let current = browser.current { keep.insert(current) }
        ImageLoader.shared.setWanted(keep, by: self)
        ImageLoader.shared.prefetch(neighbors, maxPixel: max(canvas.pixelExtent, 512))
    }

    func updateTitle() {
        guard let window else { return }
        guard let browser, let url = browser.current else {
            window.title = "Pixix"
            window.subtitle = ""
            return
        }
        window.title = url.lastPathComponent
        window.representedURL = url
        var parts: [String] = []
        if browser.count > 1 { parts.append("\(browser.index + 1) of \(browser.count)") }
        if let editor {
            parts.append("\(Int(editor.document.size.width)) × \(Int(editor.document.size.height))")
        } else if let info = displayed?.loaded.info, displayed?.url == url {
            parts.append("\(Int(info.pixelSize.width)) × \(Int(info.pixelSize.height))")
        }
        window.subtitle = parts.joined(separator: "  ·  ")
    }

    // MARK: Chrome

    func updateChromeState() {
        let hasImage = displayed != nil || isEditing
        let canBrowse = !isEditing && (browser?.count ?? 0) > 1
        previousButton.isHidden = !canBrowse
        nextButton.isHidden = !canBrowse
        zoomBar.isHidden = !hasImage
        zoomBar.setZoom(percent: canvas.zoomPercent)
        zoomBar.setPlayback(visible: player != nil && !isEditing, playing: player?.isPlaying ?? false)
        window?.toolbar?.validateVisibleItems()
    }

    private func setChrome(visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.12 : 0.35
            previousButton.animator().alphaValue = visible ? 1 : 0
            nextButton.animator().alphaValue = visible ? 1 : 0
            zoomBar.animator().alphaValue = visible ? 1 : 0
        }
    }

    private func scheduleChromeHide() {
        chromeTimer?.invalidate()
        guard !isEditing else { return }
        chromeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setChrome(visible: false) }
        }
    }

    func canvasPointerDidMove(_ canvas: CanvasView) {
        setChrome(visible: true)
        scheduleChromeHide()
    }

    func canvasViewportDidChange(_ canvas: CanvasView) {
        zoomBar.setZoom(percent: canvas.zoomPercent)
        editor?.viewportDidChange()
        liveText?.layout()
    }

    // MARK: Live Text

    /// Looks for text in the picture on screen, once it is there at full size.
    private func updateLiveText() {
        guard Settings.shared.liveText, !isEditing, let displayed, displayed.loaded.isFull, !displayed.loaded.info.isAnimated else {
            liveText?.clear()
            return
        }
        if liveText == nil { liveText = LiveTextController(canvas: canvas) }
        liveText?.analyze(displayed.loaded.image)
    }

    @objc func toggleLiveText(_ sender: Any?) {
        Settings.shared.liveText.toggle()
        updateLiveText()
        showToast(Settings.shared.liveText ? "Live Text is on: select text in pictures" : "Live Text is off")
    }

    /// Stops everything that would keep changing the picture while it is being edited.
    func stopPlaybackForEditing() {
        loadTask?.cancel()
        player?.pause()
        liveText?.clear()
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        setChrome(visible: true)
        chromeTimer?.invalidate()
    }

    /// Makes the next `showCurrent` start from scratch, for example after the file was edited.
    func forgetDisplayedImage() {
        displayed = nil
        currentFrameImage = nil
    }

    /// The file on screen has a new name. A still picture simply carries on; an animation reads its frames
    /// from the file, so it starts over.
    func followRename(from old: URL, to new: URL) {
        ImageLoader.shared.move(old, to: new)
        let wasShown = displayed?.url == old
        if wasShown, let loaded = displayed?.loaded { displayed = (new, loaded) }
        browser?.replace(old, with: new)
        if wasShown, player != nil { showCurrent() }
    }

    // MARK: Navigation

    func canvas(_ canvas: CanvasView, navigateBy delta: Int) {
        navigate(by: delta)
    }

    func navigate(by delta: Int) {
        guard !isEditing, let browser else { return }
        if !browser.move(by: delta, wrap: Settings.shared.wrapAround) { NSSound.beep() }
    }

    /// The side buttons of a mouse, wherever in the window the pointer is: the first one goes forward, the second back.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3 where !isEditing: navigate(by: 1)
        case 4 where !isEditing: navigate(by: -1)
        default: super.otherMouseDown(with: event)
        }
    }

    /// Wheel events nobody took: from the arrows and the other controls laid over the canvas, and from the filmstrip.
    override func scrollWheel(with event: NSEvent) {
        guard !isEditing, !event.hasPreciseScrollingDeltas, let window,
              window.contentLayoutRect.contains(event.locationInWindow) else {
            super.scrollWheel(with: event)
            return
        }
        let target = window.contentView?.hitTest(event.locationInWindow)
        if target?.isDescendant(of: zoomBar) == true {
            // The zoom pill is not a place to turn pages from; behave as if the pointer were on what is under it.
            canvas.scrollWheel(with: event)
        } else {
            canvas.mouseWheel(with: event, overImage: false)
        }
    }

    @objc func nextImage(_ sender: Any?) { navigate(by: 1) }
    @objc func previousImage(_ sender: Any?) { navigate(by: -1) }
    @objc func firstImage(_ sender: Any?) { if !isEditing { browser?.go(to: 0) } }
    @objc func lastImage(_ sender: Any?) { if !isEditing, let browser { browser.go(to: browser.count - 1) } }

    @objc func zoomIn(_ sender: Any?) { canvas.zoomStep(1) }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomStep(-1) }
    @objc func zoomToFit(_ sender: Any?) { canvas.fit() }
    @objc func zoomActualSize(_ sender: Any?) { canvas.zoomToActualSize() }

    @objc func togglePlayback(_ sender: Any?) {
        player?.toggle()
        updateChromeState()
    }

    @objc func toggleSlideshow(_ sender: Any?) {
        if slideshowTimer != nil {
            slideshowTimer?.invalidate()
            slideshowTimer = nil
            return
        }
        guard !isEditing, (browser?.count ?? 0) > 1 else { return }
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: Settings.shared.slideshowInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isEditing, let browser = self.browser else { return }
                browser.move(by: 1, wrap: true)
            }
        }
    }

    var isSlideshowRunning: Bool { slideshowTimer != nil }

    @objc func toggleFilmstrip(_ sender: Any?) {
        Settings.shared.showsFilmstrip.toggle()
        applyFilmstripVisibility()
    }

    func applyFilmstripVisibility() {
        let show = Settings.shared.showsFilmstrip && !isEditing
        if show, filmstrip == nil {
            let strip = FilmstripView()
            strip.onSelect = { [weak self] index in
                guard let self, !self.isEditing else { return }
                self.browser?.go(to: index)
            }
            strip.translatesAutoresizingMaskIntoConstraints = false
            bottomPanel.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: bottomPanel.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: bottomPanel.trailingAnchor),
                strip.topAnchor.constraint(equalTo: bottomPanel.topAnchor),
                strip.bottomAnchor.constraint(equalTo: bottomPanel.bottomAnchor),
            ])
            filmstrip = strip
            if let browser { strip.reload(files: browser.files, index: browser.index) }
        }
        filmstrip?.isHidden = !show
        bottomHeight.constant = show ? FilmstripView.height : 0
    }

    // MARK: Keyboard

    func canvas(_ canvas: CanvasView, keyDown event: NSEvent) -> Bool {
        if let editor, editor.handleKeyDown(event) { return true }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 123: previousImage(nil)
        case 124: nextImage(nil)
        case 115: firstImage(nil)
        case 119: lastImage(nil)
        case 117: moveToTrash(nil)
        case 120: renameFile(nil)
        case 53:
            if let window, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else if isSlideshowRunning {
                toggleSlideshow(nil)
            } else {
                return false
            }
        case 49:
            if player != nil { togglePlayback(nil) } else { nextImage(nil) }
        default:
            switch event.charactersIgnoringModifiers {
            case "f": window?.toggleFullScreen(nil)
            case "+", "=": zoomIn(nil)
            case "-": zoomOut(nil)
            case "0": zoomToFit(nil)
            case "1": zoomActualSize(nil)
            case ",": player?.step(by: -1); updateChromeState()
            case ".": player?.step(by: 1); updateChromeState()
            default: return false
            }
        }
        return true
    }

    // MARK: File actions

    func canvas(_ canvas: CanvasView, didReceive pasteboard: NSPasteboard, at imagePoint: CGPoint) -> Bool {
        if let editor { return editor.handleDrop(pasteboard, at: imagePoint) }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        open(urls)
        return true
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard !isEditing, let url = currentURL else { return }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            ImageLoader.shared.invalidate(url)
            browser?.remove(url)
            if let trashed = trashed as URL? {
                window?.undoManager?.registerUndo(withTarget: self) { controller in
                    do {
                        try FileManager.default.moveItem(at: trashed, to: url)
                        controller.browser?.insert(url, select: true)
                    } catch {
                        controller.present(error)
                    }
                }
                window?.undoManager?.setActionName("Move to Trash")
            }
        } catch {
            present(error)
        }
    }

    @objc func rotateRight(_ sender: Any?) { rotate(clockwise: true) }
    @objc func rotateLeft(_ sender: Any?) { rotate(clockwise: false) }

    private func rotate(clockwise: Bool) {
        if let editor {
            editor.rotateCanvas(quarterTurns: clockwise ? 1 : -1)
            return
        }
        guard let url = currentURL, displayed?.url == url else { return }
        loadTask?.cancel()
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileRotation.rotate(url: url, clockwise: clockwise)
                }.value
                ImageLoader.shared.invalidate(url)
                guard let self, self.currentURL == url else { return }
                self.showCurrent()
            } catch {
                self?.present(error)
            }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func setAsWallpaper(_ sender: Any?) {
        guard let url = currentURL, let screen = window?.screen ?? NSScreen.main else { return }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            present(error)
        }
    }

    @objc func copy(_ sender: Any?) {
        if let editor {
            editor.copySelection(merged: false)
            return
        }
        guard let displayed else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Text selected in the picture is what the user means to copy.
        if let text = liveText?.selectedText, !text.isEmpty {
            pasteboard.setString(text, forType: .string)
            return
        }
        let size = NSSize(width: displayed.loaded.image.width, height: displayed.loaded.image.height)
        pasteboard.writeObjects([NSImage(cgImage: displayed.loaded.image, size: size), displayed.url as NSURL])
    }

    @objc func showInfo(_ sender: Any?) {
        if let infoPopover, infoPopover.isShown {
            infoPopover.close()
            return
        }
        guard let url = currentURL else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = InfoViewController(
            url: url, image: displayed?.url == url ? (currentFrameImage ?? displayed?.loaded.image) : nil
        )
        if let item = toolbarItem(.info) {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: NSRect(x: canvas.bounds.maxX - 40, y: 8, width: 1, height: 1), of: canvas, preferredEdge: .maxY)
        }
        infoPopover = popover
    }

    @objc func shareImage(_ sender: Any?) {
        guard let url = currentURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        // Anchor to the top-right corner of the picture, right under the toolbar button.
        picker.show(relativeTo: NSRect(x: canvas.bounds.maxX - 30, y: 0, width: 1, height: 1), of: canvas, preferredEdge: .maxY)
    }

    @objc func printImage(_ sender: Any?) {
        guard let image = editor?.flattenedImage() ?? displayed?.loaded.image, let window else { return }
        let size = NSSize(width: image.width, height: image.height)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.orientation = size.width > size.height ? .landscape : .portrait
        NSPrintOperation(view: view, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func present(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let editor, editor.isDirty else { return true }
        confirmDiscardingEdits { [weak self] proceed in
            if proceed { self?.window?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        editor?.deactivate()
        editor = nil
        loadTask?.cancel()
        player?.stop()
        slideshowTimer?.invalidate()
        chromeTimer?.invalidate()
        browser?.stop()
        liveText?.clear()
        ImageLoader.shared.forget(self)
        (NSApp.delegate as? AppDelegate)?.controllerDidClose(self)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateChromeState()
    }
}

extension ViewerWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validate(action: menuItem.action, menuItem: menuItem)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(action: item.action, menuItem: nil)
    }

    private func validate(action: Selector?, menuItem: NSMenuItem?) -> Bool {
        guard let action else { return true }
        let hasImage = displayed != nil || isEditing
        let hasFile = currentURL != nil
        if let editor, let verdict = editor.validate(action: action, menuItem: menuItem) { return verdict }
        switch action {
        case #selector(nextImage(_:)), #selector(previousImage(_:)), #selector(firstImage(_:)), #selector(lastImage(_:)):
            return !isEditing && (browser?.count ?? 0) > 1
        case #selector(toggleSlideshow(_:)):
            menuItem?.title = isSlideshowRunning ? "Stop Slideshow" : "Start Slideshow"
            return !isEditing && (browser?.count ?? 0) > 1
        case #selector(toggleFilmstrip(_:)):
            menuItem?.state = Settings.shared.showsFilmstrip ? .on : .off
            return !isEditing
        case #selector(toggleLiveText(_:)):
            menuItem?.state = Settings.shared.liveText ? .on : .off
            return !isEditing
        case #selector(moveToTrash(_:)), #selector(setAsWallpaper(_:)), #selector(renameFile(_:)),
             #selector(duplicateFile(_:)), #selector(copyToFolder(_:)), #selector(moveToFolder(_:)):
            return hasFile && !isEditing
        case #selector(openInNewWindow(_:)):
            return hasFile
        case #selector(revealInFinder(_:)), #selector(showInfo(_:)), #selector(shareImage(_:)):
            return hasFile
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            if isEditing { return true }
            return hasFile && displayed?.loaded.info.isAnimated == false
        case #selector(undoEdit(_:)) where !isEditing:
            menuItem?.title = window?.undoManager?.undoMenuItemTitle ?? "Undo"
            return window?.undoManager?.canUndo ?? false
        case #selector(redoEdit(_:)) where !isEditing:
            menuItem?.title = window?.undoManager?.redoMenuItemTitle ?? "Redo"
            return window?.undoManager?.canRedo ?? false
        case #selector(paste(_:)) where !isEditing:
            return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        case #selector(toggleEditing(_:)):
            menuItem?.title = isEditing ? "Finish Editing" : "Edit Image"
            return hasImage
        case #selector(saveDocument(_:)):
            return editor?.isDirty ?? false
        case #selector(saveDocumentAs(_:)), #selector(exportImage(_:)), #selector(printImage(_:)), #selector(copy(_:)):
            return hasImage
        case #selector(exportAgain(_:)):
            return hasImage && Settings.shared.lastExport != nil
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomToFit(_:)), #selector(zoomActualSize(_:)):
            return hasImage
        case #selector(togglePlayback(_:)):
            return player != nil && !isEditing
        default:
            // Everything else is an editor command.
            return editor != nil ? true : !EditorController.isEditorAction(action)
        }
    }
}
