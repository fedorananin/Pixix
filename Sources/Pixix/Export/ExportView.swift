import PixixCodec
import SwiftUI

struct ExportView: View {
    @Bindable var model: ExportModel
    var onCancel: () -> Void
    /// The flag is true when the user wants to choose where the file goes.
    var onConfirm: (_ choosingLocation: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.headline)
                .padding(.bottom, 12)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Preset")
                    HStack {
                        Picker("Preset", selection: Binding(
                            get: { model.selectedPreset }, set: { model.applyPreset($0) }
                        )) {
                            Text("Custom").tag(ExportPreset.ID?.none)
                            ForEach(model.presets) { preset in
                                Text(preset.name).tag(ExportPreset.ID?.some(preset.id))
                            }
                        }
                        .labelsHidden()
                        Button("Save…") {
                            model.presetName = ""
                            model.isNamingPreset = true
                        }
                        .help("Save the current settings as a preset")
                        Button(role: .destructive) { model.deleteSelectedPreset() } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(model.selectedPreset == nil)
                        .help("Delete the selected preset")
                    }
                }
                Divider().gridCellColumns(2)
                GridRow {
                    label("Format")
                    Picker("Format", selection: $model.format) {
                        ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                GridRow {
                    label("Size")
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Size", selection: $model.sizeMode) {
                            ForEach(ExportModel.SizeMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        sizeControls
                    }
                }
                if model.format.hasQuality {
                    GridRow {
                        label("Quality")
                        HStack {
                            Slider(value: $model.quality, in: 0.05...1)
                                .disabled(model.limitsFileSize)
                            Text(qualityText)
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                    GridRow {
                        label("")
                        HStack {
                            Toggle("Limit file size to", isOn: $model.limitsFileSize)
                            TextField("KB", value: $model.limitKB, format: .number)
                                .frame(width: 70)
                                .disabled(!model.limitsFileSize)
                            Text("KB")
                        }
                    }
                }
                GridRow {
                    label("Options")
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Remove metadata and location", isOn: $model.stripMetadata)
                        Toggle("Convert colors to sRGB", isOn: $model.convertToSRGB)
                        if !model.format.supportsAlpha, model.sourceHasAlpha {
                            ColorPicker("Fill transparency with", selection: backgroundBinding, supportsOpacity: false)
                        }
                    }
                }
            }

            if let note = animationNote {
                Label(note, systemImage: "film")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            Divider().padding(.vertical, 14)

            HStack(spacing: 10) {
                estimateView
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Choose Location…") { onConfirm(true) }
                    .disabled(!canConfirm)
                Button(model.confirmTitle) { onConfirm(false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
                    .help("Save next to the original file")
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("Preset Name", isPresented: $model.isNamingPreset) {
            TextField("Name", text: $model.presetName)
            Button("Save") {
                let name = model.presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.savePreset(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    @ViewBuilder private var sizeControls: some View {
        switch model.sizeMode {
        case .original:
            Text(verbatim: "\(Int(model.sourceSize.width)) × \(Int(model.sourceSize.height)) px")
                .foregroundStyle(.secondary)
        case .percent:
            HStack {
                Slider(value: $model.percent, in: 5...200, step: 5)
                Text(verbatim: "\(Int(model.percent))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            outputSizeText
        case .longEdge:
            HStack {
                TextField("Pixels", value: $model.longEdge, format: .number.grouping(.never))
                    .frame(width: 80)
                Text("px")
                ForEach([1280, 1920, 2560], id: \.self) { edge in
                    Button(String(edge)) { model.longEdge = edge }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            outputSizeText
        case .custom:
            HStack {
                TextField("Width", value: $model.customWidth, format: .number.grouping(.never))
                    .frame(width: 80)
                Text("×")
                TextField("Height", value: $model.customHeight, format: .number.grouping(.never))
                    .frame(width: 80)
                Text("px")
                Toggle(isOn: $model.keepsAspect) {
                    Image(systemName: model.keepsAspect ? "lock.fill" : "lock.open")
                }
                .toggleStyle(.button)
                .help("Keep the original proportions. Turn off to stretch.")
            }
        }
    }

    private var outputSizeText: some View {
        let size = model.outputSize
        return Text(verbatim: "\(size.width) × \(size.height) px")
            .foregroundStyle(.secondary)
    }

    private var qualityText: String {
        if case .ready(_, _, _, let used, _, _) = model.estimate, model.limitsFileSize {
            return "\(Int((used * 100).rounded()))%"
        }
        if model.format == .webp, model.quality >= 0.995 { return "Lossless" }
        return "\(Int((model.quality * 100).rounded()))%"
    }

    private var backgroundBinding: Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: model.background.red, green: model.background.green, blue: model.background.blue) },
            set: { color in
                let resolved = color.resolve(in: EnvironmentValues())
                model.background = RGBAColor(
                    red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue)
                )
            }
        )
    }

    private var animationNote: String? {
        guard model.isAnimatedSource else { return nil }
        return model.format.supportsAnimation
            ? "All frames of the animation are kept."
            : "\(model.format.displayName) holds one image, so only the first frame is saved."
    }

    private var canConfirm: Bool {
        if case .failed = model.estimate { return false }
        return true
    }

    @ViewBuilder private var estimateView: some View {
        switch model.estimate {
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Calculating size…").foregroundStyle(.secondary)
            }
        case .ready(let bytes, let width, let height, _, let fitsLimit, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(width) × \(height) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    .fontWeight(.medium)
                    .monospacedDigit()
                if !fitsLimit {
                    Text("Cannot get under the size limit")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let original = model.originalBytes, original > 0 {
                    let change = Double(bytes - original) / Double(original) * 100
                    Text(String(format: "%+.0f%% vs. original", change))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
