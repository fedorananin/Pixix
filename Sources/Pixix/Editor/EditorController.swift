import AppKit
import CoreImage
import PixixCodec
import PixixEngine

/// Runs an editing session in a window: owns the document, puts it on screen and routes input to tools.
@MainActor
final class EditorController: CanvasToolHandler {
    let document: Document
    let model = EditorModel()
    unowned let host: ViewerWindowController
    let canvas: CanvasView

    /// The file Save overwrites. Nil when there is nothing sensible to overwrite.
    private(set) var fileURL: URL?
    /// Metadata of the opened file, carried into whatever is saved.
    let sourceProperties: [CFString: Any]?
    /// True for content that never existed on disk in this form, such as a pasted picture.
    private var startsUnsaved: Bool
    /// True until the first Save: the file on disk is still what it was before this session touched it.
    private(set) var fileIsUntouched: Bool
    /// Small pictures of the layers for the panel, redrawn a moment after the document settles.
    private(set) var thumbnails: [LayerID: CGImage] = [:]
    private var thumbnailWork: DispatchWorkItem?

    private var tool: EditorTool!
    private var buffers: [PixelBuffer] = []
    private var front = 0
    /// What each buffer still has to redraw before it can be shown.
    private var stale: [CGRect] = [.infinite, .infinite]
    private var pendingDirty = CGRect.null
    private var pendingEverything = true
    private var isRenderScheduled = false
    private lazy var selectionOverlay = SelectionOverlay(canvas: canvas, document: document)

    init(host: ViewerWindowController, document: Document, fileURL: URL?, properties: [CFString: Any]?, startsUnsaved: Bool) {
        self.host = host
        self.canvas = host.canvas
        self.document = document
        self.fileURL = fileURL
        self.sourceProperties = properties
        self.startsUnsaved = startsUnsaved
        fileIsUntouched = fileURL != nil
        model.controller = self
        tool = makeTool(model.tool)
        document.onChange = { [weak self] change in self?.documentDidChange(change) }
        document.history.onChange = { [weak self] in self?.historyDidChange() }
    }

    var isDirty: Bool { startsUnsaved || document.history.isDirty }

    func markSaved(url: URL) {
        fileURL = url
        startsUnsaved = false
        // From here on the file holds this session's own work.
        fileIsUntouched = false
        document.history.markSaved()
        host.window?.isDocumentEdited = false
    }

    func flattenedImage() -> CGImage {
        document.flattenedImage() ?? PixelBuffer(width: 1, height: 1, colorSpace: document.colorSpace)!.makeImage()
    }

    func saveProject(to url: URL) throws {
        try ProjectFile.write(document, to: url)
    }

    // MARK: Lifecycle

    func activate() {
        canvas.toolHandler = self
        canvas.allowsNavigation = false
        canvas.showsCheckerboard = true
        canvas.fitPadding = 28
        canvas.panSlack = 0.45
        canvas.setContentSize(document.size, resetView: true)
        tool.activate()
        flush()
        host.window?.isDocumentEdited = isDirty
    }

    func deactivate() {
        tool.deactivate()
        thumbnailWork?.cancel()
        selectionOverlay.stop()
        document.onChange = nil
        document.history.onChange = nil
        canvas.toolHandler = nil
        canvas.allowsNavigation = true
        canvas.showsCheckerboard = false
        canvas.fitPadding = 0
        canvas.panSlack = 0
        canvas.setSurface(nil)
        canvas.setPreviewRotation(0, about: .zero)
        host.window?.isDocumentEdited = false
    }

    // MARK: Display

    private func documentDidChange(_ change: DocumentChange) {
        switch change {
        case .pixels(let rect): pendingDirty = pendingDirty.union(rect)
        case .everything: pendingEverything = true
        }
        guard !isRenderScheduled else { return }
        isRenderScheduled = true
        // Several changes in one event collapse into a single redraw.
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func historyDidChange() {
        model.revision += 1
        host.window?.isDocumentEdited = isDirty
        host.window?.toolbar?.validateVisibleItems()
    }

    private func flush() {
        isRenderScheduled = false
        let everything = pendingEverything
        let dirty = pendingDirty
        pendingEverything = false
        pendingDirty = .null

        let size = document.size
        if buffers.first?.size != size {
            buffers = (0..<2).compactMap { _ in
                PixelBuffer(width: Int(size.width), height: Int(size.height), colorSpace: document.colorSpace)
            }
            stale = [.infinite, .infinite]
            front = 0
        }
        guard buffers.count == 2 else { return }
        if canvas.contentSize != size {
            canvas.setContentSize(size, resetView: false)
            (tool as? CropTool)?.reset()
            host.updateTitle()
        }

        // Draw into the buffer that is not on screen, then swap. Core Animation only notices new contents.
        let back = 1 - front
        let change: CGRect = everything ? .infinite : dirty
        stale[0] = stale[0].union(change)
        stale[1] = stale[1].union(change)
        let region = stale[back]
        if !region.isNull {
            document.renderer.render(
                document.composite(), to: buffers[back].surface, documentSize: size,
                rect: region.isInfinite ? nil : region
            )
            stale[back] = .null
            canvas.setSurface(buffers[back].surface)
            front = back
        }

        if everything {
            model.revision += 1
            selectionOverlay.update()
            host.updateTitle()
            tool.documentDidChange()
        }
        canvas.setOverlayNeedsDisplay()
        scheduleThumbnails()
    }

    /// Redraws the layer pictures once the document has been still for a moment, so a drag or a brush
    /// stroke does not pay for them on every step.
    private func scheduleThumbnails() {
        thumbnailWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var fresh: [LayerID: CGImage] = [:]
            // Text, shapes and areas are told apart by their symbols; only pictures need a picture.
            for layer in self.document.layers where layer.isRaster {
                fresh[layer.id] = self.document.thumbnail(ofLayer: layer.id, maxPixel: 96)
            }
            self.thumbnails = fresh
            self.model.thumbnailRevision += 1
        }
        thumbnailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (thumbnails.isEmpty ? 0.05 : 0.3), execute: work)
    }

    func viewportDidChange() {
        selectionOverlay.update()
    }

    // MARK: Tools

    private func makeTool(_ kind: ToolKind) -> EditorTool {
        switch kind {
        case .move: MoveTool(editor: self)
        case .crop: CropTool(editor: self)
        case .selectRectangle, .selectEllipse, .lasso: SelectTool(editor: self)
        case .wand: WandTool(editor: self)
        case .brush, .pencil, .eraser, .clone: PaintTool(editor: self)
        case .fill: FillTool(editor: self)
        case .gradient: GradientTool(editor: self)
        case .picker: PickerTool(editor: self)
        case .text, .callout: TextTool(editor: self)
        case .badge, .arrow, .line, .rectangle, .ellipse, .pen, .highlighter: ShapeTool(editor: self)
        case .blurRegion, .pixelateRegion, .spotlightRegion: RegionTool(editor: self)
        }
    }

    /// Switches to the text tool and starts typing into a text layer on the canvas.
    func beginTextEditing(_ id: LayerID, at point: CGPoint? = nil) {
        if !(tool is TextTool) { model.tool = .text }
        (tool as? TextTool)?.beginEditing(id, at: point)
    }

    /// Types into the text being edited on the canvas. For scripted scenarios.
    func typeText(_ string: String, selecting range: NSRange? = nil) {
        (tool as? TextTool)?.type(string)
        if let range { (tool as? TextTool)?.select(range) }
    }

    func toolDidChange(from old: ToolKind) {
        // Tools of one family share an object, so switching brush to eraser keeps the clone source and such.
        let sameFamily = type(of: makeTool(old)) == type(of: makeTool(model.tool))
        if !sameFamily {
            tool.deactivate()
            tool = makeTool(model.tool)
            tool.activate()
        }
        canvas.setOverlayNeedsDisplay()
        canvas.window?.makeFirstResponder(canvas)
    }

    func cropSettingsDidChange() {
        (tool as? CropTool)?.settingsDidChange()
    }

    func applyCrop() {
        (tool as? CropTool)?.apply()
    }

    func resetCrop() {
        model.straighten = 0
        (tool as? CropTool)?.reset()
    }

    func toolMouseDown(at point: CGPoint, event: NSEvent) { tool.mouseDown(at: point, event: event) }
    func toolMouseDragged(to point: CGPoint, event: NSEvent) { tool.mouseDragged(to: point, event: event) }
    func toolMouseUp(at point: CGPoint, event: NSEvent) { tool.mouseUp(at: point, event: event) }
    func toolMouseMoved(to point: CGPoint, event: NSEvent) { tool.mouseMoved(to: point, event: event) }
    func toolCursor(at point: CGPoint) -> NSCursor { tool.cursor(at: point) }
    func toolFlagsChanged(_ event: NSEvent) {}
    var toolHoldsKeyboard: Bool { tool.holdsKeyboard }
    func drawOverlay(in context: CGContext, canvas: CanvasView) { tool.drawOverlay(in: context, canvas: canvas) }

    // MARK: Keyboard

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        if tool.keyDown(event) { return true }
        switch event.keyCode {
        case 51, 117:
            deleteSelectionOrLayer()
            return true
        case 53:
            if document.selection != nil {
                document.setSelection(nil)
                return true
            }
            return false
        case 123, 124, 125, 126:
            // Arrow keys must not flip to another file while editing.
            return true
        default:
            break
        }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), let key = characters.first else { return false }
        if key == "x" {
            model.swapColors()
            return true
        }
        if let kind = ToolKind.allCases.first(where: { $0.shortcut == key }) {
            model.tool = kind
            return true
        }
        return false
    }

    /// Arrow keys move the active layer by a pixel, or ten with Shift.
    func nudgeActiveLayer(with event: NSEvent) -> Bool {
        guard let layer = document.activeLayer, !layer.isLocked else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGPoint
        switch event.keyCode {
        case 123: delta = CGPoint(x: -step, y: 0)
        case 124: delta = CGPoint(x: step, y: 0)
        case 125: delta = CGPoint(x: 0, y: step)
        case 126: delta = CGPoint(x: 0, y: -step)
        default: return false
        }
        document.updateLayer(layer.id, name: "Nudge", key: "nudge") {
            $0.transform = $0.transform.concatenating(CGAffineTransform(translationX: delta.x, y: delta.y))
        }
        return true
    }

    func deleteSelectionOrLayer() {
        guard let layer = document.activeLayer else { return }
        if document.selection != nil, layer.isRaster {
            document.erase()
        } else if !layer.isRaster, document.layers.count > 1 {
            document.removeLayer(layer.id)
        } else if layer.isRaster, document.layers.count > 1, model.tool == .move {
            document.removeLayer(layer.id)
        } else {
            NSSound.beep()
        }
    }

    // MARK: Canvas-level operations

    func rotateCanvas(quarterTurns: Int) {
        document.rotate(quarterTurns: quarterTurns)
        canvas.fit()
    }

    func flipCanvas(horizontal: Bool) {
        document.flip(horizontal: horizontal)
    }

    // MARK: Clipboard and drops

    func copySelection(merged: Bool) {
        guard let copied = document.copyImage(layer: merged ? nil : document.activeLayerID) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let size = NSSize(width: copied.image.width, height: copied.image.height)
        pasteboard.writeObjects([NSImage(cgImage: copied.image, size: size)])
    }

    func cut() {
        copySelection(merged: false)
        if document.activeLayer?.isRaster == true { document.erase() }
    }

    /// The image point in the middle of what is visible, so new content lands where the user is looking.
    private var visibleCenter: CGPoint {
        let point = canvas.imagePoint(fromView: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        return CGPoint(
            x: min(max(point.x, 0), document.size.width), y: min(max(point.y, 0), document.size.height)
        )
    }

    @discardableResult
    func paste(from pasteboard: NSPasteboard = .general, at point: CGPoint? = nil) -> Bool {
        let center = point ?? visibleCenter
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        var added = false
        for url in urls where ReadableTypes.isReadable(url) {
            if let image = try? ImageSource(url: url).image() {
                document.addImageLayer(image, name: url.deletingPathExtension().lastPathComponent, center: center)
                added = true
            }
        }
        if added {
            didAddObject()
            return true
        }
        if let image = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            document.addImageLayer(image, name: "Pasted Image", center: center)
            didAddObject()
            return true
        }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            var text = model.textDefaults
            text.string = string
            text.color = model.primaryColor
            text.tail = nil
            var layer = Layer(name: "Text", content: .text(text))
            let size = layer.frameBounds.size
            layer.transform = CGAffineTransform(translationX: center.x - size.width / 2, y: center.y - size.height / 2)
            document.addLayer(layer, name: "Paste Text")
            didAddObject()
            return true
        }
        return false
    }

    func handleDrop(_ pasteboard: NSPasteboard, at point: CGPoint) -> Bool {
        paste(from: pasteboard, at: point)
    }

    /// New pictures and text arrive ready to be placed, so switch to the tool that places them.
    private func didAddObject() {
        if model.tool != .move { model.tool = .move }
    }

    func addImageLayer(from url: URL) {
        guard let image = try? ImageSource(url: url).image() else {
            NSSound.beep()
            return
        }
        document.addImageLayer(image, name: url.deletingPathExtension().lastPathComponent, center: visibleCenter)
        didAddObject()
    }

    // MARK: Effects and dialogs

    func beginEffect(_ effect: EffectDescriptor) {
        guard let layer = document.activeLayer, layer.isRaster, !layer.isLocked else {
            host.showToast("Select a picture layer first — effects change pixels")
            return
        }
        if effect.parameters.isEmpty {
            document.applyEffect(effect, values: [:])
            return
        }
        model.effectValues = effect.defaults
        document.preview = EffectPreview(layerID: layer.id, effect: effect, values: model.effectValues)
        host.presentEditorDialog(.effect(effect))
    }

    func updateEffectPreview(_ effect: EffectDescriptor) {
        guard let layer = document.activeLayer else { return }
        document.preview = EffectPreview(layerID: layer.id, effect: effect, values: model.effectValues)
    }

    func finishEffect(_ effect: EffectDescriptor, apply: Bool) {
        if apply {
            document.applyEffect(effect, values: model.effectValues)
        } else {
            document.preview = nil
        }
    }

    func beginResize() {
        model.resizeWidth = Int(document.size.width)
        model.resizeHeight = Int(document.size.height)
        model.resizeKeepsAspect = true
        host.presentEditorDialog(.resize)
    }

    func beginCanvasSize() {
        model.canvasWidth = Int(document.size.width)
        model.canvasHeight = Int(document.size.height)
        model.canvasAnchor = CGPoint(x: 0.5, y: 0.5)
        host.presentEditorDialog(.canvasSize)
    }

    func cropToSelection() {
        guard let bounds = document.selection?.bounds, !bounds.isEmpty else { return }
        document.crop(to: bounds)
        canvas.fit()
    }

    /// Puts pictures under the canvas or beside it, each scaled to span that side.
    func appendImages(from urls: [URL], to edge: CanvasEdge) {
        var added = false
        for url in urls {
            guard let image = try? ImageSource(url: url).image() else { continue }
            if document.appendImage(image, name: url.deletingPathExtension().lastPathComponent, to: edge) != nil {
                added = true
            } else {
                host.showToast("The picture would grow past \(PixelBuffer.maxDimension) px")
            }
        }
        guard added else { return }
        didAddObject()
        canvas.fit()
    }

    // MARK: Subject

    /// Selects what the picture is of: the active picture layer when there is one, else everything visible.
    func selectSubject() {
        let layer = document.activeLayer?.isRaster == true ? document.activeLayerID : nil
        findSubject(in: layer) { [weak self] selection in
            self?.document.setSelection(selection, name: "Select Subject")
        }
    }

    /// Makes everything around the subject of the active picture layer transparent.
    func removeBackground() {
        guard let layer = document.activeLayer, layer.isRaster, !layer.isLocked else {
            host.showToast("Select a picture layer first")
            return
        }
        findSubject(in: layer.id) { [weak self] selection in
            self?.document.eraseOutside(selection, layer: layer.id, name: "Remove Background")
        }
    }

    private var isFindingSubject = false

    private func findSubject(in layer: LayerID?, then use: @escaping (Selection) -> Void) {
        guard !isFindingSubject, let image = document.image(ofLayer: layer) else { return }
        isFindingSubject = true
        let size = document.size
        host.showToast("Looking for the subject…")
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> Result<Data?, Error> in
                Result { try SubjectFinder.mask(for: image) }
            }.value
            guard let self else { return }
            self.isFindingSubject = false
            // The picture may have been cropped or closed while the search ran.
            guard self.host.editor === self, self.document.size == size else { return }
            switch found {
            case .success(let coverage?):
                guard let selection = Selection(coverage: coverage, width: Int(size.width), height: Int(size.height)),
                      !selection.isEmpty
                else { fallthrough }
                use(selection)
                self.host.showToast("Subject found")
            case .success:
                self.host.showToast("Nothing in this picture stands out as a subject")
            case .failure(let error):
                self.host.present(error)
            }
        }
    }

    // MARK: Menu validation

    private static let editorActions: Set<Selector> = [
        #selector(ViewerWindowController.undoEdit(_:)), #selector(ViewerWindowController.redoEdit(_:)),
        #selector(ViewerWindowController.cut(_:)),
        #selector(ViewerWindowController.copyMerged(_:)), #selector(ViewerWindowController.deleteSelection(_:)),
        #selector(ViewerWindowController.selectAll(_:)), #selector(ViewerWindowController.deselect(_:)),
        #selector(ViewerWindowController.invertSelection(_:)), #selector(ViewerWindowController.resizeImage(_:)),
        #selector(ViewerWindowController.changeCanvasSize(_:)), #selector(ViewerWindowController.cropToSelection(_:)),
        #selector(ViewerWindowController.rotate180(_:)), #selector(ViewerWindowController.flipHorizontal(_:)),
        #selector(ViewerWindowController.flipVertical(_:)), #selector(ViewerWindowController.flattenImage(_:)),
        #selector(ViewerWindowController.newLayer(_:)), #selector(ViewerWindowController.duplicateLayer(_:)),
        #selector(ViewerWindowController.deleteLayer(_:)), #selector(ViewerWindowController.addImageLayer(_:)),
        #selector(ViewerWindowController.mergeDown(_:)), #selector(ViewerWindowController.moveLayerUp(_:)),
        #selector(ViewerWindowController.moveLayerDown(_:)), #selector(ViewerWindowController.rasterizeLayer(_:)),
        #selector(ViewerWindowController.applyEffect(_:)), #selector(ViewerWindowController.saveProjectAs(_:)),
        #selector(ViewerWindowController.fillSelection(_:)), #selector(ViewerWindowController.selectTool(_:)),
        #selector(ViewerWindowController.selectSubject(_:)), #selector(ViewerWindowController.removeBackground(_:)),
        #selector(ViewerWindowController.addImageBelow(_:)), #selector(ViewerWindowController.addImageToTheRight(_:)),
    ]

    /// True for commands that only make sense while editing.
    static func isEditorAction(_ action: Selector) -> Bool {
        editorActions.contains(action)
    }

    /// Returns nil for commands the editor has no opinion about.
    func validate(action: Selector, menuItem: NSMenuItem?) -> Bool? {
        let layer = document.activeLayer
        switch action {
        case #selector(ViewerWindowController.undoEdit(_:)):
            menuItem?.title = document.history.undoName.map { "Undo \($0)" } ?? "Undo"
            return document.history.canUndo
        case #selector(ViewerWindowController.redoEdit(_:)):
            menuItem?.title = document.history.redoName.map { "Redo \($0)" } ?? "Redo"
            return document.history.canRedo
        case #selector(ViewerWindowController.deselect(_:)), #selector(ViewerWindowController.cropToSelection(_:)):
            return document.selection != nil
        case #selector(ViewerWindowController.cut(_:)), #selector(ViewerWindowController.deleteSelection(_:)):
            return layer != nil
        case #selector(ViewerWindowController.deleteLayer(_:)):
            return document.layers.count > 1
        case #selector(ViewerWindowController.mergeDown(_:)), #selector(ViewerWindowController.moveLayerDown(_:)):
            return (document.activeIndex ?? 0) > 0
        case #selector(ViewerWindowController.moveLayerUp(_:)):
            return (document.activeIndex ?? Int.max) < document.layers.count - 1
        case #selector(ViewerWindowController.rasterizeLayer(_:)):
            guard let layer else { return false }
            return layer.effectRegion == nil && !layer.isAligned(to: document.size)
        case #selector(ViewerWindowController.flattenImage(_:)):
            return document.layers.count > 1 || layer?.isRaster == false
        case #selector(ViewerWindowController.applyEffect(_:)), #selector(ViewerWindowController.removeBackground(_:)):
            return layer?.isRaster == true
        case #selector(ViewerWindowController.selectTool(_:)):
            if let raw = menuItem?.representedObject as? String { menuItem?.state = raw == model.tool.rawValue ? .on : .off }
            return true
        default:
            return nil
        }
    }
}

/// Animated outline around the selection ("marching ants"), drawn on the GPU at screen resolution
/// so that it works for any mask, including ones from the magic wand.
@MainActor
final class SelectionOverlay {
    private unowned let canvas: CanvasView
    private unowned let document: Document
    private var buffers: [PixelBuffer] = []
    private var front = 0
    private var timer: Timer?
    private var phase: CGFloat = 0

    init(canvas: CanvasView, document: Document) {
        self.canvas = canvas
        self.document = document
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        canvas.selectionLayer.contents = nil
    }

    func update() {
        guard document.selection != nil else {
            stop()
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.phase += 1.5
                    self.render()
                }
            }
        }
        render()
    }

    private func render() {
        guard let selection = document.selection else { return }
        let size = canvas.pixelSize
        guard size.width >= 1, size.height >= 1, size.width <= 16384, size.height <= 16384 else { return }
        if buffers.first?.size != size {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            buffers = (0..<2).compactMap { _ in PixelBuffer(width: Int(size.width), height: Int(size.height), colorSpace: space) }
        }
        guard buffers.count == 2 else { return }

        // Map the mask from document space straight to screen pixels (both with y pointing up).
        let backing = canvas.backingScaleFactor
        let rect = canvas.imageRect
        let scale = canvas.scale * backing
        let toScreen = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale, tx: rect.minX * backing, ty: (canvas.bounds.height - rect.maxY) * backing
        )
        let screen = CGRect(origin: .zero, size: size)
        let mask = selection.ciImage().samplingNearest().transformed(by: toScreen).cropped(to: screen)
        let edge = mask
            .composited(over: CIImage(color: .black).cropped(to: screen))
            .applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: 1])
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor.white, "inputColor1": CIColor.black, kCIInputWidthKey: 4 * backing,
            kCIInputSharpnessKey: 1, kCIInputCenterKey: CIVector(x: phase * backing, y: 0),
        ])?.outputImage?.transformed(by: CGAffineTransform(rotationAngle: .pi / 4)) ?? CIImage(color: .white)
        let ants = stripes.cropped(to: screen).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: edge,
        ])
        let back = 1 - front
        document.renderer.render(ants, to: buffers[back].surface, documentSize: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.selectionLayer.contents = buffers[back].surface
        CATransaction.commit()
        front = back
    }
}
