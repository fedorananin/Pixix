import AppKit
import Carbon.HIToolbox

/// A key with its modifiers: what a global shortcut is made of.
struct KeyCombo: Codable, Hashable {
    /// The position of the key on the keyboard, which does not change with the input language.
    var keyCode: UInt32
    /// ⌘ ⌥ ⌃ ⇧ as raw `NSEvent.ModifierFlags`.
    var modifiers: UInt
    /// What the key is called on the keyboard it was recorded with.
    var keyLabel: String

    static let standard = KeyCombo(
        keyCode: UInt32(kVK_ANSI_2), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyLabel: "2"
    )

    /// What the color picker starts with: the key next to the screenshot's.
    static let pickerStandard = KeyCombo(
        keyCode: UInt32(kVK_ANSI_1), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyLabel: "1"
    )

    /// True when both are the same press, whatever the key was called when each was recorded.
    func isSamePress(as other: KeyCombo) -> Bool {
        keyCode == other.keyCode && flags == other.flags
    }

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .option, .control, .shift])
    }

    var carbonModifiers: UInt32 {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }

    /// The shortcut the way macOS writes it, such as ⇧⌘2.
    var title: String { Self.symbols(for: flags) + keyLabel }

    /// The key as a menu item wants it, when it is one a menu can show.
    var menuKeyEquivalent: String {
        Self.namedKeys[Int(keyCode)] == nil && keyLabel.count == 1 ? keyLabel.lowercased() : ""
    }

    init(keyCode: UInt32, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// The shortcut a key press spells. Nil when it could not be a global one: a plain letter would swallow typing
    /// everywhere, so anything but a function key needs ⌘, ⌥ or ⌃.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys.contains(code)
        guard isFunctionKey || !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        // The name is for showing only; a key that cannot be named still makes a shortcut.
        let label = Self.namedKeys[code] ?? Self.latinLabel(for: event.keyCode)
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(keyCode: UInt32(code), modifiers: flags.rawValue, keyLabel: label.flatMap { $0.isEmpty ? nil : $0 } ?? "Key \(code)")
    }

    /// What the key types on the Latin layout of this keyboard, which is how macOS writes shortcuts in menus
    /// whatever language is being typed.
    private static func latinLabel(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let pointer = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                pointer, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let label = String(utf16CodeUnits: characters, count: length).uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    /// The modifiers alone, as they are shown while a shortcut is being typed.
    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    /// True when macOS keeps this shortcut for something of its own and it is switched on in System Settings.
    /// macOS then acts on it first and the app never hears it.
    var isUsedByMacOS: Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let list = array?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            entry[kHISymbolicHotKeyEnabled as String] as? Bool == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int).map { UInt32(truncatingIfNeeded: $0) } == keyCode
                && (entry[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32(truncatingIfNeeded: $0) } == carbonModifiers
        }
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Keys that type nothing a label could be read from.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌅", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// A shortcut that works whatever app is in front. Carbon's hot keys need no permission and no event tap,
/// and they are what every screenshot tool on the Mac uses.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void
    /// Tells this shortcut from the app's other ones: a press of any of them is offered to every handler.
    private let id: UInt32
    private static let signature: OSType = 0x5049_5849

    init(id: UInt32 = 1, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = action
    }

    var isRegistered: Bool { hotKey != nil }

    /// The handler holds this object unretained, so it must not outlive it: a press delivered to a handler
    /// whose owner is gone would call into freed memory.
    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Claims the shortcut, letting go of the one held before. False when macOS refuses, which usually means
    /// another app has it. A shortcut of macOS itself is granted here and then never arrives.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()
        installHandler()
        let name = EventHotKeyID(signature: Self.signature, id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, name, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return false }
        hotKey = reference
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// Delivers the shortcut to this app the way macOS does when it is pressed, without anyone pressing it.
    /// For checking that a press would arrive; returns false when the event found no handler.
    func simulatePress() -> Bool {
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr, let event else { return false }
        defer { ReleaseEvent(event) }
        var name = EventHotKeyID(signature: Self.signature, id: id)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &name
        )
        return SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let owner = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            let pressedID = pressed.id
            // Hot keys are delivered on the main thread, through the app's own event loop.
            let address = Int(bitPattern: userData)
            return MainActor.assumeIsolated {
                guard let pointer = UnsafeRawPointer(bitPattern: address) else { return OSStatus(eventNotHandledErr) }
                let key = Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue()
                // Another shortcut of the app's: the handler that owns it comes next.
                guard status == noErr, pressedID == key.id else { return OSStatus(eventNotHandledErr) }
                key.action()
                return noErr
            }
        }, 1, &spec, owner, &handler)
    }
}
