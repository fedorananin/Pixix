import AppKit
import PixixCodec
import PixixEngine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controllers: [ViewerWindowController] = []
    private var settingsWindow: NSWindow?
    private var didOpenFiles = false
    private var didPlanSnapshot = false
    private let launchOptions = LaunchOptions()

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        trace("will finish launching")
        // Start decoding before any interface exists; the window is ready by the time the pixels are.
        prefetch(launchOptions.files)
        NSApp.mainMenu = MainMenu.build(recentDelegate: self)
        trace("menu built")
    }

    /// Kicks off the decode of the first picture. A window-sized preview decodes several times faster
    /// than the full image, and the full image follows as soon as the preview is up.
    private func prefetch(_ urls: [URL]) {
        guard let first = urls.first, ReadableTypes.isReadable(first) else { return }
        ImageLoader.shared.prefetch([first], maxPixel: 2400)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        trace("did finish launching")
        if let action = launchOptions.defaultsAction {
            // A maintenance run from the terminal or the install script: do the job, report, leave.
            Task {
                let message = action == .register ? await DefaultViewer.register().summary : await DefaultViewer.restore()
                // Written directly: buffered output can be lost when the app terminates.
                FileHandle.standardOutput.write(Data((message + "\n").utf8))
                NSApp.terminate(nil)
            }
            return
        }
        if !launchOptions.files.isEmpty {
            open(launchOptions.files)
        }
        // Files from Finder arrive through `application(_:open:)`, possibly a moment after launch.
        DispatchQueue.main.async { [self] in
            if controllers.isEmpty, !didOpenFiles { present(makeController()) }
            // A diagnostic run must not take the keyboard away from whoever is at the machine.
            if !launchOptions.isUnattended { NSApp.activate() }
        }
    }

    /// The point of the whole app: closing the last window removes it from the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting with unsaved edits asks about each of them; the app then quits once its windows are gone.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nobody is there to answer in a diagnostic run, and its edits are throwaway.
        if launchOptions.isUnattended { return .terminateNow }
        let unsaved = controllers.filter { $0.editor?.isDirty == true }
        guard !unsaved.isEmpty else { return .terminateNow }
        for controller in controllers where controller.editor?.isDirty != true {
            controller.window?.close()
        }
        for controller in unsaved {
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.performClose(nil)
        }
        return .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    // MARK: Windows

    private func makeController() -> ViewerWindowController {
        let controller = ViewerWindowController()
        if launchOptions.isUnattended, let window = controller.window {
            // A diagnostic run draws its window where no screen is: nothing appears in front of the person at the
            // machine, and nothing can be clicked by accident. The place must not be remembered for real launches.
            window.setFrameAutosaveName("")
            window.setFrameOrigin(Self.offscreen)
            // macOS keeps a corner of every window on a screen, so that corner is made invisible and untouchable.
            // A snapshot draws the views themselves and is not affected.
            window.alphaValue = 0
            window.hasShadow = false
            window.ignoresMouseEvents = true
        } else if let neighbor = controllers.last?.window, let window = controller.window {
            // Another window opens a step down and to the right of the newest one, not exactly on top of it.
            window.setFrame(neighbor.frame, display: false)
            _ = window.cascadeTopLeft(from: neighbor.cascadeTopLeft(from: .zero))
        }
        controllers.append(controller)
        return controller
    }

    private static let offscreen = NSPoint(x: -30000, y: -30000)

    /// Puts a window on screen, or for a diagnostic run brings it to life out of sight.
    private func present(_ controller: ViewerWindowController) {
        guard launchOptions.isUnattended, let window = controller.window else {
            controller.showWindow(nil)
            return
        }
        window.orderBack(nil)
        // Showing a window may pull it back onto a screen.
        window.setFrameOrigin(Self.offscreen)
    }

    /// The window that should show these files.
    private func controller(for urls: [URL]) -> ViewerWindowController {
        // A window with nothing in it is there to be filled.
        if let empty = controllers.first(where: { !$0.isEditing && $0.currentURL == nil }) { return empty }
        // Opening what is already on screen brings that window forward.
        if urls.count == 1, let showing = controllers.first(where: { !$0.isEditing && $0.currentURL == urls[0] }) {
            return showing
        }
        // Never pull the rug from under an editing session.
        if !Settings.shared.opensNewWindows, let viewing = controllers.first(where: { !$0.isEditing }) { return viewing }
        return makeController()
    }

    func controllerDidClose(_ controller: ViewerWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        didOpenFiles = true
        trace("open \(urls.count) file(s)")
        prefetch(urls)
        let controller = controller(for: urls)
        // Only the first window of a run is photographed; a scenario may open more.
        if let snapshot = launchOptions.snapshotURL, controller.onFirstImage == nil, !didPlanSnapshot {
            didPlanSnapshot = true
            controller.onFirstImage = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.launchOptions.reportFirstFrame()
                self.takeSnapshot(of: controller, to: snapshot)
            }
        } else if launchOptions.reportsTiming || launchOptions.closesAfterFirstFrame {
            controller.onFirstImage = { [weak self, weak controller] in
                self?.launchOptions.reportFirstFrame()
                if self?.launchOptions.quitsAfterFirstFrame == true { NSApp.terminate(nil) }
                // Closing the window, not quitting: the process must then end by itself.
                if self?.launchOptions.closesAfterFirstFrame == true { controller?.window?.performClose(nil) }
            }
        }
        trace("window ready")
        controller.open(urls)
        present(controller)
        trace("window shown at \(Int(controller.window?.frame.minX ?? 0)),\(Int(controller.window?.frame.minY ?? 0))\(controller.window?.screen == nil ? ", off screen" : "")")
    }

    /// Shows a file in a window of its own, next to whatever else is open, whatever Settings says.
    func openInNewWindow(_ url: URL) {
        let controller = makeController()
        controller.open([url])
        present(controller)
    }

    @objc func newWindow(_ sender: Any?) {
        let front = controllers.first { $0.window?.isKeyWindow == true } ?? controllers.last
        if let url = front?.currentURL {
            // A second look at the same picture, to compare it with another or with an edit in progress.
            openInNewWindow(url)
        } else {
            present(makeController())
        }
    }

    func newWindow(pasting image: CGImage) {
        let controller = controllers.first { !$0.isEditing && $0.currentURL == nil } ?? makeController()
        present(controller)
        controller.openPastedImage(image)
    }

    // MARK: Menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, ProjectFile.contentType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func newFromClipboard(_ sender: Any?) {
        guard let image = NSImage(pasteboard: .general)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSSound.beep()
            return
        }
        newWindow(pasting: image)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open([url])
    }

    @objc func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = NSDocumentController.shared.recentDocumentURLs
        for url in recent.prefix(12) {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path(percentEncoded: false)
            menu.addItem(item)
        }
        if !recent.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: recent.isEmpty ? nil : #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    static let repositoryURL = URL(string: "https://github.com/fedorananin/Pixix")!

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Made by Fedor Ananin.\nOpen source under the MIT License.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(
            string: "github.com/fedorananin/Pixix",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: Self.repositoryURL]
        ))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    @objc func openRepository(_ sender: Any?) {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    @objc func openIssues(_ sender: Any?) {
        NSWorkspace.shared.open(Self.repositoryURL.appendingPathComponent("issues"))
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Pixix Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(model: SettingsModel()))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Re-sorts every open folder after the sort order changed in Settings.
    func sortOrderDidChange() {
        for controller in controllers { controller.browser?.rescan() }
    }

    // MARK: Diagnostics

    /// Ends a snapshot run at once. An ordinary quit waits for an open sheet or popover to be dealt with,
    /// and in a run nobody is watching that wait would never end.
    private static func leaveAfterSnapshot() -> Never {
        exit(0)
    }

    /// Writes what the window shows to a PNG and quits. Used to check the interface without a person looking.
    private func takeSnapshot(of controller: ViewerWindowController, to url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + launchOptions.snapshotDelay) { [self] in
            if launchOptions.startsEditing, !controller.isEditing {
                controller.beginEditing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                    let finish: @MainActor () -> Void = {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            controller.writeSnapshot(to: url)
                            Self.leaveAfterSnapshot()
                        }
                    }
                    if let script = launchOptions.script { script(controller, finish) } else { finish() }
                }
                return
            }
            let finish: @MainActor () -> Void = {
                controller.writeSnapshot(to: url)
                Self.leaveAfterSnapshot()
            }
            if !launchOptions.startsEditing, let script = launchOptions.script { script(controller, finish) } else { finish() }
        }
    }
}

/// Command-line switches for running the app from a terminal.
///
///     Pixix --version                      print the version and exit
///     Pixix photo.jpg                      open a file
///     Pixix --make-default                 open every supported file type with Pixix from now on
///     Pixix --restore-default              give those types back; macOS asks to confirm each one
///     Pixix --timing --quit photo.jpg      print milliseconds to first frame and exit
///     Pixix --close photo.jpg              close the window once the picture is up; the app must exit by itself
///     Pixix --snapshot out.png photo.jpg   save a picture of the window and exit
///     Pixix --snapshot out.png --edit --demo meme photo.jpg   the same, in the editor, after a scripted scenario
///     Pixix --snapshot out.png --demo mouse photo.jpg         the viewer after a scripted scenario
///                                          (the scenarios are listed in Diagnostics.swift)
@MainActor
final class LaunchOptions {
    var files: [URL] = []
    var snapshotURL: URL?
    var snapshotDelay: TimeInterval = 0.6
    var startsEditing = false
    var reportsTiming = false
    var quitsAfterFirstFrame = false
    var closesAfterFirstFrame = false
    enum DefaultsAction { case register, restore }
    var defaultsAction: DefaultsAction?
    /// A scripted scenario. It calls the closure it is given once the window is ready to be photographed.
    var script: ((ViewerWindowController, @escaping @MainActor () -> Void) -> Void)?
    private var didReport = false

    /// True for runs made from a terminal to measure or photograph the app. They show nothing on screen,
    /// never take the keyboard and never stop to ask a question.
    var isUnattended: Bool { snapshotURL != nil || reportsTiming || quitsAfterFirstFrame || closesAfterFirstFrame }

    init() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--snapshot":
                if !arguments.isEmpty { snapshotURL = URL(fileURLWithPath: arguments.removeFirst()) }
            case "--delay":
                if !arguments.isEmpty { snapshotDelay = TimeInterval(arguments.removeFirst()) ?? snapshotDelay }
            case "--edit":
                startsEditing = true
            case "--demo":
                let name = arguments.isEmpty ? "meme" : arguments.removeFirst()
                script = { $0.runDemoScript(name, done: $1) }
            case "--timing":
                reportsTiming = true
            case "--quit":
                quitsAfterFirstFrame = true
            case "--close":
                closesAfterFirstFrame = true
            case "--make-default":
                defaultsAction = .register
            case "--restore-default":
                defaultsAction = .restore
            default:
                // Finder and `open` pass things like -NSDocumentRevisionsDebugMode; ignore any switch we do not know.
                if !argument.hasPrefix("-") { files.append(URL(fileURLWithPath: argument)) }
            }
        }
    }

    func reportFirstFrame() {
        guard reportsTiming, !didReport else { return }
        didReport = true
        let sinceMain = Double(DispatchTime.now().uptimeNanoseconds - launchStart.uptimeNanoseconds) / 1_000_000
        var message = String(format: "first frame %.0f ms after main()", sinceMain)
        if let started = Self.processStartTime() {
            message += String(format: ", %.0f ms after the process was created", Date().timeIntervalSince(started) * 1000)
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// When the kernel created this process, which is earlier than main() by the time the loader needs.
    private static func processStartTime() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
