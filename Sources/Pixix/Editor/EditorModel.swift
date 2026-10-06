import AppKit
import Observation
import PixixCodec
import PixixEngine
import SwiftUI

/// SwiftUI has a `Document` of its own; in this app the word always means the image document.
typealias Document = PixixEngine.Document

enum ToolKind: String, CaseIterable, Identifiable {
    case move, crop
    case selectRectangle, selectEllipse, lasso, wand
    case brush, pencil, eraser, clone, fill, gradient, picker
    case text, arrow, line, rectangle, ellipse, pen, highlighter
    case blurRegion, pixelateRegion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: "Move"
        case .crop: "Crop"
        case .selectRectangle: "Rectangle Select"
        case .selectEllipse: "Ellipse Select"
        case .lasso: "Lasso"
        case .wand: "Magic Wand"
        case .brush: "Brush"
        case .pencil: "Pencil"
        case .eraser: "Eraser"
        case .clone: "Clone Stamp"
        case .fill: "Paint Bucket"
        case .gradient: "Gradient"
        case .picker: "Color Picker"
        case .text: "Text"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .blurRegion: "Blur Area"
        case .pixelateRegion: "Pixelate Area"
        }
    }

    var symbol: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .crop: "crop"
        case .selectRectangle: "rectangle.dashed"
        case .selectEllipse: "circle.dashed"
        case .lasso: "lasso"
        case .wand: "wand.and.stars"
        case .brush: "paintbrush.pointed"
        case .pencil: "pencil"
        case .eraser: "eraser"
        case .clone: "circle.circle"
        case .fill: "paintbrush"
        case .gradient: "square.lefthalf.filled"
        case .picker: "eyedropper"
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .blurRegion: "drop"
        case .pixelateRegion: "square.grid.3x3"
        }
    }

    /// The single key that picks the tool, as in most editors.
    var shortcut: Character? {
        switch self {
        case .move: "v"
        case .crop: "c"
        case .selectRectangle: "m"
        case .selectEllipse: "o"
        case .lasso: "l"
        case .wand: "w"
        case .brush: "b"
        case .pencil: "n"
        case .eraser: "e"
        case .clone: "s"
        case .fill: "g"
        case .gradient: "d"
        case .picker: "i"
        case .text: "t"
        case .arrow: "a"
        case .line: "\\"
        case .rectangle: "r"
        case .ellipse: "u"
        case .pen: "p"
        case .highlighter: "h"
        case .blurRegion: "j"
        case .pixelateRegion: "k"
        }
    }

    var help: String {
        if let shortcut { return "\(title) (\(String(shortcut).uppercased()))" }
        return title
    }

    /// Tools grouped the way the palette shows them.
    static let groups: [[ToolKind]] = [
        [.move, .crop],
        [.selectRectangle, .selectEllipse, .lasso, .wand],
        [.brush, .pencil, .eraser, .clone, .fill, .gradient, .picker],
        [.text, .arrow, .line, .rectangle, .ellipse, .pen, .highlighter],
        [.blurRegion, .pixelateRegion],
    ]

    var shapeKind: ShapeKind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .freehand
        case .highlighter: .highlighter
        default: nil
        }
    }

    var isPaintTool: Bool { [.brush, .pencil, .eraser, .clone].contains(self) }
    var isSelectionTool: Bool { [.selectRectangle, .selectEllipse, .lasso, .wand].contains(self) }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9, r3x4, r2x3, r9x16, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1 : 1"
        case .r4x3: "4 : 3"
        case .r3x2: "3 : 2"
        case .r16x9: "16 : 9"
        case .r3x4: "3 : 4"
        case .r2x3: "2 : 3"
        case .r9x16: "9 : 16"
        case .custom: "Custom"
        }
    }

    var fixedRatio: CGFloat? {
        switch self {
        case .square: 1
        case .r4x3: 4.0 / 3
        case .r3x2: 3.0 / 2
        case .r16x9: 16.0 / 9
        case .r3x4: 3.0 / 4
        case .r2x3: 2.0 / 3
        case .r9x16: 9.0 / 16
        default: nil
        }
    }
}

enum EditorDialog: Identifiable {
    case resize, canvasSize
    case effect(EffectDescriptor)

    var id: String {
        switch self {
        case .resize: "resize"
        case .canvasSize: "canvas"
        case .effect(let effect): "effect-\(effect.id)"
        }
    }
}

/// What the editor's panels show and change. Tools read their settings from here.
@MainActor
@Observable
final class EditorModel {
    @ObservationIgnored weak var controller: EditorController?

    var tool = ToolKind.move {
        didSet { if tool != oldValue { controller?.toolDidChange(from: oldValue) } }
    }

    /// Bumped whenever the document changes, so panels that read it refresh.
    var revision = 0

    var primaryColor = RGBAColor(red: 0.9, green: 0.16, blue: 0.13)
    var secondaryColor = RGBAColor.white

    // Painting
    var brushSize = 24.0
    var brushHardness = 0.85
    var brushOpacity = 1.0

    // Selecting and filling
    var tolerance = 20.0
    var contiguous = true
    var sampleAllLayers = false
    var selectionMode = SelectionCombine.replace
    var feather = 0.0
    var gradientIsRadial = false

    // Shapes
    var strokeWidth = 6.0
    var fillsShapes = false
    var cornerRadius = 0.0
    var regionAmount = 18.0

    // Text for new layers
    var textDefaults = TextContent()

    // Crop
    var cropAspect = CropAspect.free { didSet { controller?.cropSettingsDidChange() } }
    var customAspectWidth = 5.0 { didSet { controller?.cropSettingsDidChange() } }
    var customAspectHeight = 4.0 { didSet { controller?.cropSettingsDidChange() } }
    /// Degrees.
    var straighten = 0.0 { didSet { controller?.cropSettingsDidChange() } }
    var cropRect = CGRect.zero

    // Dialog state. Kept here because the @State macro needs a compiler plugin that only ships with Xcode.
    var resizeWidth = 0
    var resizeHeight = 0
    var resizeKeepsAspect = true
    var canvasWidth = 0
    var canvasHeight = 0
    var canvasAnchor = CGPoint(x: 0.5, y: 0.5)
    var effectValues: [String: Double] = [:]
    var focusesTextEditor = false
    var expandedSections: Set<String> = ["tool", "layer", "adjust", "layers"]

    func isExpanded(_ section: String) -> Binding<Bool> {
        Binding(
            get: { self.expandedSections.contains(section) },
            set: { open in
                if open { self.expandedSections.insert(section) } else { self.expandedSections.remove(section) }
            }
        )
    }

    func swapColors() {
        swap(&primaryColor, &secondaryColor)
    }
}

extension RGBAColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(
            red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue),
            alpha: Double(resolved.opacity)
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
