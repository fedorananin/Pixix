import AppKit
import Observation
import PixixCodec
import PixixEngine

/// Proportions the selection is held to.
struct CaptureAspect: Hashable {
    var width: Int
    var height: Int

    var ratio: CGFloat { CGFloat(width) / CGFloat(max(height, 1)) }
    var title: String { "\(width) : \(height)" }
    var storage: String { "\(width):\(height)" }

    init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    init?(storage: String?) {
        let parts = (storage ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        self.init(width: parts[0], height: parts[1])
    }

    /// The proportions of a size in their lowest terms: 1920 × 1080 is 16 : 9.
    init(reducing size: CGSize) {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let w = max(Int(size.width.rounded()), 1), h = max(Int(size.height.rounded()), 1)
        let divisor = max(gcd(w, h), 1)
        self.init(width: w / divisor, height: h / divisor)
    }

    static let presets = [(1, 1), (4, 3), (3, 2), (16, 9), (3, 4), (2, 3), (9, 16)].map { CaptureAspect(width: $0.0, height: $0.1) }
}

/// A ready-made size in pixels.
struct CaptureSize: Hashable, Identifiable {
    var name: String
    var width: Int
    var height: Int

    var id: String { name }

    static let presets = [
        CaptureSize(name: "Full HD", width: 1920, height: 1080),
        CaptureSize(name: "HD", width: 1280, height: 720),
        CaptureSize(name: "Instagram post", width: 1080, height: 1080),
        CaptureSize(name: "Instagram portrait", width: 1080, height: 1350),
        CaptureSize(name: "Stories, Shorts", width: 1080, height: 1920),
        CaptureSize(name: "X post", width: 1200, height: 675),
        CaptureSize(name: "LinkedIn post", width: 1200, height: 627),
    ]
}

/// The markup tools of the panel beside a selection. A group shares one button; the rest are a click further.
enum CaptureToolGroup: String, CaseIterable, Identifiable {
    case pointer, arrow, draw, shape, hide, text, badge

    var id: String { rawValue }

    var tools: [ToolKind] {
        switch self {
        case .pointer: [.move]
        case .arrow: [.arrow, .line]
        case .draw: [.pen, .highlighter]
        case .shape: [.rectangle, .ellipse]
        case .hide: [.pixelateRegion, .blurRegion]
        case .text: [.text]
        case .badge: [.badge]
        }
    }

    static let allTools = allCases.flatMap(\.tools)

    static func group(of tool: ToolKind) -> CaptureToolGroup? {
        allCases.first { $0.tools.contains(tool) }
    }
}

enum CaptureFlyout: Equatable {
    case tools(CaptureToolGroup)
    case color
}

/// What the panels around a selection show. The tool, color and line width live in the editor's own model.
@MainActor
@Observable
final class CaptureModel {
    @ObservationIgnored weak var screen: CaptureScreenController?

    /// The selection in pixels. The fields of the size label edit these; the screen applies them.
    var width = 0
    var height = 0

    var aspect = CaptureAspect(storage: Settings.shared.captureAspect) {
        didSet {
            guard aspect != oldValue else { return }
            if screen?.session.isUnattended != true { Settings.shared.captureAspect = aspect?.storage }
            screen?.aspectDidChange()
        }
    }

    var flyout: CaptureFlyout?
    /// The tool each group's button stands for: the one used last.
    var chosen: [CaptureToolGroup: ToolKind] = [:]
    /// What the button under the pointer does. Tooltips of the system open under the overlay, so the panels
    /// say it themselves: `place` is the row or the panel the words belong beside.
    var hint: (place: String, text: String)?
    /// A line next to the buttons: what is going on, or what went wrong.
    var status: String?
    var isBusy = false

    func tool(of group: CaptureToolGroup) -> ToolKind {
        chosen[group] ?? group.tools[0]
    }

    static let palette: [RGBAColor] = [
        RGBAColor(red: 0.93, green: 0.18, blue: 0.16), RGBAColor(red: 1, green: 0.58, blue: 0),
        RGBAColor(red: 1, green: 0.84, blue: 0.04), RGBAColor(red: 0.2, green: 0.78, blue: 0.35),
        RGBAColor(red: 0.04, green: 0.52, blue: 1), RGBAColor(red: 0.69, green: 0.32, blue: 0.87),
        .white, .black,
    ]

    /// Line widths in points.
    static let lineWidths: [Double] = [2, 3, 5, 8]
}
