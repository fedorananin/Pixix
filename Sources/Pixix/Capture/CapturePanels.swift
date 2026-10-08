import PixixCodec
import PixixEngine
import SwiftUI

private let panelColor = Color(nsColor: NSColor(white: 0.13, alpha: 0.96))

/// Reports the pointer coming over a control and leaving it. SwiftUI's own `onHover` listens only in the
/// active app, and during a capture the app in front may well be another one; this listens always.
final class HoverView: NSView {
    var onChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    /// Clicks are for the control underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}

private struct HoverArea: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: HoverView, context: Context) {
        view.onChange = onChange
    }
}

/// Says what a control does while the pointer is over it.
private struct Hinted: ViewModifier {
    let model: CaptureModel
    let place: String
    let text: String

    func body(content: Content) -> some View {
        content.background(HoverArea { inside in
            if inside {
                model.hint = (place, text)
            } else if model.hint?.text == text {
                model.hint = nil
            }
        })
    }
}

private extension View {
    func hint(_ text: String, in place: String, _ model: CaptureModel) -> some View {
        modifier(Hinted(model: model, place: place, text: text))
    }
}

/// The words of a hint, in a dark tag of their own.
private struct HintTag: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(panelColor, in: RoundedRectangle(cornerRadius: 7))
            .allowsHitTesting(false)
    }
}

/// A button of the panels: a symbol in a square that lights up while its tool is in use.
private struct PanelButton: View {
    let symbol: String
    var isOn = false
    var isEnabled = true
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
                .frame(width: 34, height: 30)
                .background(isOn ? Color.accentColor.opacity(0.8) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The small corner that says a button has more tools behind it.
private struct MoreCorner: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 5, y: 0))
            path.addLine(to: CGPoint(x: 5, y: 5))
            path.addLine(to: CGPoint(x: 0, y: 5))
            path.closeSubpath()
        }
        .fill(.white.opacity(0.75))
        .frame(width: 5, height: 5)
        .padding(3)
        .allowsHitTesting(false)
    }
}

/// The markup tools, in a column beside the selection. Groups open a strip of their tools to the left.
struct CaptureToolsView: View {
    @Bindable var model: CaptureModel
    @Bindable var tools: EditorModel
    let screen: CaptureScreenController

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(CaptureToolGroup.allCases) { group in
                HStack(spacing: 9) {
                    hintTag(for: group.rawValue)
                    if model.flyout == .tools(group) {
                        strip {
                            ForEach(group.tools) { tool in
                                PanelButton(symbol: tool.symbol, isOn: tools.tool == tool, help: tool.help) {
                                    screen.choose(tool, in: group)
                                }
                                .hint(tool.help, in: group.rawValue, model)
                            }
                        }
                    }
                    PanelButton(
                        symbol: model.tool(of: group).symbol, isOn: group.tools.contains(tools.tool),
                        help: model.tool(of: group).help
                    ) {
                        screen.choose(group)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if group.tools.count > 1 { MoreCorner() }
                    }
                    .hint(groupHint(group), in: group.rawValue, model)
                }
            }
            HStack(spacing: 9) {
                hintTag(for: "color")
                if model.flyout == .color {
                    strip {
                        ForEach(CaptureModel.palette, id: \.self) { color in
                            Button { screen.setColor(color) } label: {
                                swatch(color, isOn: color == tools.primaryColor).frame(width: 24, height: 30)
                            }
                            .buttonStyle(.plain)
                        }
                        Divider().frame(height: 18).padding(.horizontal, 3)
                        ForEach(CaptureModel.lineWidths, id: \.self) { width in
                            Button { screen.setLineWidth(width) } label: {
                                Circle()
                                    .fill(.white.opacity(screen.lineWidth == width ? 1 : 0.45))
                                    .frame(width: 4 + width * 1.6, height: 4 + width * 1.6)
                                    .frame(width: 24, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hint("Line width", in: "color", model)
                        }
                    }
                }
                Button { model.flyout = model.flyout == .color ? nil : .color } label: {
                    swatch(tools.primaryColor, isOn: false).frame(width: 34, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottomTrailing) { MoreCorner() }
                .hint("Color and line width", in: "color", model)
            }
            HStack(spacing: 9) {
                hintTag(for: "undo")
                // Reading the revision keeps the button in step with the history.
                PanelButton(
                    symbol: "arrow.uturn.backward", isEnabled: tools.revision >= 0 && screen.canUndo, help: "Undo (⌘Z)"
                ) {
                    screen.undo()
                }
                .hint("Undo (⌘Z)", in: "undo", model)
            }
        }
        .padding(5)
        .background(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 10).fill(panelColor).frame(width: 44)
        }
        .environment(\.colorScheme, .dark)
    }

    /// The hint of a row, to the left of everything else in it.
    @ViewBuilder private func hintTag(for place: String) -> some View {
        if let hint = model.hint, hint.place == place { HintTag(text: hint.text) }
    }

    /// A group's button stands for one tool and hides the others; the hint says so.
    private func groupHint(_ group: CaptureToolGroup) -> String {
        let tool = model.tool(of: group)
        guard group.tools.count > 1 else { return tool.help }
        let others = group.tools.filter { $0 != tool }.map(\.title).joined(separator: ", ")
        return "\(tool.help) · click again for \(others)"
    }

    private func strip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 2, content: content)
            .padding(.horizontal, 4)
            // Drawn past its own bounds, so the row keeps its height when the strip opens.
            .background { RoundedRectangle(cornerRadius: 9).fill(panelColor).padding(.vertical, -4) }
    }

    private func swatch(_ color: RGBAColor, isOn: Bool) -> some View {
        Circle()
            .fill(color.color)
            .frame(width: 17, height: 17)
            .overlay { Circle().strokeBorder(.white.opacity(isOn ? 1 : 0.45), lineWidth: isOn ? 2 : 1) }
    }
}

/// What can be done with the selection, in a row under it.
struct CaptureActionsView: View {
    @Bindable var model: CaptureModel
    let screen: CaptureScreenController

    var body: some View {
        HStack(spacing: 2) {
            // What is going on comes first; otherwise the line says what the button under the pointer does.
            if let line = model.status ?? (model.hint?.place == "actions" ? model.hint?.text : nil) {
                Text(verbatim: line)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
            }
            button("square.and.pencil", "Open in the Editor (⌘E)") { screen.openInEditor() }
            button("text.viewfinder", "Copy the Text (⇧⌘C)", isEnabled: !model.isBusy) { screen.copyText() }
            button("square.and.arrow.down", "Save to \(screen.saveFolderName) (⌘S) · Save As (⇧⌘S)") { screen.save() }
            button("doc.on.doc", "Copy (⌘C or Return)") { screen.copyImage() }
            button("xmark", "Close (Esc)") { screen.cancel() }
        }
        .padding(5)
        .background(panelColor, in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }

    private func button(_ symbol: String, _ help: String, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        PanelButton(symbol: symbol, isEnabled: isEnabled, help: help, action: action).hint(help, in: "actions", model)
    }
}

/// The size of the selection in pixels, at its top-left corner. The numbers can be typed over, and the
/// menu sets proportions and ready-made sizes.
struct CaptureSizeView: View {
    @Bindable var model: CaptureModel
    let screen: CaptureScreenController

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Section("Proportions") {
                    choice("Free", isOn: model.aspect == nil) { model.aspect = nil }
                    ForEach(CaptureAspect.presets, id: \.self) { aspect in
                        choice(aspect.title, isOn: model.aspect == aspect) { model.aspect = aspect }
                    }
                    Button("Keep These Proportions") { screen.lockProportions() }
                }
                Section("Size in Pixels") {
                    ForEach(CaptureSize.presets) { size in
                        Button { screen.apply(size) } label: {
                            Text(verbatim: "\(size.width) × \(size.height)  —  \(size.name)")
                        }
                    }
                    Button("Whole Screen") { screen.selectWholeScreen() }
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hint("Proportions and ready-made sizes", in: "size", model)

            field($model.width, alignment: .trailing)
            Text(verbatim: "×").foregroundStyle(.white.opacity(0.7))
            field($model.height, alignment: .leading)
            if let aspect = model.aspect {
                Text(verbatim: aspect.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.leading, 2)
            }
            if let hint = model.hint, hint.place == "size" {
                Text(verbatim: hint.text).foregroundStyle(.white.opacity(0.85)).fixedSize().padding(.leading, 6)
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(panelColor, in: RoundedRectangle(cornerRadius: 7))
        .environment(\.colorScheme, .dark)
    }

    private func choice(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
        }
    }

    private func field(_ value: Binding<Int>, alignment: SwiftUI.TextAlignment) -> some View {
        TextField("", value: value, format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .foregroundStyle(.white)
            .frame(width: 40)
            .hint("Width and height in pixels: type a number, then Return", in: "size", model)
            .onSubmit { screen.applyTypedSize() }
            .onExitCommand { screen.focusCanvas() }
    }
}
