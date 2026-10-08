import AppKit
import PixixCodec
import PixixEngine
import SwiftUI
import UniformTypeIdentifiers

extension ViewerWindowController {
    private static let paletteWidth: CGFloat = 46
    private static let inspectorWidth: CGFloat = 272

    // MARK: Entering and leaving

    @objc func toggleEditing(_ sender: Any?) {
        if editor != nil {
            finishEditing()
        } else {
            beginEditing()
        }
    }

    /// Opens the picture on screen in the editor, at full resolution.
    func beginEditing() {
        guard editor == nil, let url = currentURL, displayed?.url == url else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                // An animation is edited one frame at a time: the one being shown.
                let full = try await ImageLoader.shared.load(url, maxPixel: nil)
                guard self.editor == nil, self.currentURL == url else { return }
                let isAnimated = full.info.isAnimated
                let image = isAnimated ? (self.currentFrameImage ?? full.image) : full.image
                guard max(image.width, image.height) <= PixelBuffer.maxDimension, let document = Document(image: image) else {
                    self.showToast("This picture is too large to edit (limit \(PixelBuffer.maxDimension) px per side)")
                    return
                }
                let writable = ImageFormat(url: url) != nil && !isAnimated
                self.startEditing(
                    document: document, fileURL: writable ? url : nil,
                    properties: (try? ImageSource(url: url))?.properties(), startsUnsaved: false
                )
            } catch {
                self.present(error)
            }
        }
    }

    func openProject(_ url: URL) {
        do {
            let document = try ProjectFile.read(from: url)
            if editor != nil { stopEditing() }
            window?.title = url.lastPathComponent
            window?.representedURL = url
            startEditing(document: document, fileURL: url, properties: nil, startsUnsaved: false)
        } catch {
            present(error)
        }
    }

    /// Starts a document from the clipboard.
    func openPastedImage(_ image: CGImage) {
        guard let document = Document(image: image) else { return }
        startEditing(document: document, fileURL: nil, properties: nil, startsUnsaved: true)
    }

    private func startEditing(document: Document, fileURL: URL?, properties: [CFString: Any]?, startsUnsaved: Bool) {
        stopPlaybackForEditing()
        let editor = EditorController(
            host: self, document: document, fileURL: fileURL, properties: properties, startsUnsaved: startsUnsaved
        )
        self.editor = editor

        let palette = NSHostingView(rootView: ToolPaletteView(model: editor.model))
        let inspector = NSHostingView(rootView: InspectorView(model: editor.model, editor: editor))
        for (view, panel) in [(palette as NSView, leftPanel), (inspector as NSView, rightPanel)] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.subviews.forEach { $0.removeFromSuperview() }
            panel.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                view.topAnchor.constraint(equalTo: panel.topAnchor),
                view.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            ])
        }
        setPanels(left: Self.paletteWidth, right: Self.inspectorWidth)
        applyFilmstripVisibility()
        window?.toolbar = editorToolbar
        window?.contentView?.layoutSubtreeIfNeeded()
        editor.activate()
        updateChromeState()
        updateTitle()
        window?.makeFirstResponder(canvas)
    }

    /// Leaves the editor, asking about unsaved changes first.
    func finishEditing() {
        guard let editor else { return }
        guard editor.isDirty else {
            stopEditing()
            return
        }
        confirmDiscardingEdits { [weak self] proceed in
            if proceed { self?.stopEditing() }
        }
    }

    private func stopEditing() {
        guard let editor else { return }
        let hadFile = currentURL != nil
        editor.deactivate()
        self.editor = nil
        leftPanel.subviews.forEach { $0.removeFromSuperview() }
        rightPanel.subviews.forEach { $0.removeFromSuperview() }
        setPanels(left: 0, right: 0)
        window?.toolbar = viewerToolbar
        applyFilmstripVisibility()
        window?.contentView?.layoutSubtreeIfNeeded()
        if hadFile {
            forgetDisplayedImage()
            showCurrent()
        } else {
            // A project or pasted picture has no file to go back to.
            window?.close()
        }
    }

    /// Offers to save, discard or keep editing. Calls back with true once it is fine to drop the edits.
    func confirmDiscardingEdits(_ completion: @escaping (Bool) -> Void) {
        guard let window, let editor else {
            completion(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save the changes to this picture?"
        alert.informativeText = editor.fileURL != nil
            ? "Saving overwrites “\(editor.fileURL!.lastPathComponent)”. Your changes are lost if you don't save them."
            : "Your changes are lost if you don't save them."
        alert.addButton(withTitle: editor.fileURL != nil ? "Save" : "Save As…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.buttons.last?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                guard let self else { return }
                if editor.fileURL != nil {
                    self.saveDocument(nil)
                    // The write is asynchronous; leave once it has landed.
                    self.waitUntilSaved(completion)
                } else {
                    self.saveDocumentAs(nil)
                    completion(false)
                }
            case .alertThirdButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    private func waitUntilSaved(_ completion: @escaping (Bool) -> Void, attempts: Int = 0) {
        guard let editor else {
            completion(true)
            return
        }
        if !editor.isDirty {
            completion(true)
        } else if attempts < 100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitUntilSaved(completion, attempts: attempts + 1)
            }
        } else {
            completion(false)
        }
    }

    // MARK: Dialogs

    func presentEditorDialog(_ dialog: EditorDialog) {
        guard let window, let editor, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let close = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        let document = editor.document
        let canvas = self.canvas
        let content: AnyView
        switch dialog {
        case .resize:
            content = AnyView(ResizeDialog(model: editor.model, original: document.size) { size in
                close()
                if let size, size != document.size {
                    document.resize(to: size)
                    canvas.fit()
                }
            })
        case .canvasSize:
            content = AnyView(CanvasSizeDialog(model: editor.model, original: document.size) { size, anchor in
                close()
                if let size, size != document.size {
                    document.setCanvasSize(size, anchor: anchor)
                    canvas.fit()
                }
            })
        case .effect(let effect):
            content = AnyView(EffectDialog(
                model: editor.model, effect: effect,
                onChange: { [weak editor] in editor?.updateEffectPreview(effect) },
                onDone: { [weak editor] apply in
                    close()
                    editor?.finishEffect(effect, apply: apply)
                }
            ))
        }
        sheet.contentViewController = NSHostingController(rootView: content)
        window.beginSheet(sheet)
    }

    // MARK: Edit menu

    @objc func undoEdit(_ sender: Any?) {
        if let editor {
            editor.document.undo()
        } else {
            window?.undoManager?.undo()
        }
    }

    @objc func redoEdit(_ sender: Any?) {
        if let editor {
            editor.document.redo()
        } else {
            window?.undoManager?.redo()
        }
    }

    @objc func cut(_ sender: Any?) { editor?.cut() }
    @objc func copyMerged(_ sender: Any?) { editor?.copySelection(merged: true) }
    @objc func deleteSelection(_ sender: Any?) {
        // While text is being typed on the canvas, Delete means the selected letters, not the layer.
        if editor?.toolHoldsKeyboard == true {
            NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: sender)
        } else {
            editor?.deleteSelectionOrLayer()
        }
    }
    @objc override func selectAll(_ sender: Any?) { editor?.document.selectAll() }
    @objc func deselect(_ sender: Any?) { editor?.document.setSelection(nil) }
    @objc func invertSelection(_ sender: Any?) { editor?.document.invertSelection() }

    @objc func fillSelection(_ sender: Any?) {
        guard let editor else { return }
        editor.document.fill(with: editor.model.primaryColor)
    }

    @objc func paste(_ sender: Any?) {
        if let editor {
            if !editor.paste() { NSSound.beep() }
            return
        }
        // Outside the editor, pasting a picture starts a new one from it.
        if let image = NSImage(pasteboard: .general)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            (NSApp.delegate as? AppDelegate)?.newWindow(pasting: image)
        } else {
            NSSound.beep()
        }
    }

    @objc func selectSubject(_ sender: Any?) { editor?.selectSubject() }
    @objc func removeBackground(_ sender: Any?) { editor?.removeBackground() }

    // MARK: Image menu

    @objc func resizeImage(_ sender: Any?) { editor?.beginResize() }
    @objc func changeCanvasSize(_ sender: Any?) { editor?.beginCanvasSize() }
    @objc func cropToSelection(_ sender: Any?) { editor?.cropToSelection() }
    @objc func rotate180(_ sender: Any?) { editor?.rotateCanvas(quarterTurns: 2) }
    @objc func flipHorizontal(_ sender: Any?) { editor?.flipCanvas(horizontal: true) }
    @objc func flipVertical(_ sender: Any?) { editor?.flipCanvas(horizontal: false) }
    @objc func flattenImage(_ sender: Any?) { editor?.document.flatten() }

    // MARK: Layer menu

    @objc func newLayer(_ sender: Any?) { editor?.document.addEmptyLayer() }

    @objc func duplicateLayer(_ sender: Any?) {
        guard let document = editor?.document, let id = document.activeLayerID else { return }
        document.duplicateLayer(id)
    }

    @objc func deleteLayer(_ sender: Any?) {
        guard let document = editor?.document, let id = document.activeLayerID else { return }
        document.removeLayer(id)
    }

    @objc func mergeDown(_ sender: Any?) {
        guard let document = editor?.document, let id = document.activeLayerID else { return }
        document.mergeDown(id)
    }

    @objc func moveLayerUp(_ sender: Any?) {
        guard let document = editor?.document, let id = document.activeLayerID else { return }
        document.moveLayer(id, by: 1)
    }

    @objc func moveLayerDown(_ sender: Any?) {
        guard let document = editor?.document, let id = document.activeLayerID else { return }
        document.moveLayer(id, by: -1)
    }

    @objc func rasterizeLayer(_ sender: Any?) {
        guard let document = editor?.document, let id = document.activeLayerID else { return }
        document.rasterizeLayer(id)
    }

    @objc func addImageLayer(_ sender: Any?) {
        choosePictures(message: "Choose pictures to add as layers") { [weak self] urls in
            for url in urls { self?.editor?.addImageLayer(from: url) }
        }
    }

    @objc func addImageBelow(_ sender: Any?) {
        choosePictures(message: "Choose pictures to put under this one") { [weak self] urls in
            self?.editor?.appendImages(from: urls, to: .bottom)
        }
    }

    @objc func addImageToTheRight(_ sender: Any?) {
        choosePictures(message: "Choose pictures to put to the right of this one") { [weak self] urls in
            self?.editor?.appendImages(from: urls, to: .right)
        }
    }

    private func choosePictures(message: String, then use: @escaping ([URL]) -> Void) {
        guard let window, editor != nil, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = message
        panel.directoryURL = currentURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            // In the order Finder shows them, whatever order they were clicked in.
            use(panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
    }

    // MARK: Tools, adjustments and effects

    @objc func selectTool(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let kind = ToolKind(rawValue: raw) else { return }
        editor?.model.tool = kind
    }

    @objc func applyEffect(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String, let effect = EffectCatalog.find(id) else { return }
        editor?.beginEffect(effect)
    }
}
