import AppKit
import PixixEngine

/// The menu bar, built in code because the app has no nib.
@MainActor
enum MainMenu {
    private typealias Controller = ViewerWindowController

    static func build(recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu(recentDelegate: recentDelegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(imageMenu()))
        main.addItem(submenu(layerMenu()))
        main.addItem(submenu(adjustmentsMenu()))
        main.addItem(submenu(effectsMenu()))
        main.addItem(submenu(toolsMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        help.addItem(item("Pixix on GitHub", #selector(AppDelegate.openRepository(_:))))
        help.addItem(item("Report an Issue", #selector(AppDelegate.openIssues(_:))))
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
        represented: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = represented
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Pixix")
        menu.addItem(item("About Pixix", #selector(AppDelegate.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(item("Hide Pixix", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pixix", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu(recentDelegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = recentDelegate
        menu.addItem(submenu(recent))
        menu.addItem(item("New from Clipboard", #selector(AppDelegate.newFromClipboard(_:)), "n"))
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .option]))
        // Enabled only while screenshots are switched on in Settings; the shortcut is the global one chosen there.
        let screenshot = item("Take Screenshot", #selector(CaptureAgent.takeScreenshot(_:)))
        screenshot.target = CaptureAgent.shared
        menu.addItem(screenshot)
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(Controller.saveDocument(_:)), "s"))
        menu.addItem(item("Save As…", #selector(Controller.saveDocumentAs(_:)), "s", [.command, .shift]))
        menu.addItem(item("Save as Pixix Project…", #selector(Controller.saveProjectAs(_:)), "s", [.command, .option, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Export…", #selector(Controller.exportImage(_:)), "e", [.command, .shift]))
        menu.addItem(item("Export Again", #selector(Controller.exportAgain(_:)), "e"))
        menu.addItem(.separator())
        menu.addItem(item("Show in Finder", #selector(Controller.revealInFinder(_:)), "r", [.command, .shift]))
        // F2 types nothing, so unlike a letter it is safe as a shortcut without modifiers.
        menu.addItem(item("Rename…", #selector(Controller.renameFile(_:)), String(UnicodeScalar(NSF2FunctionKey)!), []))
        menu.addItem(item("Duplicate", #selector(Controller.duplicateFile(_:)), "d", [.command, .shift]))
        menu.addItem(item("Copy to Folder…", #selector(Controller.copyToFolder(_:)), "c", [.command, .control]))
        menu.addItem(item("Move to Folder…", #selector(Controller.moveToFolder(_:)), "m", [.command, .control]))
        menu.addItem(item("Set as Wallpaper", #selector(Controller.setAsWallpaper(_:))))
        menu.addItem(item("Move to Trash", #selector(Controller.moveToTrash(_:)), "\u{8}"))
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(Controller.printImage(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", #selector(Controller.undoEdit(_:)), "z"))
        menu.addItem(item("Redo", #selector(Controller.redoEdit(_:)), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(Controller.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(Controller.copy(_:)), "c"))
        menu.addItem(item("Copy Merged", #selector(Controller.copyMerged(_:)), "c", [.command, .shift]))
        menu.addItem(item("Paste", #selector(Controller.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(Controller.deleteSelection(_:))))
        menu.addItem(item("Fill with Primary Color", #selector(Controller.fillSelection(_:)), "\u{8}", [.option]))
        menu.addItem(.separator())
        menu.addItem(item("Select All", #selector(Controller.selectAll(_:)), "a"))
        menu.addItem(item("Deselect", #selector(Controller.deselect(_:)), "d"))
        menu.addItem(item("Invert Selection", #selector(Controller.invertSelection(_:)), "i", [.command, .shift]))
        menu.addItem(item("Select Subject", #selector(Controller.selectSubject(_:)), "a", [.command, .shift]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Next Image", #selector(Controller.nextImage(_:)), "]"))
        menu.addItem(item("Previous Image", #selector(Controller.previousImage(_:)), "["))
        menu.addItem(item("First Image", #selector(Controller.firstImage(_:))))
        menu.addItem(item("Last Image", #selector(Controller.lastImage(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Zoom In", #selector(Controller.zoomIn(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(Controller.zoomOut(_:)), "-"))
        menu.addItem(item("Fit to Window", #selector(Controller.zoomToFit(_:)), "0"))
        menu.addItem(item("Actual Size", #selector(Controller.zoomActualSize(_:)), "1"))
        menu.addItem(.separator())
        menu.addItem(item("Show Info", #selector(Controller.showInfo(_:)), "i"))
        menu.addItem(item("Thumbnail Strip", #selector(Controller.toggleFilmstrip(_:)), "t", [.command, .option]))
        menu.addItem(item("Live Text", #selector(Controller.toggleLiveText(_:)), "t", [.command, .shift]))
        menu.addItem(item("Start Slideshow", #selector(Controller.toggleSlideshow(_:)), "\r", [.command, .shift]))
        menu.addItem(item("Play or Pause Animation", #selector(Controller.togglePlayback(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func imageMenu() -> NSMenu {
        let menu = NSMenu(title: "Image")
        menu.addItem(item("Edit Image", #selector(Controller.toggleEditing(_:)), "\r"))
        menu.addItem(.separator())
        menu.addItem(item("Resize…", #selector(Controller.resizeImage(_:)), "r", [.command, .option]))
        menu.addItem(item("Canvas Size…", #selector(Controller.changeCanvasSize(_:)), "c", [.command, .option]))
        menu.addItem(item("Crop to Selection", #selector(Controller.cropToSelection(_:)), "x", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Rotate Right", #selector(Controller.rotateRight(_:)), "r"))
        menu.addItem(item("Rotate Left", #selector(Controller.rotateLeft(_:)), "l"))
        menu.addItem(item("Rotate 180°", #selector(Controller.rotate180(_:))))
        menu.addItem(item("Flip Horizontal", #selector(Controller.flipHorizontal(_:))))
        menu.addItem(item("Flip Vertical", #selector(Controller.flipVertical(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Flatten", #selector(Controller.flattenImage(_:)), "f", [.command, .shift]))
        return menu
    }

    private static func layerMenu() -> NSMenu {
        let menu = NSMenu(title: "Layer")
        menu.addItem(item("New Layer", #selector(Controller.newLayer(_:)), "n", [.command, .shift]))
        menu.addItem(item("Add Image as Layer…", #selector(Controller.addImageLayer(_:)), "o", [.command, .shift]))
        menu.addItem(item("Add Image Below…", #selector(Controller.addImageBelow(_:)), "b", [.command, .option]))
        menu.addItem(item("Add Image to the Right…", #selector(Controller.addImageToTheRight(_:))))
        menu.addItem(item("Duplicate Layer", #selector(Controller.duplicateLayer(_:)), "j"))
        menu.addItem(item("Delete Layer", #selector(Controller.deleteLayer(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Move Up", #selector(Controller.moveLayerUp(_:)), "]", [.command, .option]))
        menu.addItem(item("Move Down", #selector(Controller.moveLayerDown(_:)), "[", [.command, .option]))
        menu.addItem(item("Merge Down", #selector(Controller.mergeDown(_:)), "m", [.command, .option]))
        menu.addItem(item("Rasterize", #selector(Controller.rasterizeLayer(_:))))
        menu.addItem(item("Remove Background", #selector(Controller.removeBackground(_:))))
        return menu
    }

    private static func adjustmentsMenu() -> NSMenu {
        let menu = NSMenu(title: "Adjustments")
        for effect in EffectCatalog.adjustments {
            let title = effect.parameters.isEmpty ? effect.name : effect.name + "…"
            menu.addItem(item(title, #selector(Controller.applyEffect(_:)), represented: effect.id))
        }
        return menu
    }

    private static func effectsMenu() -> NSMenu {
        let menu = NSMenu(title: "Effects")
        for group in EffectCatalog.effectGroups {
            let sub = NSMenu(title: group.category)
            for effect in group.effects {
                let title = effect.parameters.isEmpty ? effect.name : effect.name + "…"
                sub.addItem(item(title, #selector(Controller.applyEffect(_:)), represented: effect.id))
            }
            menu.addItem(submenu(sub))
        }
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: "Tools")
        for (index, group) in ToolKind.groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for tool in group {
                // The single-letter shortcuts are handled by the canvas. As real key equivalents they would
                // swallow typing in every text field, so the menu only spells them out.
                let title = tool.shortcut.map { "\(tool.title)  (\(String($0).uppercased()))" } ?? tool.title
                let entry = item(title, #selector(Controller.selectTool(_:)), represented: tool.rawValue)
                menu.addItem(entry)
            }
        }
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
