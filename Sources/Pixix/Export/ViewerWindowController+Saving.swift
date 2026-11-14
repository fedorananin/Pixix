import AppKit
import PixixCodec
import PixixEngine
import SwiftUI
import UniformTypeIdentifiers

extension ViewerWindowController {
    private struct PreparedSource {
        var source: ExportSource
        var originalBytes: Int?
        var baseURL: URL
        /// False for a pasted picture or a screenshot: there is no file to save next to.
        var hasFile = true
        /// In the editor: the state of the history when the picture was taken, and the size of the document.
        var marker: History.SaveMarker?
        var documentSize: CGSize?
    }

    /// Everything an export needs: full-resolution pixels (or all frames) and the original metadata.
    private func prepareSource() async throws -> PreparedSource {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let editor {
            // What is saved is what is on screen: a crop frame left unapplied is applied first.
            editor.commitPendingEdits()
            let file = editor.fileURL ?? currentURL
            return PreparedSource(
                source: .image(editor.flattenedImage(), properties: editor.sourceProperties),
                originalBytes: nil, baseURL: file ?? pictures.appendingPathComponent("Untitled.png"),
                hasFile: file != nil, marker: editor.document.history.saveMarker(), documentSize: editor.document.size
            )
        }
        guard let url = currentURL else { throw CodecError.cannotDecode }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if displayed?.loaded.info.isAnimated == true {
            let (frames, properties) = try await Task.detached(priority: .userInitiated) {
                let source = try ImageSource(url: url)
                return (try source.allFrames(), UncheckedBox(source.properties()))
            }.value
            return PreparedSource(source: .frames(frames, properties: properties.value), originalBytes: bytes, baseURL: url)
        }
        let full = try await fullImage(of: url)
        let properties = (try? ImageSource(url: url))?.properties()
        return PreparedSource(source: .image(full.image, properties: properties), originalBytes: bytes, baseURL: url)
    }

    @objc func exportImage(_ sender: Any?) {
        var initial = Settings.shared.lastExport ?? ExportSettings()
        if Settings.shared.lastExport == nil { initial.quality = 0.85 }
        presentExportDialog(title: "Export", confirmTitle: "Export", initial: initial, isSaveAs: false)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        saveDocumentAs(then: nil)
    }

    /// Save As. `completion` learns whether the edits are now safely in a file, so that closing can go on.
    func saveDocumentAs(then completion: ((Bool) -> Void)?) {
        var initial = ExportSettings()
        let url = editor?.fileURL ?? currentURL
        initial.format = url.flatMap { ImageFormat(url: $0) } ?? .png
        initial.quality = 0.92
        presentExportDialog(
            title: "Save As", confirmTitle: "Save Copy", initial: initial, isSaveAs: true, completion: completion
        )
    }

    private func presentExportDialog(
        title: String, confirmTitle: String, initial: ExportSettings, isSaveAs: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let window, window.attachedSheet == nil else {
            completion?(false)
            return
        }
        Task { [weak self, weak window] in
            guard let self, let window else { return }
            do {
                let prepared = try await self.prepareSource()
                let model = ExportModel(
                    title: title, confirmTitle: confirmTitle, source: prepared.source, initial: initial,
                    originalBytes: prepared.originalBytes
                )
                model.needsLocation = !prepared.hasFile
                let sheet = NSWindow(
                    contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
                )
                sheet.isReleasedWhenClosed = false
                let view = ExportView(
                    model: model,
                    onCancel: { [weak window, weak sheet] in
                        if let sheet { window?.endSheet(sheet) }
                        completion?(false)
                    },
                    onConfirm: { [weak self, weak sheet] choosing in
                        guard let self, let sheet else { return }
                        // A number typed into a field reaches the model only once the field lets go of the keyboard.
                        sheet.makeFirstResponder(nil)
                        self.finishExport(
                            model: model, sheet: sheet, prepared: prepared, choosingLocation: choosing || model.needsLocation,
                            isSaveAs: isSaveAs, completion: completion
                        )
                    }
                )
                sheet.contentViewController = NSHostingController(rootView: view)
                window.beginSheet(sheet, completionHandler: nil)
            } catch {
                self.present(error)
                completion?(false)
            }
        }
    }

    private func finishExport(
        model: ExportModel, sheet: NSWindow, prepared: PreparedSource, choosingLocation: Bool, isSaveAs: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard let window else { return }
        let baseURL = prepared.baseURL
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await model.encode()
                let ext = model.format.fileExtension
                let destination: URL
                if choosingLocation {
                    let panel = NSSavePanel()
                    panel.directoryURL = baseURL.deletingLastPathComponent()
                    panel.nameFieldStringValue = baseURL.deletingPathExtension().lastPathComponent + "." + ext
                    if let type = UTType(model.format.typeIdentifier) { panel.allowedContentTypes = [type] }
                    panel.canCreateDirectories = true
                    // On the dialog itself: cancelling the panel goes back to the settings instead of losing them.
                    guard await panel.beginSheetModal(for: sheet) == .OK, let chosen = panel.url else { return }
                    destination = chosen
                } else {
                    destination = FileWriter.uniqueURL(near: baseURL, fileExtension: ext)
                }
                try FileWriter.write(result.data, to: destination)
                window.endSheet(sheet)
                Settings.shared.lastExport = model.settings
                let adopted = self.didWrite(
                    result, to: destination, adoptAsDocument: isSaveAs, marker: prepared.marker,
                    documentSize: prepared.documentSize
                )
                completion?(adopted)
            } catch {
                // The dialog stays, with its settings, under the error.
                NSAlert(error: error).beginSheetModal(for: sheet, completionHandler: nil)
            }
        }
    }

    /// Repeats the last export without asking anything.
    @objc func exportAgain(_ sender: Any?) {
        guard let settings = Settings.shared.lastExport else {
            exportImage(sender)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.prepareSource()
                let result = try await Task.detached(priority: .userInitiated) {
                    try ImageEncoder.export(prepared.source, settings: settings)
                }.value
                let destination = FileWriter.uniqueURL(near: prepared.baseURL, fileExtension: settings.format.fileExtension)
                try FileWriter.write(result.data, to: destination)
                self.didWrite(result, to: destination, adoptAsDocument: false, marker: nil, documentSize: nil)
            } catch {
                self.present(error)
            }
        }
    }

    /// Overwrites the file being edited, in its own format.
    @objc func saveDocument(_ sender: Any?) {
        guard let editor else { return }
        // What is saved is what is on screen: a crop frame left unapplied is applied first.
        editor.commitPendingEdits()
        guard let url = editor.fileURL else {
            // Nothing sensible to overwrite: an animation, a pasted image, or a format we cannot write.
            saveDocumentAs(sender)
            return
        }
        if url.pathExtension.lowercased() == ProjectFile.fileExtension {
            do {
                try editor.saveProject(to: url)
                editor.markSaved(url: url)
                showToast("Saved \(url.lastPathComponent)")
            } catch {
                present(error)
            }
            return
        }
        guard let format = ImageFormat(url: url) else {
            saveDocumentAs(sender)
            return
        }
        let image = editor.flattenedImage()
        // What the file will hold is the state now; a change made while it is being written stays unsaved.
        let marker = editor.document.history.saveMarker()
        let properties = UncheckedBox(editor.sourceProperties)
        Task { [weak self] in
            guard let self else { return }
            do {
                var settings = ExportSettings()
                settings.format = format
                settings.quality = 0.92
                let result = try await Task.detached(priority: .userInitiated) {
                    try ImageEncoder.export(.image(image, properties: properties.value), settings: settings)
                }.value
                // The first Save of a session is the one that destroys something: the file as it was.
                let keepsOriginal = Settings.shared.keepsOriginalInTrash && self.editor?.fileIsUntouched == true
                let trashed = try FileWriter.replace(url, with: result.data, trashingOriginal: keepsOriginal)
                ImageLoader.shared.invalidate(url)
                self.editor?.markSaved(url: url, marker: marker)
                let note = trashed != nil ? " · the original is in the Trash" : ""
                self.showToast("Saved \(url.lastPathComponent) · \(Self.byteText(result.data.count))\(note)")
                self.updateTitle()
            } catch {
                self.present(error)
            }
        }
    }

    @objc func saveProjectAs(_ sender: Any?) {
        guard let editor, let window else { return }
        editor.commitPendingEdits()
        let base = editor.fileURL ?? currentURL
        let panel = NSSavePanel()
        panel.directoryURL = base?.deletingLastPathComponent()
        panel.nameFieldStringValue = (base?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + ProjectFile.fileExtension
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self, let editor = self.editor else { return }
            do {
                try editor.saveProject(to: url)
                editor.markSaved(url: url)
                self.showToast("Saved \(url.lastPathComponent)")
                self.updateTitle()
            } catch {
                self.present(error)
            }
        }
    }

    /// Returns true when the editor now works on the written file. Save As switches to it only when the file holds
    /// the document as it is: a copy made smaller is an export, and the full-size edit stays unsaved.
    @discardableResult
    private func didWrite(
        _ result: ExportResult, to destination: URL, adoptAsDocument: Bool, marker: History.SaveMarker?,
        documentSize: CGSize?
    ) -> Bool {
        ImageLoader.shared.invalidate(destination)
        var adopted = false
        if adoptAsDocument, let editor {
            if let documentSize, result.width == Int(documentSize.width), result.height == Int(documentSize.height) {
                // After Save As the editor works on the new file, like any document app.
                editor.markSaved(url: destination, marker: marker)
                browser?.insert(destination, select: true)
                updateTitle()
                adopted = true
            }
        }
        var text = "Saved \(destination.lastPathComponent) · \(result.width) × \(result.height) · \(Self.byteText(result.data.count))"
        if adoptAsDocument, editor != nil, !adopted { text += " · a resized copy, the edit itself is not saved" }
        showToast(text)
        return adopted
    }

    static func byteText(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// A short confirmation that fades by itself.
    func showToast(_ text: String) {
        guard let content = window?.contentView else { return }
        content.subviews.filter { $0.identifier == Self.toastIdentifier }.forEach { $0.removeFromSuperview() }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.identifier = Self.toastIdentifier
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        pill.layer?.cornerRadius = 15
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        content.addSubview(pill)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 30),
            pill.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            pill.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 14),
            pill.widthAnchor.constraint(lessThanOrEqualTo: canvas.widthAnchor, constant: -40),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak pill] in
            guard let pill else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                pill.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { pill.removeFromSuperview() }
            })
        }
    }

    private static let toastIdentifier = NSUserInterfaceItemIdentifier("pixix.toast")
}

/// Carries a non-Sendable value across a task boundary when the code guarantees exclusive use.
struct UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
