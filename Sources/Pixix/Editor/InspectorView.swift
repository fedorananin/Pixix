import AppKit
import PixixCodec
import PixixEngine
import SwiftUI

/// The editor's right-hand panel: tool options, layer properties, adjustments, layers and history.
struct InspectorView: View {
    @Bindable var model: EditorModel
    let editor: EditorController
    @FocusState private var textFocused: Bool

    private var document: Document { editor.document }

    var body: some View {
        // Reading the revision makes the panel refresh whenever the document changes.
        let _ = model.revision
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("tool", model.tool.title) { toolOptions }
                if let layer = document.activeLayer {
                    section("layer", layerTitle(layer)) { layerProperties(layer) }
                    if layer.effectRegion == nil {
                        section("adjust", "Adjust") { adjustments(layer) }
                    }
                }
                section("layers", "Layers") { layers }
                section("history", "History") { history }
            }
            .padding(.vertical, 6)
        }
        .controlSize(.small)
        .frame(width: 272)
        .background(Color(nsColor: NSColor(white: 0.15, alpha: 1)))
        .onChange(of: model.focusesTextEditor) { _, wants in
            if wants {
                textFocused = true
                model.focusesTextEditor = false
            }
        }
    }

    private func section<Content: View>(_ id: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        let body = content()
        return VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: model.isExpanded(id)) {
                VStack(alignment: .leading, spacing: 8) { body }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            } label: {
                Text(title).font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
        }
    }

    // MARK: Bindings

    private func slider(
        _ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String = "%.0f",
        onEnd: @escaping () -> Void = {}
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 74, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in
                if !editing { onEnd() }
            }
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    /// A binding to a property of the active layer. Edits in a row merge into one undo step until `endInteraction`.
    private func layerBinding<Value>(
        _ name: String, key: String, default fallback: Value, get: @escaping (Layer) -> Value?,
        set: @escaping (inout Layer, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { document.activeLayer.flatMap(get) ?? fallback },
            set: { value in
                guard let id = document.activeLayerID else { return }
                document.updateLayer(id, name: name, key: key) { set(&$0, value) }
            }
        )
    }

    private func textBinding<Value>(_ name: String, _ path: WritableKeyPath<TextContent, Value>, default fallback: Value) -> Binding<Value> {
        layerBinding(name, key: "text-\(name)", default: fallback, get: { $0.text?[keyPath: path] }) { layer, value in
            guard var text = layer.text else { return }
            let before = layer.localBounds
            text[keyPath: path] = value
            layer.content = .text(text)
            // Keep the box centered where it was, so typing does not walk the text across the picture.
            let after = layer.localBounds
            let shift = CGAffineTransform(translationX: (before.width - after.width) / 2, y: (before.height - after.height) / 2)
            layer.transform = shift.concatenating(layer.transform)
            model.textDefaults[keyPath: path] = value
        }
    }

    private func shapeBinding<Value>(_ name: String, _ path: WritableKeyPath<ShapeContent, Value>, default fallback: Value) -> Binding<Value> {
        layerBinding(name, key: "shape-\(name)", default: fallback, get: { $0.shape?[keyPath: path] }) { layer, value in
            guard var shape = layer.shape else { return }
            shape[keyPath: path] = value
            layer.content = .shape(shape)
        }
    }

    private func regionBinding<Value>(_ name: String, _ path: WritableKeyPath<EffectRegion, Value>, default fallback: Value) -> Binding<Value> {
        layerBinding(name, key: "region-\(name)", default: fallback, get: { $0.effectRegion?[keyPath: path] }) { layer, value in
            guard var region = layer.effectRegion else { return }
            region[keyPath: path] = value
            layer.content = .effect(region)
        }
    }

    private func colorBinding(_ source: Binding<RGBAColor>) -> Binding<Color> {
        Binding(get: { source.wrappedValue.color }, set: { source.wrappedValue = RGBAColor($0) })
    }

    private func endInteraction() {
        document.endInteraction()
    }

    // MARK: Tool options

    private var colorRow: some View {
        HStack(spacing: 8) {
            Text("Colors")
                .frame(width: 74, alignment: .leading)
                .foregroundStyle(.secondary)
            ColorPicker("Primary", selection: colorBinding($model.primaryColor))
                .labelsHidden()
                .help("Primary color")
            Button { model.swapColors() } label: { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.borderless)
                .help("Swap colors (X)")
            ColorPicker("Secondary", selection: colorBinding($model.secondaryColor))
                .labelsHidden()
                .help("Secondary color")
            Spacer()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var toolOptions: some View {
        switch model.tool {
        case .move:
            hint("Click a layer to select it and drag to move. Drag the square handles to resize and the round one to rotate. Arrow keys nudge.")
        case .crop:
            cropOptions
        case .selectRectangle, .selectEllipse, .lasso, .wand:
            selectionOptions
        case .brush, .pencil, .eraser, .clone:
            if model.tool != .eraser, model.tool != .clone { colorRow }
            slider("Size", value: $model.brushSize, in: 1...400)
            if model.tool != .pencil {
                slider("Hardness", value: Binding(get: { model.brushHardness * 100 }, set: { model.brushHardness = $0 / 100 }), in: 0...100)
            }
            slider("Opacity", value: Binding(get: { model.brushOpacity * 100 }, set: { model.brushOpacity = $0 / 100 }), in: 1...100)
            if model.tool == .clone {
                hint("Option-click the spot to copy from, then paint.")
            } else {
                hint("[ and ] change the size. Hold Control to paint with the secondary color.")
            }
        case .fill:
            colorRow
            slider("Tolerance", value: $model.tolerance, in: 0...100)
            Toggle("Contiguous area only", isOn: $model.contiguous)
            Toggle("Sample all layers", isOn: $model.sampleAllLayers)
        case .gradient:
            colorRow
            Picker("Shape", selection: $model.gradientIsRadial) {
                Text("Linear").tag(false)
                Text("Radial").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            hint("Drag from the primary color to the secondary color.")
        case .picker:
            colorRow
            Toggle("Sample all layers", isOn: $model.sampleAllLayers)
            hint("Click to set the primary color. Hold Option for the secondary color.")
        case .text:
            hint("Click the picture to add text, then type in the box below. Click existing text to edit it.")
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter:
            colorRow
            slider("Width", value: $model.strokeWidth, in: 1...80)
            if model.tool == .rectangle || model.tool == .ellipse {
                Toggle("Fill with secondary color", isOn: $model.fillsShapes)
            }
            if model.tool == .rectangle {
                slider("Corners", value: $model.cornerRadius, in: 0...200)
            }
            hint("Hold Shift to keep lines at 45° steps and boxes square.")
        case .blurRegion, .pixelateRegion:
            hint("Drag over the part to hide. The area stays movable and resizable, and its strength can be changed below.")
        }
    }

    @ViewBuilder private var cropOptions: some View {
        Picker("Ratio", selection: $model.cropAspect) {
            ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
        }
        if model.cropAspect == .custom {
            HStack {
                TextField("W", value: $model.customAspectWidth, format: .number)
                Text(":")
                TextField("H", value: $model.customAspectHeight, format: .number)
            }
        }
        HStack {
            Text("Size")
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: "\(Int(model.cropRect.width.rounded())) × \(Int(model.cropRect.height.rounded())) px")
                .monospacedDigit()
        }
        slider("Straighten", value: $model.straighten, in: -45...45, format: "%.1f°")
        HStack {
            Button { editor.rotateCanvas(quarterTurns: -1) } label: { Image(systemName: "rotate.left") }
                .help("Rotate left")
            Button { editor.rotateCanvas(quarterTurns: 1) } label: { Image(systemName: "rotate.right") }
                .help("Rotate right")
            Button { editor.flipCanvas(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .help("Flip horizontally")
            Button { editor.flipCanvas(horizontal: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                .help("Flip vertically")
            Spacer()
        }
        HStack {
            Button("Reset") { editor.resetCrop() }
            Spacer()
            Button("Apply Crop") { editor.applyCrop() }
                .buttonStyle(.borderedProminent)
        }
        hint("Drag the frame past the edge of the picture to extend the canvas. Press Return to apply.")
    }

    @ViewBuilder private var selectionOptions: some View {
        Picker("Mode", selection: $model.selectionMode) {
            Image(systemName: "square").help("Replace").tag(SelectionCombine.replace)
            Image(systemName: "plus.square").help("Add (Shift)").tag(SelectionCombine.add)
            Image(systemName: "minus.square").help("Subtract (Option)").tag(SelectionCombine.subtract)
            Image(systemName: "square.on.square.intersection.dashed").help("Intersect (Shift-Option)").tag(SelectionCombine.intersect)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if model.tool == .wand {
            slider("Tolerance", value: $model.tolerance, in: 0...100)
            Toggle("Contiguous area only", isOn: $model.contiguous)
            Toggle("Sample all layers", isOn: $model.sampleAllLayers)
        } else {
            slider("Feather", value: $model.feather, in: 0...100)
        }
        HStack {
            Button("All") { document.selectAll() }
            Button("None") { document.setSelection(nil) }
                .disabled(document.selection == nil)
            Button("Invert") { document.invertSelection() }
            Spacer()
        }
        if let bounds = document.selection?.bounds {
            hint("Selected: \(Int(bounds.width)) × \(Int(bounds.height)) px at \(Int(bounds.minX)), \(Int(bounds.minY))")
        }
    }

    // MARK: Layer properties

    private func layerTitle(_ layer: Layer) -> String {
        switch layer.content {
        case .raster: "Layer"
        case .text: "Text"
        case .shape: "Shape"
        case .effect(let region): region.effect == .blur ? "Blur Area" : "Pixelate Area"
        }
    }

    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies

    @ViewBuilder private func layerProperties(_ layer: Layer) -> some View {
        switch layer.content {
        case .text(let text):
            TextEditor(text: textBinding("Edit Text", \.string, default: ""))
                .font(.body)
                .frame(minHeight: 54, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                .focused($textFocused)
            Picker("Font", selection: textBinding("Font", \.fontName, default: "Helvetica Neue")) {
                if !Self.fontFamilies.contains(text.fontName) { Text(text.fontName).tag(text.fontName) }
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            slider("Size", value: textBinding("Font Size", \.fontSize, default: 64), in: 6...600, onEnd: endInteraction)
            HStack(spacing: 8) {
                Toggle(isOn: textBinding("Bold", \.isBold, default: false)) { Image(systemName: "bold") }
                    .toggleStyle(.button)
                Toggle(isOn: textBinding("Italic", \.isItalic, default: false)) { Image(systemName: "italic") }
                    .toggleStyle(.button)
                Picker("Alignment", selection: textBinding("Alignment", \.alignment, default: .left)) {
                    Image(systemName: "text.alignleft").tag(PixixEngine.TextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(PixixEngine.TextAlignment.center)
                    Image(systemName: "text.alignright").tag(PixixEngine.TextAlignment.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ColorPicker("Color", selection: colorBinding(textBinding("Text Color", \.color, default: .white)))
            slider("Outline", value: textBinding("Outline", \.outlineWidth, default: 0), in: 0...40, onEnd: endInteraction)
            if text.outlineWidth > 0 {
                ColorPicker("Outline color", selection: colorBinding(textBinding("Outline Color", \.outlineColor, default: .black)))
            }
            Toggle("Background", isOn: Binding(
                get: { text.background != nil },
                set: { on in
                    let value: RGBAColor? = on ? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6) : nil
                    textBinding("Background", \.background, default: nil).wrappedValue = value
                }
            ))
            if let background = text.background {
                ColorPicker("Background color", selection: colorBinding(Binding(
                    get: { background },
                    set: { textBinding("Background", \.background, default: nil).wrappedValue = $0 }
                )))
            }
            Button("Meme Style") { applyMemeStyle(layer) }
                .help("Impact, white with a black outline, centered")
        case .shape(let shape):
            ColorPicker("Color", selection: colorBinding(shapeBinding("Color", \.strokeColor, default: .black)))
            slider("Width", value: shapeBinding("Width", \.strokeWidth, default: 6), in: 0...120, onEnd: endInteraction)
            if shape.kind == .rectangle || shape.kind == .ellipse {
                Toggle("Fill", isOn: Binding(
                    get: { shape.fillColor != nil },
                    set: { shapeBinding("Fill", \.fillColor, default: nil).wrappedValue = $0 ? model.secondaryColor : nil }
                ))
                if let fill = shape.fillColor {
                    ColorPicker("Fill color", selection: colorBinding(Binding(
                        get: { fill }, set: { shapeBinding("Fill", \.fillColor, default: nil).wrappedValue = $0 }
                    )))
                }
            }
            if shape.kind == .rectangle {
                slider("Corners", value: shapeBinding("Corners", \.cornerRadius, default: 0), in: 0...300, onEnd: endInteraction)
            }
        case .effect:
            Picker("Effect", selection: regionBinding("Effect", \.effect, default: .blur)) {
                Text("Blur").tag(RegionEffect.blur)
                Text("Pixelate").tag(RegionEffect.pixelate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            slider("Strength", value: regionBinding("Strength", \.amount, default: 16), in: 2...200, onEnd: endInteraction)
            Toggle("Round", isOn: regionBinding("Shape", \.isEllipse, default: false))
        case .raster:
            EmptyView()
        }
        slider(
            "Opacity",
            value: layerBinding("Opacity", key: "opacity", default: 100, get: { $0.opacity * 100 }) { $0.opacity = $1 / 100 },
            in: 0...100, onEnd: endInteraction
        )
        Picker("Blend", selection: layerBinding("Blend Mode", key: "blend", default: .normal, get: { $0.blendMode }) { $0.blendMode = $1 }) {
            ForEach(BlendMode.allCases) { Text($0.title).tag($0) }
        }
    }

    private func applyMemeStyle(_ layer: Layer) {
        document.updateLayer(layer.id, name: "Meme Style") { layer in
            guard var text = layer.text else { return }
            text.fontName = "Impact"
            text.color = .white
            text.outlineColor = .black
            text.outlineWidth = max(2, (text.fontSize / 14).rounded())
            text.alignment = .center
            text.string = text.string.uppercased()
            text.isBold = false
            text.isItalic = false
            layer.content = .text(text)
            model.textDefaults = text
        }
    }

    // MARK: Adjustments

    private func adjustment(_ title: String, _ path: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double> = -100...100) -> some View {
        slider(
            title,
            value: layerBinding(title, key: "adjust-\(title)", default: 0, get: { $0.adjustments[keyPath: path] * 100 }) {
                $0.adjustments[keyPath: path] = $1 / 100
            },
            in: range, onEnd: endInteraction
        )
    }

    @ViewBuilder private func adjustments(_ layer: Layer) -> some View {
        Picker("Filter", selection: layerBinding("Filter", key: "filter", default: .none, get: { $0.filter }) { $0.filter = $1 }) {
            ForEach(PhotoFilter.allCases) { Text($0.title).tag($0) }
        }
        adjustment("Exposure", \.exposure)
        adjustment("Brightness", \.brightness)
        adjustment("Contrast", \.contrast)
        adjustment("Highlights", \.highlights)
        adjustment("Shadows", \.shadows)
        adjustment("Saturation", \.saturation)
        adjustment("Vibrance", \.vibrance)
        adjustment("Warmth", \.temperature)
        adjustment("Tint", \.tint)
        adjustment("Sharpness", \.sharpness, 0...100)
        adjustment("Vignette", \.vignette, 0...100)
        HStack {
            Button("Reset") {
                document.updateLayer(layer.id, name: "Reset Adjustments") {
                    $0.adjustments = Adjustments()
                    $0.filter = .none
                }
            }
            .disabled(layer.adjustments.isNeutral && layer.filter == .none)
            Spacer()
            if layer.isRaster {
                Button("Bake In") { document.applyAdjustments(layer.id) }
                    .disabled(layer.adjustments.isNeutral && layer.filter == .none)
                    .help("Apply the adjustments to the pixels and reset the sliders")
            }
        }
    }

    // MARK: Layers

    @ViewBuilder private var layers: some View {
        VStack(spacing: 1) {
            ForEach(document.layers.reversed()) { layer in
                let isActive = layer.id == document.activeLayerID
                HStack(spacing: 6) {
                    Button {
                        document.updateLayer(layer.id, name: layer.isVisible ? "Hide Layer" : "Show Layer") { $0.isVisible.toggle() }
                    } label: {
                        Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                            .frame(width: 16)
                            .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help(layer.isVisible ? "Hide layer" : "Show layer")
                    Image(systemName: layer.kindSymbol)
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
                    Text(layer.text.map { $0.string.isEmpty ? layer.name : $0.string.replacingOccurrences(of: "\n", with: " ") } ?? layer.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button {
                        document.updateLayer(layer.id, name: layer.isLocked ? "Unlock Layer" : "Lock Layer") { $0.isLocked.toggle() }
                    } label: {
                        Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                            .foregroundStyle(layer.isLocked ? .primary : .quaternary)
                    }
                    .buttonStyle(.borderless)
                    .help(layer.isLocked ? "Unlock layer" : "Lock layer")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(isActive ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { document.setActiveLayer(layer.id) }
            }
        }
        HStack(spacing: 4) {
            Button { document.addEmptyLayer() } label: { Image(systemName: "plus") }
                .help("New empty layer")
            Button { editor.host.addImageLayer(nil) } label: { Image(systemName: "photo.badge.plus") }
                .help("Add a picture as a layer")
            Button { document.activeLayerID.map { document.duplicateLayer($0) } } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate layer")
            Button { document.activeLayerID.map { document.moveLayer($0, by: 1) } } label: { Image(systemName: "arrow.up") }
                .disabled((document.activeIndex ?? Int.max) >= document.layers.count - 1)
                .help("Move layer up")
            Button { document.activeLayerID.map { document.moveLayer($0, by: -1) } } label: { Image(systemName: "arrow.down") }
                .disabled((document.activeIndex ?? 0) <= 0)
                .help("Move layer down")
            Button { document.activeLayerID.map { document.mergeDown($0) } } label: { Image(systemName: "arrow.down.to.line") }
                .disabled((document.activeIndex ?? 0) <= 0)
                .help("Merge into the layer below")
            Spacer(minLength: 0)
            Button(role: .destructive) { document.activeLayerID.map { document.removeLayer($0) } } label: { Image(systemName: "trash") }
                .disabled(document.layers.count <= 1)
                .help("Delete layer")
        }
    }

    // MARK: History

    @ViewBuilder private var history: some View {
        let entries = document.history.entries
        let position = document.history.position
        VStack(alignment: .leading, spacing: 1) {
            historyRow("Opened", isCurrent: position == 0, isUndone: false) { document.history.jump(to: 0) }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                historyRow(entry.name, isCurrent: position == index + 1, isUndone: index >= position) {
                    document.history.jump(to: index + 1)
                }
            }
        }
    }

    private func historyRow(_ name: String, isCurrent: Bool, isUndone: Bool, action: @escaping () -> Void) -> some View {
        Text(name)
            .lineLimit(1)
            .foregroundStyle(isUndone ? .tertiary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isCurrent ? Color.accentColor.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

/// The strip of tool buttons on the left.
struct ToolPaletteView: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(Array(ToolKind.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider().padding(.vertical, 4).padding(.horizontal, 8)
                    }
                    ForEach(group) { tool in
                        Button { model.tool = tool } label: {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 15))
                                .frame(width: 34, height: 30)
                                .background(
                                    model.tool == tool ? Color.accentColor.opacity(0.75) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tool.help)
                        .accessibilityLabel(tool.title)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 46)
        .background(Color(nsColor: NSColor(white: 0.15, alpha: 1)))
    }
}
