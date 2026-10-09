import AppKit
import PixixCodec

/// One press of the shortcut: every display frozen under an overlay, until a part of one is copied, saved,
/// sent to the editor or dismissed.
@MainActor
final class CaptureSession {
    private(set) var screens: [CaptureScreenController] = []
    /// True for a scripted run, which shows nothing on screen and takes no keyboard.
    let isUnattended: Bool
    /// Called once the overlays are gone. The flag says whether the app that was in front should get the keyboard back.
    var onEnd: ((_ returningFocus: Bool) -> Void)?
    private var hasEnded = false

    init(shots: [ScreenShot], isUnattended: Bool) {
        self.isUnattended = isUnattended
        screens = shots.map { CaptureScreenController(session: self, shot: $0) }
    }

    func begin() {
        for screen in screens { screen.show() }
        guard !isUnattended else { return }
        // The overlay under the pointer takes the keyboard; the others get it when the pointer comes to them.
        let pointer = NSEvent.mouseLocation
        (screens.first { $0.shot.frame.contains(pointer) } ?? screens.first)?.panel.makeKeyAndOrderFront(nil)
        // Only the active app chooses the pointer's shape. The plain `activate()` asks the app in front to
        // give way and may be turned down; a screenshot was asked for by the user and cannot wait.
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.set()
    }

    /// There is one selection at a time: starting one on a display drops what the others had.
    func willSelect(on screen: CaptureScreenController) {
        for other in screens where other !== screen { other.clearSelection() }
    }

    /// False while another display holds markup that a new selection would throw away.
    func maySelect(on screen: CaptureScreenController) -> Bool {
        !screens.contains { $0 !== screen && $0.hasMarkup }
    }

    /// Takes the overlays off the screen for a moment, for a dialog that would open under them.
    func setHidden(_ hidden: Bool) {
        for screen in screens { screen.setHidden(hidden) }
    }

    func end(returningFocus: Bool = true) {
        guard !hasEnded else { return }
        hasEnded = true
        for screen in screens { screen.close() }
        screens = []
        onEnd?(returningFocus)
    }
}

/// Where a finished screenshot goes when it goes to a file, and the word that says so.
@MainActor
enum CaptureOutput {
    /// A name like the ones macOS gives: "Screenshot 2026-10-08 at 21.53.04.png".
    static func fileName(format: ImageFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// Saves into the screenshots folder under a name of its own.
    static func save(_ image: CGImage, scale: CGFloat) {
        let format = Settings.shared.captureFormat
        let folder = Settings.shared.captureFolder
        write(image, scale: scale, format: format, to: folder.appendingPathComponent(fileName(format: format)), keepingExisting: true)
    }

    /// Encodes and writes off the main thread. With `keepingExisting` a taken name gets a number instead of being replaced.
    static func write(_ image: CGImage, scale: CGFloat, format: ImageFormat, to url: URL, keepingExisting: Bool = false) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let destination = keepingExisting ? FileWriter.uniqueURL(near: url) : url
                    // The resolution tells other apps how large the picture was on screen.
                    let resolution = 72 * Double(scale)
                    let data = try ImageEncoder.encode(image, format: format, quality: 0.9, properties: [
                        kCGImagePropertyDPIWidth: resolution, kCGImagePropertyDPIHeight: resolution,
                    ])
                    try FileWriter.write(data, to: destination)
                    return destination
                }
            }.value
            switch result {
            case .success(let destination):
                announce("Saved to \(destination.deletingLastPathComponent().lastPathComponent)")
            case .failure(let error):
                let alert = NSAlert(error: error)
                alert.messageText = "The screenshot could not be saved"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    private static var notice: NSPanel?

    /// A word at the bottom of the screen that fades by itself: the overlay is gone by the time a screenshot
    /// has landed, so something has to say that it did. A picked color is shown beside its name.
    static func announce(_ text: String, swatch: RGBAColor? = nil) {
        guard CaptureAgent.shared.announces else { return }
        notice?.close()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let lead: CGFloat = swatch == nil ? 16 : 36
        let size = NSSize(width: label.frame.width + lead + 16, height: 32)
        let pill = NSView(frame: NSRect(origin: .zero, size: size))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        pill.layer?.cornerRadius = 16
        label.setFrameOrigin(NSPoint(x: lead, y: (size.height - label.frame.height) / 2))
        pill.addSubview(label)
        if let swatch {
            let chip = NSView(frame: NSRect(x: 12, y: 8, width: 16, height: 16))
            chip.wantsLayer = true
            chip.layer?.backgroundColor = swatch.cgColor
            chip.layer?.cornerRadius = 4
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
            pill.addSubview(chip)
        }

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let panel = NSPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2, y: visible.minY + 90, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = pill
        panel.orderFrontRegardless()
        notice = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.close()
                    if notice === panel { notice = nil }
                }
            })
        }
    }
}
