import AppKit

/// The part of Pixix that takes screenshots and picks colors from the screen. While it runs, the app holds a
/// global shortcut for each of the two that is switched on and an icon in the menu bar, and stays alive without
/// a Dock icon when its windows are closed. It is off unless the user turns one of them on in Settings, and
/// nothing here is touched on the way to showing a picture.
@MainActor
final class CaptureAgent: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = CaptureAgent()

    private(set) var isRunning = false
    private(set) var session: CaptureSession?
    private(set) var picker: PickerSession?
    /// False when macOS refused the shortcut, which usually means another app holds it.
    private(set) var screenshotKeyIsClaimed = false
    private(set) var pickerKeyIsClaimed = false
    /// True for a run made from a terminal to measure or photograph the app. Such a run must put nothing on the
    /// screen, so the agent refuses to start, to capture and to ask macOS for anything, whoever calls it.
    var isUnattended = false
    private var announcesResults = true
    var announces: Bool { announcesResults && !isUnattended }

    private lazy var screenshotKey = GlobalHotKey(id: 1) { [weak self] in self?.takeScreenshot(nil) }
    private lazy var pickerKey = GlobalHotKey(id: 2) { [weak self] in self?.pickColor(nil) }
    /// True while an overlay covers the screen, whichever of the two it is.
    private var isBusy: Bool { session != nil || picker != nil }
    private var statusItem: NSStatusItem?
    private var closeObserver: NSObjectProtocol?
    private var isGrabbing = false
    private var previousApp: NSRunningApplication?

    // MARK: Running

    /// Starts, stops or changes what is claimed, to match what Settings asks for now.
    func refresh() {
        let settings = Settings.shared
        guard settings.staysInMenuBar else { return stop() }
        if !settings.capturesScreenshots { session?.end() }
        if !settings.picksColors { picker?.end() }
        if isRunning {
            applyHotKeys()
            updateStatusIcon()
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning, !isUnattended else { return }
        isRunning = true
        installStatusItem()
        applyHotKeys()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            // The window still counts as open while it is closing; look again once it is gone.
            Task { @MainActor in CaptureAgent.shared.updateDockPresence() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        session?.end()
        picker?.end()
        suspendHotKeys()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    /// Claims the shortcuts chosen in Settings, for what is switched on.
    func applyHotKeys() {
        guard isRunning else { return }
        let settings = Settings.shared
        let screenshot = settings.capturesScreenshots ? settings.captureHotKey : nil
        var color = settings.picksColors ? settings.pickerHotKey : nil
        // One press cannot start two things; the screenshot keeps it, and Settings says so.
        if let screenshot, color?.isSamePress(as: screenshot) == true { color = nil }
        screenshotKeyIsClaimed = claim(screenshotKey, screenshot)
        pickerKeyIsClaimed = claim(pickerKey, color)
    }

    private func claim(_ key: GlobalHotKey, _ combo: KeyCombo?) -> Bool {
        guard let combo else {
            key.unregister()
            return false
        }
        return key.register(combo)
    }

    /// Lets go of the shortcuts while a new one is being typed in Settings, so typing an old one records it.
    func suspendHotKeys() {
        screenshotKey.unregister()
        pickerKey.unregister()
        screenshotKeyIsClaimed = false
        pickerKeyIsClaimed = false
    }

    // MARK: Dock

    /// Shows Pixix in the Dock while it has a window, and takes it out when the last one is gone.
    func updateDockPresence() {
        guard isRunning, !isBusy else { return }
        let hasWindows = NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }
        let wanted: NSApplication.ActivationPolicy = hasWindows ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    /// Called before a window opens: an app that lives in the menu bar alone has no Dock icon and no menus.
    func showInDock() {
        guard isRunning, NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // The menu bar of an app that has just come back to the Dock belongs to it only after it is activated again.
        DispatchQueue.main.async { NSApp.activate() }
    }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "Pixix"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    /// The camera while Pixix takes screenshots; the pipette when colors are all it is there for.
    private func updateStatusIcon() {
        let name = Settings.shared.capturesScreenshots ? "camera.viewfinder" : "eyedropper"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Pixix")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, _ combo: KeyCombo?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let combo {
                item.keyEquivalent = combo.menuKeyEquivalent
                item.keyEquivalentModifierMask = combo.flags
            }
            menu.addItem(item)
        }
        let settings = Settings.shared
        if settings.capturesScreenshots {
            add("Take Screenshot", #selector(takeScreenshot(_:)), screenshotKeyIsClaimed ? settings.captureHotKey : nil)
        }
        if settings.picksColors {
            add("Pick Color", #selector(pickColor(_:)), pickerKeyIsClaimed ? settings.pickerHotKey : nil)
        }
        menu.addItem(.separator())
        for (title, action) in [("Open…", #selector(AppDelegate.openDocument(_:))), ("Settings…", #selector(AppDelegate.showSettings(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = NSApp.delegate
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pixix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard isRunning, !isBusy else { return false }
        switch menuItem.action {
        case #selector(takeScreenshot(_:)): return Settings.shared.capturesScreenshots
        case #selector(pickColor(_:)): return Settings.shared.picksColors
        default: return true
        }
    }

    // MARK: Capturing

    @objc func takeScreenshot(_ sender: Any?) {
        guard Settings.shared.capturesScreenshots else { return }
        freezeScreen(sender) { [weak self] in self?.beginSession(shots: $0) }
    }

    @objc func pickColor(_ sender: Any?) {
        guard Settings.shared.picksColors else { return }
        freezeScreen(sender) { [weak self] in self?.beginPicking(shots: $0) }
    }

    /// Picks again for the color window, which gets the result whatever a click is set to do.
    func pickColorForWindow() {
        freezeScreen(nil) { [weak self] in self?.beginPicking(shots: $0).forcedAction = .window }
    }

    /// Takes a picture of every display and hands them to whatever is going to cover the screen with them.
    private func freezeScreen(_ sender: Any?, then begin: @escaping @MainActor ([ScreenShot]) -> Void) {
        guard isRunning, !isGrabbing else { return }
        if isBusy {
            // Pressed with an overlay already up: bring it back in case it got lost behind something.
            session?.setHidden(false)
            picker?.bringForward()
            return
        }
        guard ScreenGrabber.hasAccess else {
            askForAccess()
            return
        }
        isGrabbing = true
        let front = NSWorkspace.shared.frontmostApplication
        // A menu takes a moment to fade; without the wait it would be in the picture.
        let delay: TimeInterval = sender is NSMenuItem ? 0.3 : 0
        Task {
            defer { isGrabbing = false }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                let shots = try await ScreenGrabber.grab()
                guard isRunning, !shots.isEmpty else { return }
                previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
                begin(shots)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "The screen could not be captured"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    /// Starts a session on pictures that are already taken. A scripted run passes a picture from a file,
    /// so it needs no permission and shows nothing.
    @discardableResult
    func beginSession(shots: [ScreenShot], unattended: Bool = false) -> CaptureSession {
        session?.end()
        picker?.end()
        if unattended { announcesResults = false }
        let session = CaptureSession(shots: shots, isUnattended: unattended)
        session.onEnd = { [weak self] returningFocus in
            self?.session = nil
            self?.overlayDidEnd(returningFocus: returningFocus)
        }
        self.session = session
        session.begin()
        return session
    }

    /// Starts picking a color on pictures that are already taken, as `beginSession` starts a screenshot.
    @discardableResult
    func beginPicking(shots: [ScreenShot], unattended: Bool = false) -> PickerSession {
        session?.end()
        picker?.end()
        if unattended { announcesResults = false }
        let picker = PickerSession(shots: shots, isUnattended: unattended)
        picker.onEnd = { [weak self] returningFocus in
            self?.picker = nil
            self?.overlayDidEnd(returningFocus: returningFocus)
        }
        self.picker = picker
        picker.begin()
        return picker
    }

    private func overlayDidEnd(returningFocus: Bool) {
        if returningFocus { previousApp?.activate() }
        previousApp = nil
        updateDockPresence()
    }

    /// macOS asks for the permission by itself, once. After that only System Settings can grant it.
    func askForAccess() {
        guard !isUnattended else { return }
        let askedBefore = Settings.shared.didAskForScreenAccess
        Settings.shared.didAskForScreenAccess = true
        // The first time this brings up the dialog of macOS, and that is all there is to do.
        if ScreenGrabber.requestAccess() || !askedBefore { return }
        let alert = NSAlert()
        alert.messageText = "Pixix needs permission to see the screen"
        alert.informativeText = "Allow Pixix under Privacy & Security › Screen & System Audio Recording in System Settings, then quit Pixix and open it again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(ScreenGrabber.settingsURL) }
    }
}
