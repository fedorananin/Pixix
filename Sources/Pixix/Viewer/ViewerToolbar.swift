import AppKit

extension NSToolbarItem.Identifier {
    static let edit = NSToolbarItem.Identifier("pixix.edit")
    static let rotate = NSToolbarItem.Identifier("pixix.rotate")
    static let trash = NSToolbarItem.Identifier("pixix.trash")
    static let info = NSToolbarItem.Identifier("pixix.info")
    static let export = NSToolbarItem.Identifier("pixix.export")
    static let share = NSToolbarItem.Identifier("pixix.share")
    static let done = NSToolbarItem.Identifier("pixix.done")
    static let undo = NSToolbarItem.Identifier("pixix.undo")
    static let redo = NSToolbarItem.Identifier("pixix.redo")
    static let save = NSToolbarItem.Identifier("pixix.save")
    static let saveAs = NSToolbarItem.Identifier("pixix.saveAs")
}

extension ViewerWindowController: NSToolbarDelegate {
    func makeToolbar(identifier: String) -> NSToolbar {
        let toolbar = NSToolbar(identifier: "pixix.\(identifier)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar === editorToolbar {
            return [.done, .space, .undo, .redo, .rotate, .flexibleSpace, .save, .saveAs, .export]
        }
        return [.edit, .rotate, .trash, .flexibleSpace, .info, .export, .share]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        func item(_ label: String, _ symbol: String, _ action: Selector, tip: String? = nil) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.toolTip = tip ?? label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.isBordered = true
            item.target = self
            item.action = action
            return item
        }
        switch identifier {
        case .edit:
            return item("Edit", "slider.horizontal.3", #selector(toggleEditing(_:)), tip: "Edit Image (⌘↩)")
        case .rotate:
            return item("Rotate", "rotate.right", #selector(rotateRight(_:)), tip: "Rotate Clockwise (⌘R)")
        case .trash:
            return item("Delete", "trash", #selector(moveToTrash(_:)), tip: "Move to Trash (⌘⌫)")
        case .info:
            return item("Info", "info.circle", #selector(showInfo(_:)), tip: "Show Info (⌘I)")
        case .export:
            return item("Export", "square.and.arrow.down", #selector(exportImage(_:)), tip: "Export… (⇧⌘E)")
        case .share:
            // A plain button: the system's share toolbar item enumerates sharing services at launch, which is slow.
            return item("Share", "square.and.arrow.up", #selector(shareImage(_:)), tip: "Share")
        case .done:
            let done = item("Done", "checkmark", #selector(toggleEditing(_:)), tip: "Finish Editing (⌘↩)")
            done.title = "Done"
            return done
        case .undo:
            return item("Undo", "arrow.uturn.backward", #selector(undoEdit(_:)), tip: "Undo (⌘Z)")
        case .redo:
            return item("Redo", "arrow.uturn.forward", #selector(redoEdit(_:)), tip: "Redo (⇧⌘Z)")
        case .save:
            return item("Save", "square.and.arrow.down.on.square", #selector(saveDocument(_:)), tip: "Save (⌘S)")
        case .saveAs:
            return item("Save As", "doc.badge.plus", #selector(saveDocumentAs(_:)), tip: "Save As… (⇧⌘S)")
        default:
            return nil
        }
    }

    func toolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        window?.toolbar?.items.first { $0.itemIdentifier == identifier && $0.isVisible }
    }
}
