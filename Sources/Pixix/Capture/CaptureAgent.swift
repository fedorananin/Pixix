import AppKit

/// The part of Pixix that takes screenshots. While it runs, the app holds a global shortcut and an icon in
/// the menu bar, and stays alive without a Dock icon when its windows are closed. It is off unless the user
/// turns it on in Settings, and nothing here is touched on the way to showing a picture.
@MainActor
final class CaptureAgent: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = CaptureAgent()

    private(set) var isRunning = false
    private(set) var session: CaptureSession?
    /// False when macOS refused the shortcut, which usually means another app holds it.
    private(set) var hotKeyIsClaimed = false
    /// True for a run made from a terminal to measure or photograph the app. Such a run must put nothing on the
    /// screen, so the agent refuses to start, to capture and to ask macOS for anything, whoever calls it.
    var isUnattended = false
    private var announcesResults = true
    var announces: Bool { announcesResults && !isUnattended }

    private lazy var hotKey = GlobalHotKey { [weak self] in self?.takeScreenshot(nil) }
    private var statusItem: NSStatusItem?
    private var closeObserver: NSObjectProtocol?
    private var isGrabbing = false
    private var previousApp: NSRunningApplication?

    // MARK: Running

    func start() {
        guard !isRunning, !isUnattended else { return }
        isRunning = true
        installStatusItem()
        applyHotKey()
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
        hotKey.unregister()
        hotKeyIsClaimed = false
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    /// Claims the shortcut chosen in Settings.
    func applyHotKey() {
        guard isRunning else { return }
        if let combo = Settings.shared.captureHotKey {
            hotKeyIsClaimed = hotKey.register(combo)
        } else {
            hotKey.unregister()
            hotKeyIsClaimed = false
        }
    }

    /// Lets go of the shortcut while a new one is being typed in Settings, so typing the old one records it.
    func suspendHotKey() {
        hotKey.unregister()
    }

    // MARK: Dock

    /// Shows Pixix in the Dock while it has a window, and takes it out when the last one is gone.
    func updateDockPresence() {
        guard isRunning, session == nil else { return }
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
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Pixix Screenshot")
        item.button?.toolTip = "Pixix"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let take = NSMenuItem(title: "Take Screenshot", action: #selector(takeScreenshot(_:)), keyEquivalent: "")
        take.target = self
        if hotKeyIsClaimed, let combo = Settings.shared.captureHotKey {
            take.keyEquivalent = combo.menuKeyEquivalent
            take.keyEquivalentModifierMask = combo.flags
        }
        menu.addItem(take)
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
        isRunning && session == nil
    }

    // MARK: Capturing

    @objc func takeScreenshot(_ sender: Any?) {
        guard isRunning, !isGrabbing else { return }
        if let session {
            // Pressed again with a capture already up: bring it back in case it got lost behind something.
            session.setHidden(false)
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
                beginSession(shots: shots)
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
        if unattended { announcesResults = false }
        let session = CaptureSession(shots: shots, isUnattended: unattended)
        session.onEnd = { [weak self] returningFocus in
            guard let self else { return }
            self.session = nil
            if returningFocus { self.previousApp?.activate() }
            self.previousApp = nil
            self.updateDockPresence()
        }
        self.session = session
        session.begin()
        return session
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
