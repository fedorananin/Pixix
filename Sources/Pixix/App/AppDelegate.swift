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
            if controllers.isEmpty, !didOpenFiles { makeController().showWindow(nil) }
            NSApp.activate()
        }
    }

    /// The point of the whole app: closing the last window removes it from the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting with unsaved edits asks about each of them; the app then quits once its windows are gone.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        controllers.append(controller)
        return controller
    }

    func controllerDidClose(_ controller: ViewerWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        didOpenFiles = true
        trace("open \(urls.count) file(s)")
        prefetch(urls)
        // Reuse a window that is only viewing; never pull the rug from under an editing session.
        let controller = controllers.first { !$0.isEditing } ?? makeController()
        if let snapshot = launchOptions.snapshotURL, controller.onFirstImage == nil {
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
        controller.showWindow(nil)
        trace("window shown")
    }

    func newWindow(pasting image: CGImage) {
        let controller = controllers.first { !$0.isEditing && $0.currentURL == nil } ?? makeController()
        controller.showWindow(nil)
        controller.openPastedImage(image)
    }

    // MARK: Menu actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, ProjectFile.contentType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
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

    /// Writes what the window shows to a PNG and quits. Used to check the interface without a person looking.
    private func takeSnapshot(of controller: ViewerWindowController, to url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + launchOptions.snapshotDelay) { [self] in
            if launchOptions.startsEditing, !controller.isEditing {
                controller.beginEditing()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                    launchOptions.script?(controller)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        controller.writeSnapshot(to: url)
                        NSApp.terminate(nil)
                    }
                }
                return
            }
            if !launchOptions.startsEditing { launchOptions.script?(controller) }
            controller.writeSnapshot(to: url)
            NSApp.terminate(nil)
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
///                                          (meme, tools, crop, crop-applied, select, effect, export)
///     Pixix --snapshot out.png --demo mouse photo.jpg         the viewer after a scripted run of the wheel and side buttons
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
    var script: ((ViewerWindowController) -> Void)?
    private var didReport = false

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
                script = { $0.runDemoScript(name) }
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
