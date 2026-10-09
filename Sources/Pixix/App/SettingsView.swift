import AppKit
import Observation
import PixixCodec
import PixixEngine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The pages of the Settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, screenshots, colors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .screenshots: "Screenshots"
        case .colors: "Color Picker"
        }
    }
}

@MainActor
@Observable
final class SettingsModel {
    var tab: SettingsTab

    var sortOrder = Settings.shared.sortOrder {
        didSet {
            Settings.shared.sortOrder = sortOrder
            (NSApp.delegate as? AppDelegate)?.sortOrderDidChange()
        }
    }

    var sortDescending = Settings.shared.sortDescending {
        didSet {
            Settings.shared.sortDescending = sortDescending
            (NSApp.delegate as? AppDelegate)?.sortOrderDidChange()
        }
    }

    var wheelZooms = Settings.shared.wheelZooms {
        didSet { Settings.shared.wheelZooms = wheelZooms }
    }

    var wrapAround = Settings.shared.wrapAround {
        didSet { Settings.shared.wrapAround = wrapAround }
    }

    var slideshowInterval = Settings.shared.slideshowInterval {
        didSet { Settings.shared.slideshowInterval = slideshowInterval }
    }

    var opensNewWindows = Settings.shared.opensNewWindows {
        didSet { Settings.shared.opensNewWindows = opensNewWindows }
    }

    var keepsOriginalInTrash = Settings.shared.keepsOriginalInTrash {
        didSet { Settings.shared.keepsOriginalInTrash = keepsOriginalInTrash }
    }

    /// True for a scripted picture of the window: the options of screenshots and of the color picker are laid
    /// out although both are off. Nothing is switched on for it; the observers below run even when set from
    /// an initializer.
    let previewsOptions: Bool
    var showsScreenshotOptions: Bool { capturesScreenshots || previewsOptions }
    var showsPickerOptions: Bool { picksColors || previewsOptions }

    init(tab: SettingsTab = .general, previewingOptions: Bool = false) {
        self.tab = tab
        previewsOptions = previewingOptions
    }

    // MARK: Screenshots

    var capturesScreenshots = Settings.shared.capturesScreenshots {
        didSet {
            guard capturesScreenshots != oldValue else { return }
            Settings.shared.capturesScreenshots = capturesScreenshots
            backgroundWorkDidChange(switchedOn: capturesScreenshots)
        }
    }

    var captureHotKey = Settings.shared.captureHotKey {
        didSet {
            guard captureHotKey != oldValue else { return }
            Settings.shared.captureHotKey = captureHotKey
            CaptureAgent.shared.applyHotKeys()
            refreshCaptureState()
        }
    }

    /// Screenshots or the color picker were switched on or off: both keep Pixix in the menu bar and need to
    /// see the screen.
    private func backgroundWorkDidChange(switchedOn: Bool) {
        CaptureAgent.shared.refresh()
        if switchedOn {
            // The best moment for macOS to ask: the user has just said what they want it for.
            if !ScreenGrabber.hasAccess { CaptureAgent.shared.askForAccess() }
        } else if !Settings.shared.staysInMenuBar, launchesAtLogin {
            // Nothing is left to wait for in the background.
            launchesAtLogin = false
        }
        refreshCaptureState()
    }

    // MARK: Color picker

    var picksColors = Settings.shared.picksColors {
        didSet {
            guard picksColors != oldValue else { return }
            Settings.shared.picksColors = picksColors
            backgroundWorkDidChange(switchedOn: picksColors)
        }
    }

    var pickerHotKey = Settings.shared.pickerHotKey {
        didSet {
            guard pickerHotKey != oldValue else { return }
            Settings.shared.pickerHotKey = pickerHotKey
            CaptureAgent.shared.applyHotKeys()
            refreshCaptureState()
        }
    }

    var pickerAction = Settings.shared.pickerAction {
        didSet { Settings.shared.pickerAction = pickerAction }
    }

    var pickerCopyNotation = Settings.shared.pickerCopyNotation {
        didSet { Settings.shared.pickerCopyNotation = pickerCopyNotation }
    }

    var pickerNotations = Settings.shared.pickerNotations {
        didSet {
            guard pickerNotations != oldValue else { return }
            Settings.shared.pickerNotations = pickerNotations
            // What a click copies is always one of the notations on show.
            if !pickerNotations.contains(pickerCopyNotation), let first = pickerNotations.first { pickerCopyNotation = first }
        }
    }

    var pickerBareHex = Settings.shared.pickerBareHex {
        didSet { Settings.shared.pickerBareHex = pickerBareHex }
    }

    /// Shows or hides a notation. The last one stays: a magnifier with no values would say nothing.
    func setShown(_ notation: ColorNotation, _ shown: Bool) {
        let wanted = ColorNotation.allCases.filter { $0 == notation ? shown : pickerNotations.contains($0) }
        if !wanted.isEmpty { pickerNotations = wanted }
    }

    // MARK: In the menu bar

    var launchesAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchesAtLogin != oldValue, launchesAtLogin != (SMAppService.mainApp.status == .enabled),
                  !CaptureAgent.shared.isUnattended
            else { return }
            do {
                if launchesAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginMessage = ""
            } catch {
                loginMessage = error.localizedDescription
                launchesAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    var captureFolder = Settings.shared.captureFolder {
        didSet { Settings.shared.captureFolder = captureFolder }
    }

    var captureFormat = Settings.shared.captureFormat {
        didSet { Settings.shared.captureFormat = captureFormat }
    }

    var hasScreenAccess = ScreenGrabber.hasAccess
    var hotKeyMessage = ""
    var hotKeyIsUsedByMacOS = false
    var pickerKeyMessage = ""
    var pickerKeyIsUsedByMacOS = false
    var loginMessage = ""

    func refreshCaptureState() {
        let agent = CaptureAgent.shared
        hasScreenAccess = ScreenGrabber.hasAccess
        hotKeyIsUsedByMacOS = captureHotKey?.isUsedByMacOS ?? false
        pickerKeyIsUsedByMacOS = pickerHotKey?.isUsedByMacOS ?? false
        hotKeyMessage = message(
            for: captureHotKey, isUsedByMacOS: hotKeyIsUsedByMacOS,
            wasRefused: capturesScreenshots && agent.isRunning && !agent.screenshotKeyIsClaimed, starting: "screenshots start"
        )
        if capturesScreenshots, let combo = pickerHotKey, captureHotKey?.isSamePress(as: combo) == true {
            pickerKeyMessage = "\(combo.title) takes a screenshot already. Choose another shortcut for the color picker."
        } else {
            pickerKeyMessage = message(
                for: pickerHotKey, isUsedByMacOS: pickerKeyIsUsedByMacOS,
                wasRefused: picksColors && agent.isRunning && !agent.pickerKeyIsClaimed, starting: "the color picker starts"
            )
        }
    }

    /// What is wrong with a shortcut, or nothing.
    private func message(for combo: KeyCombo?, isUsedByMacOS: Bool, wasRefused: Bool, starting: String) -> String {
        guard let combo else { return "No shortcut: \(starting) from the menu bar icon." }
        if isUsedByMacOS {
            return "macOS uses \(combo.title) itself, and acts on it before Pixix can. Switch it off under Keyboard › Keyboard Shortcuts in System Settings, or choose another shortcut."
        }
        return wasRefused ? "macOS did not grant this shortcut; another app is probably using it." : ""
    }

    func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = captureFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { captureFolder = url }
    }

    var defaultAppMessage = ""
    var canRestoreDefaults = DefaultViewer.hasBackup
    var restoreCount = DefaultViewer.backupCount

    /// Asks macOS to open every supported format with Pixix.
    func makeDefaultViewer() {
        defaultAppMessage = "Asking macOS…"
        Task {
            defaultAppMessage = await DefaultViewer.register().summary
            refreshRestoreState()
        }
    }

    func restoreDefaultViewers() {
        defaultAppMessage = "Answer the macOS dialogs…"
        Task {
            defaultAppMessage = await DefaultViewer.restore()
            refreshRestoreState()
        }
    }

    private func refreshRestoreState() {
        canRestoreDefaults = DefaultViewer.hasBackup
        restoreCount = DefaultViewer.backupCount
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    private static let shortcutHelp = "Click the shortcut, then press the new one: a key with ⌘, ⌥ or ⌃, or a function key. Esc keeps the old one, Delete removes it."

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 14)
            Form {
                switch model.tab {
                case .general: general
                case .screenshots: screenshots
                case .colors: colors
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshCaptureState() }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var general: some View {
        Section("Browsing") {
            Picker("Sort images by", selection: $model.sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Reverse order", isOn: $model.sortDescending)
            Toggle("Continue from the first image after the last", isOn: $model.wrapAround)
            Toggle("Mouse wheel zooms", isOn: $model.wheelZooms)
            Toggle("Open each picture in its own window", isOn: $model.opensNewWindows)
            LabeledContent("Slideshow interval") {
                HStack {
                    Slider(value: $model.slideshowInterval, in: 1...15, step: 1)
                        .frame(width: 160)
                    Text(verbatim: "\(Int(model.slideshowInterval)) s")
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        Section("Saving") {
            Toggle("Keep the original in the Trash on the first Save", isOn: $model.keepsOriginalInTrash)
            note("Save overwrites the file. With this on, the file as it was before the first Save of an editing session goes to the Trash, where Put Back restores it.")
        }
        Section("Default Viewer") {
            HStack {
                Button("Open Images with Pixix") { model.makeDefaultViewer() }
                Button("Restore Previous Apps") { model.restoreDefaultViewers() }
                    .disabled(!model.canRestoreDefaults)
            }
            if model.canRestoreDefaults {
                Text(verbatim: "Restoring makes macOS ask for confirmation once per file type: \(model.restoreCount) dialogs. To switch a single type, use Finder › Get Info › Open With › Change All.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.defaultAppMessage.isEmpty {
                Text(model.defaultAppMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var screenshots: some View {
        Section {
            Toggle("Take screenshots with Pixix", isOn: $model.capturesScreenshots)
            note("Pixix keeps an icon in the menu bar and stays there after its windows are closed, so the shortcut works at any time. Press it, drag over a part of the screen, mark it up, then copy or save.")
            if model.showsScreenshotOptions {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $model.captureHotKey).frame(width: 150)
                }
                note(model.hotKeyMessage.isEmpty ? Self.shortcutHelp : model.hotKeyMessage)
                if model.hotKeyIsUsedByMacOS { keyboardSettingsButton }
                LabeledContent("Save to") {
                    HStack {
                        Text(verbatim: model.captureFolder.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.captureFolder.path(percentEncoded: false))
                        Button("Choose…") { model.chooseCaptureFolder() }
                    }
                }
                Picker("Format", selection: $model.captureFormat) {
                    Text("PNG").tag(ImageFormat.png)
                    Text("JPEG").tag(ImageFormat.jpeg)
                }
            }
        }
        if model.showsScreenshotOptions { menuBar }
    }

    @ViewBuilder private var colors: some View {
        Section {
            Toggle("Pick colors from the screen with Pixix", isOn: $model.picksColors)
            note("Pixix keeps an icon in the menu bar and stays there after its windows are closed, so the shortcut works at any time. Press it and a magnifier follows the pointer, showing the color of the pixel under it. A click takes the color; the arrow keys move by one pixel, Esc backs out.")
            if model.showsPickerOptions {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $model.pickerHotKey).frame(width: 150)
                }
                note(model.pickerKeyMessage.isEmpty ? Self.shortcutHelp : model.pickerKeyMessage)
                if model.pickerKeyIsUsedByMacOS { keyboardSettingsButton }
            }
        }
        if model.showsPickerOptions {
            Section {
                Picker("A click", selection: $model.pickerAction) {
                    ForEach(PickerAction.allCases) { Text($0.title).tag($0) }
                }
                Picker("Copy as", selection: $model.pickerCopyNotation) {
                    ForEach(model.pickerNotations) { notation in
                        Text(verbatim: "\(notation.name)   \(notation.text(of: Self.sample, bareHex: model.pickerBareHex))").tag(notation)
                    }
                }
                note("A click with ⌥ held does the other of the two. The window shows every value with a button to copy it.")
                LabeledContent("Show") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        ForEach(Self.notationRows, id: \.self) { row in
                            GridRow {
                                ForEach(row) { notation in
                                    Toggle(notation.name, isOn: Binding(
                                        get: { model.pickerNotations.contains(notation) }, set: { model.setShown(notation, $0) }
                                    ))
                                    .toggleStyle(.checkbox)
                                    // The last one on show cannot be switched off.
                                    .disabled(model.pickerNotations == [notation])
                                }
                            }
                        }
                    }
                }
                note("The values the magnifier and the window show. They are sRGB, whatever the display.")
                Toggle("Write HEX without the #", isOn: $model.pickerBareHex)
            }
            menuBar
        }
    }

    /// The notations three to a line: all of them side by side are wider than the window.
    private static let notationRows: [[ColorNotation]] = stride(from: 0, to: ColorNotation.allCases.count, by: 3).map {
        Array(ColorNotation.allCases[$0..<min($0 + 3, ColorNotation.allCases.count)])
    }

    /// What the examples in the menu are written for.
    private static let sample = RGBAColor(red: 26.0 / 255, green: 43.0 / 255, blue: 60.0 / 255)

    private var keyboardSettingsButton: some View {
        Button("Open Keyboard Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        }
    }

    /// What screenshots and the color picker share: the process that waits for their shortcuts, and the
    /// permission to see the screen. Shown on both pages, so each says all there is to set up.
    @ViewBuilder private var menuBar: some View {
        Section("In the Menu Bar") {
            Toggle("Start Pixix at login", isOn: $model.launchesAtLogin)
            if !model.loginMessage.isEmpty {
                Text(model.loginMessage).font(.callout).foregroundStyle(.secondary)
            }
            if !model.hasScreenAccess {
                LabeledContent("Permission") {
                    Button("Open System Settings…") { NSWorkspace.shared.open(ScreenGrabber.settingsURL) }
                }
                note("macOS has not allowed Pixix to see the screen. Allow it under Privacy & Security › Screen & System Audio Recording, then quit Pixix and open it again.")
            }
        }
    }
}
