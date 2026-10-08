import AppKit
import VisionKit

/// Lets text in the picture be selected and copied, the way Preview does. Recognition is the system's:
/// VisionKit finds the text and draws the selection, and this class keeps its view over the picture.
@MainActor
final class LiveTextController: NSObject, ImageAnalysisOverlayViewDelegate {
    private unowned let canvas: CanvasView
    private let analyzer = ImageAnalyzer()
    private let overlay = ImageAnalysisOverlayView()
    private let container = LiveTextContainer()
    private var task: Task<Void, Never>?

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init()
        overlay.delegate = self
        overlay.preferredInteractionTypes = .automatic
        // The picture has enough controls on it already.
        overlay.isSupplementaryInterfaceHidden = true
        container.overlay = overlay
        container.addSubview(overlay)
        container.isHidden = true
        // Under the layer the tools draw on, over the picture.
        canvas.addSubview(container, positioned: .below, relativeTo: nil)
    }

    /// True once the picture has been read and its text can be selected.
    var isReady: Bool { overlay.analysis != nil }
    /// All the text that was found, for diagnostics.
    var transcript: String { overlay.analysis?.transcript ?? "" }
    var selectedText: String? { overlay.hasActiveTextSelection ? overlay.selectedText : nil }

    /// Shows where the text is without anyone selecting it.
    func highlightAll(_ on: Bool) {
        overlay.selectableItemsHighlighted = on
    }

    func analyze(_ image: CGImage) {
        clear()
        guard ImageAnalyzer.isSupported else { return }
        task = Task { [weak self, analyzer] in
            // Flipping through a folder should not start a recognition per picture.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration)
            guard let self, !Task.isCancelled, let analysis else { return }
            self.overlay.analysis = analysis
            self.container.isHidden = false
            self.layout()
        }
    }

    func clear() {
        task?.cancel()
        task = nil
        overlay.analysis = nil
        container.isHidden = true
    }

    /// Keeps the recognized text over the picture as it is zoomed and panned.
    func layout() {
        guard !container.isHidden else { return }
        container.frame = canvas.imageRect
        overlay.frame = container.bounds
        overlay.setContentsRectNeedsUpdate()
    }

    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}

/// Lets clicks through to the picture everywhere except on text, so panning, zooming and dragging the
/// window by the picture keep working.
private final class LiveTextContainer: NSView {
    weak var overlay: ImageAnalysisOverlayView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let overlay, !isHidden, let superview else { return nil }
        let local = overlay.convert(point, from: superview)
        // With text selected, a click anywhere belongs to the overlay: that is how the selection is dropped.
        guard overlay.hasActiveTextSelection || overlay.hasInteractiveItem(at: local) else { return nil }
        return super.hitTest(point)
    }
}
