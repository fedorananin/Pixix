import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that shows a shortcut and, once clicked, takes the next key press as the new one.
/// Escape leaves the shortcut as it was; Delete removes it.
final class ShortcutRecorderButton: NSButton {
    var combo: KeyCombo? {
        didSet { refresh() }
    }
    var onChange: ((KeyCombo?) -> Void)?
    private var monitor: Any?
    /// What macOS hands back for switching its own shortcuts off, to be given back when recording ends.
    private var systemShortcuts: UnsafeMutableRawPointer?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var note: String?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle(_:))
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    private func refresh() {
        if let note {
            title = note
        } else if isRecording {
            // The modifiers show up as they go down, so it is plain that the keys are being heard.
            let held = KeyCombo.symbols(for: heldModifiers)
            title = held.isEmpty ? "Type a shortcut…" : held + "…"
        } else {
            title = combo?.title ?? "Click to record"
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        guard !isRecording else { return }
        isRecording = true
        heldModifiers = []
        note = nil
        // A shortcut in force would fire instead of being recorded.
        CaptureAgent.shared.suspendHotKeys()
        // So would the shortcuts of macOS itself, such as ⇧⌘5: they are switched off while this app is in front
        // and the recorder is listening.
        if !CaptureAgent.shared.isUnattended { systemShortcuts = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled)) }
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            // Local monitors run on the main thread, in the app's own event loop.
            let box = UncheckedBox(event)
            let taken = MainActor.assumeIsolated { self?.handle(box.value) ?? false }
            return taken ? nil : event
        }
        refresh()
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let systemShortcuts { PopSymbolicHotKeyMode(systemShortcuts) }
        systemShortcuts = nil
        heldModifiers = []
        note = nil
        CaptureAgent.shared.applyHotKeys()
        refresh()
    }

    /// True when the event was used and should go no further.
    private func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        switch event.type {
        case .flagsChanged:
            heldModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if !heldModifiers.isEmpty { note = nil }
            refresh()
            return false
        case .leftMouseDown:
            // A click anywhere else ends the recording; a click on the button reaches it and does the same.
            if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) { stop() }
            return false
        case .keyDown:
            return record(event)
        default:
            return false
        }
    }

    private func record(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plain:
            stop()
        case kVK_Delete where plain, kVK_ForwardDelete where plain:
            stop()
            combo = nil
            onChange?(nil)
        default:
            guard let combo = KeyCombo(event: event) else {
                // A key alone would be taken away from typing everywhere, so it is not accepted.
                flash("Add ⌘, ⌥ or ⌃")
                return true
            }
            stop()
            self.combo = combo
            onChange?(combo)
        }
        return true
    }

    /// Shows a word on the button for a moment.
    private func flash(_ text: String) {
        NSSound.beep()
        note = text
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.note == text else { return }
            self.note = nil
            self.refresh()
        }
    }

    // A second road for the keys, in case an event reaches the window without passing the monitor.
    override func keyDown(with event: NSEvent) {
        if !record(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording, event.type == .keyDown { return record(event) }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.combo = combo
        button.onChange = { combo = $0 }
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        // Not while a shortcut is being typed: the button is showing the typing, not the value.
        if !button.isRecording, button.combo != combo { button.combo = combo }
        button.onChange = { combo = $0 }
    }
}
