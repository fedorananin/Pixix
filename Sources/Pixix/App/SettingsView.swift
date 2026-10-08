import AppKit
import Observation
import PixixCodec
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SettingsModel {
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

    /// True for a scripted picture of the window: the screenshot options are laid out although screenshots
    /// are off. Nothing is switched on for it; the observers below run even when set from an initializer.
    let previewsScreenshotOptions: Bool
    var showsScreenshotOptions: Bool { capturesScreenshots || previewsScreenshotOptions }

    init(previewingScreenshotOptions: Bool = false) {
        previewsScreenshotOptions = previewingScreenshotOptions
    }

    // MARK: Screenshots

    var capturesScreenshots = Settings.shared.capturesScreenshots {
        didSet {
            guard capturesScreenshots != oldValue else { return }
            Settings.shared.capturesScreenshots = capturesScreenshots
            if capturesScreenshots {
                CaptureAgent.shared.start()
                // The best moment for macOS to ask: the user has just said they want screenshots.
                if !ScreenGrabber.hasAccess { CaptureAgent.shared.askForAccess() }
            } else {
                CaptureAgent.shared.stop()
                // Nothing is left to wait for in the background.
                if launchesAtLogin { launchesAtLogin = false }
            }
            refreshCaptureState()
        }
    }

    var captureHotKey = Settings.shared.captureHotKey {
        didSet {
            guard captureHotKey != oldValue else { return }
            Settings.shared.captureHotKey = captureHotKey
            CaptureAgent.shared.applyHotKey()
            refreshCaptureState()
        }
    }

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
    var loginMessage = ""

    func refreshCaptureState() {
        hasScreenAccess = ScreenGrabber.hasAccess
        hotKeyIsUsedByMacOS = captureHotKey?.isUsedByMacOS ?? false
        if let combo = captureHotKey, hotKeyIsUsedByMacOS {
            hotKeyMessage = "macOS uses \(combo.title) itself, and acts on it before Pixix can. Switch it off under Keyboard › Keyboard Shortcuts in System Settings, or choose another shortcut."
        } else if capturesScreenshots, captureHotKey != nil, !CaptureAgent.shared.hotKeyIsClaimed {
            hotKeyMessage = "macOS did not grant this shortcut; another app is probably using it."
        } else if captureHotKey == nil {
            hotKeyMessage = "No shortcut: screenshots start from the menu bar icon."
        } else {
            hotKeyMessage = ""
        }
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

    var body: some View {
        Form {
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
                Text("Save overwrites the file. With this on, the file as it was before the first Save of an editing session goes to the Trash, where Put Back restores it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Screenshots") {
                Toggle("Take screenshots with Pixix", isOn: $model.capturesScreenshots)
                Text("Pixix keeps an icon in the menu bar and stays there after its windows are closed, so the shortcut works at any time. Press it, drag over a part of the screen, mark it up, then copy or save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.showsScreenshotOptions {
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(combo: $model.captureHotKey).frame(width: 150)
                    }
                    Text(model.hotKeyMessage.isEmpty
                        ? "Click the shortcut, then press the new one: a key with ⌘, ⌥ or ⌃, or a function key. Esc keeps the old one, Delete removes it."
                        : model.hotKeyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.hotKeyIsUsedByMacOS {
                        Button("Open Keyboard Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                    Toggle("Start Pixix at login", isOn: $model.launchesAtLogin)
                    if !model.loginMessage.isEmpty {
                        Text(model.loginMessage).font(.callout).foregroundStyle(.secondary)
                    }
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
                    if !model.hasScreenAccess {
                        LabeledContent("Permission") {
                            Button("Open System Settings…") { NSWorkspace.shared.open(ScreenGrabber.settingsURL) }
                        }
                        Text("macOS has not allowed Pixix to see the screen. Allow it under Privacy & Security › Screen & System Audio Recording, then quit Pixix and open it again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshCaptureState() }
    }
}
