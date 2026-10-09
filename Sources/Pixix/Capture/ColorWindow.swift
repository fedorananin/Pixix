import AppKit
import Observation
import PixixCodec
import PixixEngine
import SwiftUI

/// What the color window shows.
@MainActor
@Observable
final class ColorWindowModel {
    var color: RGBAColor
    var notations: [ColorNotation]
    var bareHex: Bool
    /// The notation copied a moment ago, so its button can say so.
    var copied: ColorNotation?
    /// False for a window made only to be photographed: its buttons then leave the clipboard and the screen alone.
    @ObservationIgnored var isLive = true

    init(color: RGBAColor) {
        self.color = color
        notations = Settings.shared.pickerNotations
        bareHex = Settings.shared.pickerBareHex
    }

    /// The color as the window shows it and as its button copies it.
    func text(_ notation: ColorNotation) -> String {
        notation.text(of: color, bareHex: bareHex)
    }

    func copy(_ notation: ColorNotation) {
        guard isLive else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(notation), forType: .string)
        copied = notation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copied == notation { self?.copied = nil }
        }
    }

    func pickAnother() {
        guard isLive else { return }
        CaptureAgent.shared.pickColorForWindow()
    }
}

struct ColorWindowView: View {
    @Bindable var model: ColorWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(cgColor: model.color.cgColor))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.18)))
                .frame(height: 56)
            VStack(spacing: 4) {
                ForEach(model.notations) { notation in
                    HStack(spacing: 8) {
                        Text(verbatim: notation.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .leading)
                        Text(verbatim: model.text(notation))
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            model.copy(notation)
                        } label: {
                            Image(systemName: model.copied == notation ? "checkmark" : "doc.on.doc")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy \(notation.name)")
                    }
                    .frame(height: 24)
                }
            }
            Button {
                model.pickAnother()
            } label: {
                Label("Pick Another", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 330)
        .fixedSize()
    }
}

/// A small window that keeps a picked color on screen, written in every notation, each with a button to copy
/// it. It floats over the other apps, takes no Dock icon and does not take the keyboard from the app in front.
@MainActor
final class ColorWindowController {
    private static var shared: ColorWindowController?

    let panel: NSPanel
    let model: ColorWindowModel

    init(color: RGBAColor) {
        model = ColorWindowModel(color: color)
        panel = NSPanel(
            contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered,
            defer: false
        )
        panel.title = "Color"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        let hosting = NSHostingView(rootView: ColorWindowView(model: model))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
    }

    /// Shows a color in the window, opening it beside the pixel it came from. A window that is already up
    /// stays where the user put it.
    static func show(_ color: RGBAColor, near point: NSPoint) {
        if let shared, shared.panel.isVisible {
            shared.model.color = color
            shared.model.notations = Settings.shared.pickerNotations
            shared.model.bareHex = Settings.shared.pickerBareHex
            shared.model.copied = nil
            // Once the rows have been laid out again.
            DispatchQueue.main.async { shared.fit() }
            shared.panel.orderFrontRegardless()
            return
        }
        let controller = ColorWindowController(color: color)
        shared = controller
        let size = controller.panel.frame.size
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x + 24, y: point.y - 24 - size.height)
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.maxX - size.width - 8, visible.minX + 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.maxY - size.height - 8, visible.minY + 8))
        controller.panel.setFrameOrigin(origin)
        controller.panel.orderFrontRegardless()
    }

    /// Takes the height the rows need, keeping the title bar where it is.
    private func fit() {
        guard let hosting = panel.contentView else { return }
        let top = panel.frame.maxY
        panel.setContentSize(hosting.fittingSize)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
    }
}
