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
    }

    /// Everything an export needs: full-resolution pixels (or all frames) and the original metadata.
    private func prepareSource() async throws -> PreparedSource {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if let editor {
            let base = editor.fileURL ?? currentURL ?? pictures.appendingPathComponent("Untitled.png")
            return PreparedSource(
                source: .image(editor.flattenedImage(), properties: editor.sourceProperties),
                originalBytes: nil, baseURL: base
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
        let full = try await ImageLoader.shared.load(url, maxPixel: nil)
        let properties = (try? ImageSource(url: url))?.properties()
        return PreparedSource(source: .image(full.image, properties: properties), originalBytes: bytes, baseURL: url)
    }

    @objc func exportImage(_ sender: Any?) {
        var initial = Settings.shared.lastExport ?? ExportSettings()
        if Settings.shared.lastExport == nil { initial.quality = 0.85 }
        presentExportDialog(title: "Export", confirmTitle: "Export", initial: initial, isSaveAs: false)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        var initial = ExportSettings()
        let url = editor?.fileURL ?? currentURL
        initial.format = url.flatMap { ImageFormat(url: $0) } ?? .png
        initial.quality = 0.92
        presentExportDialog(title: "Save As", confirmTitle: "Save Copy", initial: initial, isSaveAs: true)
    }

    private func presentExportDialog(title: String, confirmTitle: String, initial: ExportSettings, isSaveAs: Bool) {
        guard let window, window.attachedSheet == nil else { return }
        Task { [weak self, weak window] in
            guard let self, let window else { return }
            do {
                let prepared = try await self.prepareSource()
                let model = ExportModel(
                    title: title, confirmTitle: confirmTitle, source: prepared.source, initial: initial,
                    originalBytes: prepared.originalBytes
                )
                let sheet = NSWindow(
                    contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
                )
                sheet.isReleasedWhenClosed = false
                let view = ExportView(
                    model: model,
                    onCancel: { [weak window, weak sheet] in
                        if let sheet { window?.endSheet(sheet) }
                    },
                    onConfirm: { [weak self, weak sheet] choosing in
                        guard let self, let sheet else { return }
                        self.finishExport(
                            model: model, sheet: sheet, baseURL: prepared.baseURL, choosingLocation: choosing,
                            isSaveAs: isSaveAs
                        )
                    }
                )
                sheet.contentViewController = NSHostingController(rootView: view)
                window.beginSheet(sheet, completionHandler: nil)
            } catch {
                self.present(error)
            }
        }
    }

    private func finishExport(model: ExportModel, sheet: NSWindow, baseURL: URL, choosingLocation: Bool, isSaveAs: Bool) {
        guard let window else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await model.encode()
                let ext = model.format.fileExtension
                window.endSheet(sheet)
                let destination: URL
                if choosingLocation {
                    let panel = NSSavePanel()
                    panel.directoryURL = baseURL.deletingLastPathComponent()
                    panel.nameFieldStringValue = baseURL.deletingPathExtension().lastPathComponent + "." + ext
                    if let type = UTType(model.format.typeIdentifier) { panel.allowedContentTypes = [type] }
                    panel.canCreateDirectories = true
                    guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { return }
                    destination = chosen
                } else {
                    destination = FileWriter.uniqueURL(near: baseURL, fileExtension: ext)
                }
                try FileWriter.write(result.data, to: destination)
                Settings.shared.lastExport = model.settings
                self.didWrite(result, to: destination, adoptAsDocument: isSaveAs)
            } catch {
                self.present(error)
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
                self.didWrite(result, to: destination, adoptAsDocument: false)
            } catch {
                self.present(error)
            }
        }
    }

    /// Overwrites the file being edited, in its own format.
    @objc func saveDocument(_ sender: Any?) {
        guard let editor else { return }
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
                try FileWriter.write(result.data, to: url)
                ImageLoader.shared.invalidate(url)
                self.editor?.markSaved(url: url)
                self.showToast("Saved \(url.lastPathComponent) · \(Self.byteText(result.data.count))")
                self.updateTitle()
            } catch {
                self.present(error)
            }
        }
    }

    @objc func saveProjectAs(_ sender: Any?) {
        guard let editor, let window else { return }
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

    private func didWrite(_ result: ExportResult, to destination: URL, adoptAsDocument: Bool) {
        ImageLoader.shared.invalidate(destination)
        if adoptAsDocument, let editor {
            // After Save As the editor works on the new file, like any document app.
            editor.markSaved(url: destination)
            browser?.insert(destination, select: true)
            updateTitle()
        }
        showToast("Saved \(destination.lastPathComponent) · \(result.width) × \(result.height) · \(Self.byteText(result.data.count))")
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
