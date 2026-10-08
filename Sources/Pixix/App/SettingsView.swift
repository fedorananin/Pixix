import AppKit
import Observation
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
    }
}
