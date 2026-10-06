import PixixEngine
import SwiftUI

private struct DialogButtons: View {
    var confirm: String
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(confirm, action: onConfirm)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 14)
    }
}

/// Image › Resize: scales the whole picture, proportionally or stretched.
struct ResizeDialog: View {
    @Bindable var model: EditorModel
    let original: CGSize
    var onDone: (_ size: CGSize?) -> Void

    private var widthBinding: Binding<Int> {
        Binding(get: { model.resizeWidth }, set: { value in
            model.resizeWidth = max(value, 1)
            if model.resizeKeepsAspect, original.width > 0 {
                model.resizeHeight = max(1, Int((Double(model.resizeWidth) * original.height / original.width).rounded()))
            }
        })
    }

    private var heightBinding: Binding<Int> {
        Binding(get: { model.resizeHeight }, set: { value in
            model.resizeHeight = max(value, 1)
            if model.resizeKeepsAspect, original.height > 0 {
                model.resizeWidth = max(1, Int((Double(model.resizeHeight) * original.width / original.height).rounded()))
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resize Image").font(.headline)
            Text(verbatim: "Now \(Int(original.width)) × \(Int(original.height)) px")
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Width")
                    TextField("Width", value: widthBinding, format: .number.grouping(.never)).frame(width: 90)
                    Text("px")
                }
                GridRow {
                    Text("Height")
                    TextField("Height", value: heightBinding, format: .number.grouping(.never)).frame(width: 90)
                    Text("px")
                }
            }
            Toggle("Keep proportions", isOn: Binding(get: { model.resizeKeepsAspect }, set: { on in
                model.resizeKeepsAspect = on
                if on { widthBinding.wrappedValue = model.resizeWidth }
            }))
            HStack {
                ForEach([25, 50, 75, 200], id: \.self) { percent in
                    Button(String(percent) + "%") {
                        model.resizeWidth = max(1, Int((original.width * Double(percent) / 100).rounded()))
                        model.resizeHeight = max(1, Int((original.height * Double(percent) / 100).rounded()))
                    }
                    .controlSize(.small)
                }
            }
            if !model.resizeKeepsAspect {
                Text("Turning proportions off stretches the picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DialogButtons(confirm: "Resize", onCancel: { onDone(nil) }) {
                onDone(CGSize(width: model.resizeWidth, height: model.resizeHeight))
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// Image › Canvas Size: adds or removes room around the picture without scaling it.
struct CanvasSizeDialog: View {
    @Bindable var model: EditorModel
    let original: CGSize
    var onDone: (_ size: CGSize?, _ anchor: CGPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Canvas Size").font(.headline)
            Text(verbatim: "Now \(Int(original.width)) × \(Int(original.height)) px")
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Width")
                    TextField("Width", value: $model.canvasWidth, format: .number.grouping(.never)).frame(width: 90)
                    Text("px")
                }
                GridRow {
                    Text("Height")
                    TextField("Height", value: $model.canvasHeight, format: .number.grouping(.never)).frame(width: 90)
                    Text("px")
                }
            }
            Text("Keep the picture at")
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            let anchor = CGPoint(x: Double(column) / 2, y: Double(row) / 2)
                            Button { model.canvasAnchor = anchor } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(model.canvasAnchor == anchor ? Color.accentColor : Color.secondary.opacity(0.25))
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Anchor row \(row + 1), column \(column + 1)")
                        }
                    }
                }
            }
            DialogButtons(confirm: "Apply", onCancel: { onDone(nil, .zero) }) {
                onDone(CGSize(width: max(model.canvasWidth, 1), height: max(model.canvasHeight, 1)), model.canvasAnchor)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

/// Sliders for one item of the Adjustments or Effects menu, previewed live on the canvas.
struct EffectDialog: View {
    @Bindable var model: EditorModel
    let effect: EffectDescriptor
    var onChange: () -> Void
    var onDone: (_ apply: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(effect.name).font(.headline)
            ForEach(effect.parameters) { parameter in
                let binding = Binding<Double>(
                    get: { model.effectValues[parameter.id] ?? parameter.defaultValue },
                    set: { value in
                        model.effectValues[parameter.id] = value
                        onChange()
                    }
                )
                HStack(spacing: 10) {
                    Text(parameter.name).frame(width: 96, alignment: .leading)
                    if parameter.range.upperBound - parameter.range.lowerBound <= 1, parameter.step == 1 {
                        Toggle("", isOn: Binding(get: { binding.wrappedValue > 0.5 }, set: { binding.wrappedValue = $0 ? 1 : 0 }))
                            .labelsHidden()
                        Spacer()
                    } else {
                        if parameter.step > 0 {
                            Slider(value: binding, in: parameter.range, step: parameter.step)
                        } else {
                            Slider(value: binding, in: parameter.range)
                        }
                        Text(format(binding.wrappedValue, parameter))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            HStack {
                Button("Reset") {
                    model.effectValues = effect.defaults
                    onChange()
                }
                Spacer()
                Button("Cancel", role: .cancel) { onDone(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onDone(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 420)
    }

    private func format(_ value: Double, _ parameter: EffectParameter) -> String {
        let span = parameter.range.upperBound - parameter.range.lowerBound
        return span <= 5 ? String(format: "%.2f", value) : String(format: "%.0f", value)
    }
}
