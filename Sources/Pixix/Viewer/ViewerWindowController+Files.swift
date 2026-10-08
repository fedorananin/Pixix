import AppKit
import PixixCodec

/// What can be done to the file on screen without editing it: rename, duplicate, copy and move it,
/// and the menu that a right click brings up.
extension ViewerWindowController {
    // MARK: Context menu

    func canvas(_ canvas: CanvasView, menuAt imagePoint: CGPoint) -> NSMenu? {
        guard displayed != nil || isEditing else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if isEditing {
            add("Cut", #selector(cut(_:)))
            add("Copy", #selector(copy(_:)))
            add("Copy Merged", #selector(copyMerged(_:)))
            add("Paste", #selector(paste(_:)))
            menu.addItem(.separator())
            add("Select All", #selector(selectAll(_:)))
            add("Deselect", #selector(deselect(_:)))
            add("Invert Selection", #selector(invertSelection(_:)))
            add("Select Subject", #selector(selectSubject(_:)))
            menu.addItem(.separator())
            add("Duplicate Layer", #selector(duplicateLayer(_:)))
            add("Merge Down", #selector(mergeDown(_:)))
            add("Rasterize", #selector(rasterizeLayer(_:)))
            add("Remove Background", #selector(removeBackground(_:)))
            add("Delete Layer", #selector(deleteLayer(_:)))
        } else {
            add("Copy Image", #selector(copy(_:)))
            add("Edit Image", #selector(toggleEditing(_:)))
            menu.addItem(.separator())
            add("Rotate Left", #selector(rotateLeft(_:)))
            add("Rotate Right", #selector(rotateRight(_:)))
            menu.addItem(.separator())
            add("Show in Finder", #selector(revealInFinder(_:)))
            add("Open in New Window", #selector(openInNewWindow(_:)))
            add("Rename…", #selector(renameFile(_:)))
            add("Duplicate", #selector(duplicateFile(_:)))
            add("Copy to Folder…", #selector(copyToFolder(_:)))
            add("Move to Folder…", #selector(moveToFolder(_:)))
            menu.addItem(.separator())
            add("Export…", #selector(exportImage(_:)))
            add("Set as Wallpaper", #selector(setAsWallpaper(_:)))
            add("Share…", #selector(shareImage(_:)))
            add("Show Info", #selector(showInfo(_:)))
            menu.addItem(.separator())
            add("Move to Trash", #selector(moveToTrash(_:)))
        }
        return menu
    }

    @objc func openInNewWindow(_ sender: Any?) {
        guard let url = currentURL else { return }
        (NSApp.delegate as? AppDelegate)?.openInNewWindow(url)
    }

    // MARK: Rename

    @objc func renameFile(_ sender: Any?) {
        guard !isEditing, let url = currentURL, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        if !url.pathExtension.isEmpty {
            alert.informativeText = "The name keeps its extension, .\(url.pathExtension)."
        }
        let field = NSTextField(string: url.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(url, to: field.stringValue)
        }
    }

    /// Gives a file a new name and keeps its extension. Returns where the file is now, or nil when it stayed put.
    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = url.pathExtension
        // Typing the extension along with the name is fine too.
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
        guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/") else {
            NSSound.beep()
            return nil
        }
        var destination = url.deletingLastPathComponent().appendingPathComponent(base)
        if !ext.isEmpty { destination.appendPathExtension(ext) }
        guard destination.lastPathComponent != url.lastPathComponent else { return nil }
        let files = FileManager.default
        do {
            // On the usual Mac volume "Photo.jpg" and "photo.jpg" are one file, so a change of case goes by way
            // of a name that cannot collide.
            if destination.lastPathComponent.lowercased() == url.lastPathComponent.lowercased() {
                let stepping = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).renaming")
                try files.moveItem(at: url, to: stepping)
                try files.moveItem(at: stepping, to: destination)
            } else {
                // moveItem refuses to replace a file, which is what is wanted here.
                try files.moveItem(at: url, to: destination)
            }
        } catch {
            present(error)
            return nil
        }
        followRename(from: url, to: destination)
        NSDocumentController.shared.noteNewRecentDocumentURL(destination)
        let previous = url.deletingPathExtension().lastPathComponent
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            controller.rename(destination, to: previous)
        }
        window?.undoManager?.setActionName("Rename")
        showToast("Renamed to \(destination.lastPathComponent)")
        return destination
    }

    // MARK: Duplicate, copy, move

    @objc func duplicateFile(_ sender: Any?) {
        guard !isEditing, let url = currentURL else { return }
        let copy = FileWriter.uniqueURL(near: url, suffix: " copy")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            present(error)
            return
        }
        browser?.insert(copy, select: false)
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            do {
                try FileManager.default.trashItem(at: copy, resultingItemURL: nil)
                controller.browser?.remove(copy)
            } catch {
                controller.present(error)
            }
        }
        window?.undoManager?.setActionName("Duplicate")
        showToast("Duplicated as \(copy.lastPathComponent)")
    }

    @objc func copyToFolder(_ sender: Any?) {
        guard !isEditing, let url = currentURL else { return }
        chooseFolder(prompt: "Copy", message: "Choose a folder to copy “\(url.lastPathComponent)” to") { [weak self] folder in
            self?.transfer(url, to: folder, moving: false)
        }
    }

    @objc func moveToFolder(_ sender: Any?) {
        guard !isEditing, let url = currentURL else { return }
        chooseFolder(prompt: "Move", message: "Choose a folder to move “\(url.lastPathComponent)” to") { [weak self] folder in
            self?.transfer(url, to: folder, moving: true)
        }
    }

    private func chooseFolder(prompt: String, message: String, then act: @escaping (URL) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        // Sorting pictures means sending many of them to the same place.
        panel.directoryURL = Settings.shared.lastDestinationFolder ?? currentURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            Settings.shared.lastDestinationFolder = folder
            act(folder)
        }
    }

    /// Copies or moves a file into a folder, under a free name if its own is taken there.
    @discardableResult
    func transfer(_ url: URL, to folder: URL, moving: Bool) -> URL? {
        let files = FileManager.default
        if moving, folder.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path {
            showToast("“\(url.lastPathComponent)” is already in that folder")
            return nil
        }
        let destination = FileWriter.uniqueURL(near: folder.appendingPathComponent(url.lastPathComponent))
        do {
            if moving {
                try files.moveItem(at: url, to: destination)
            } else {
                try files.copyItem(at: url, to: destination)
            }
        } catch {
            present(error)
            return nil
        }
        let place = "“\(folder.lastPathComponent)”"
        guard moving else {
            showToast("Copied to \(place)")
            return destination
        }
        ImageLoader.shared.invalidate(url)
        browser?.remove(url)
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            do {
                try FileManager.default.moveItem(at: destination, to: url)
                controller.browser?.insert(url, select: true)
            } catch {
                controller.present(error)
            }
        }
        window?.undoManager?.setActionName("Move to Folder")
        showToast("Moved to \(place)")
        return destination
    }
}
