import CoreGraphics
import Foundation
import PixixCodec
import Testing
@testable import PixixEngine

/// Four quadrants: red top-left, green top-right, blue bottom-left, white bottom-right.
func quadrantImage(width: Int = 64, height: Int = 48) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let w = CGFloat(width) / 2, h = CGFloat(height) / 2
    // Core Graphics has a bottom-left origin, so "top" is the upper half in y.
    // Colors are spelled out in sRGB: CGColor(red:green:blue:alpha:) means Generic RGB and would be converted.
    func fill(_ color: RGBAColor, _ rect: CGRect) {
        context.setFillColor(color.cgColor)
        context.fill(rect)
    }
    fill(RGBAColor(red: 1, green: 0, blue: 0), CGRect(x: 0, y: h, width: w, height: h))
    fill(RGBAColor(red: 0, green: 1, blue: 0), CGRect(x: w, y: h, width: w, height: h))
    fill(RGBAColor(red: 0, green: 0, blue: 1), CGRect(x: 0, y: 0, width: w, height: h))
    fill(RGBAColor(red: 1, green: 1, blue: 1), CGRect(x: w, y: 0, width: w, height: h))
    return context.makeImage()!
}

func solidImage(width: Int, height: Int, _ color: RGBAColor) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

struct Pixel: Equatable, CustomStringConvertible {
    var r: Int, g: Int, b: Int, a: Int
    var description: String { "(\(r),\(g),\(b),\(a))" }

    func isClose(to other: Pixel, tolerance: Int = 3) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
    }

    static let red = Pixel(r: 255, g: 0, b: 0, a: 255)
    static let green = Pixel(r: 0, g: 255, b: 0, a: 255)
    static let blue = Pixel(r: 0, g: 0, b: 255, a: 255)
    static let white = Pixel(r: 255, g: 255, b: 255, a: 255)
    static let clear = Pixel(r: 0, g: 0, b: 0, a: 0)
}

@MainActor
func pixel(_ document: Document, _ x: Int, _ y: Int) -> Pixel {
    let bytes = document.pixels()
    let offset = (y * Int(document.size.width) + x) * 4
    return Pixel(r: Int(bytes[offset + 2]), g: Int(bytes[offset + 1]), b: Int(bytes[offset]), a: Int(bytes[offset + 3]))
}

/// Saves a render for a human to look at, when PIXIX_TEST_OUTPUT names a folder.
@MainActor
func dump(_ document: Document, _ name: String) {
    guard let folder = ProcessInfo.processInfo.environment["PIXIX_TEST_OUTPUT"], let image = document.flattenedImage(),
          let data = try? ImageEncoder.encode(image, format: .png, quality: 1)
    else { return }
    try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
}

@MainActor
@Suite struct RenderingTests {
    @Test func compositeKeepsOrientationAndColor() throws {
        let document = try #require(Document(image: quadrantImage()))
        #expect(document.size == CGSize(width: 64, height: 48))
        #expect(pixel(document, 2, 2) == .red)
        #expect(pixel(document, 60, 2) == .green)
        #expect(pixel(document, 2, 45) == .blue)
        #expect(pixel(document, 60, 45) == .white)
        // The flattened image must be the right way up as well.
        let flat = try #require(document.flattenedImage())
        let again = try #require(Document(image: flat))
        #expect(pixel(again, 2, 2) == .red)
        #expect(pixel(again, 60, 45) == .white)
    }

    @Test func partialRenderMatchesFullRender() throws {
        let document = try #require(Document(image: quadrantImage()))
        let target = try #require(PixelBuffer(width: 64, height: 48, colorSpace: document.colorSpace))
        document.renderer.render(document.composite(), to: target.surface, documentSize: document.size)
        // Change a patch in the top-left corner and redraw only that patch.
        document.fill(with: .white)
        let dirty = CGRect(x: 4, y: 6, width: 10, height: 8)
        document.renderer.render(document.composite(), to: target.surface, documentSize: document.size, rect: dirty)
        #expect(target.pixel(x: 8, y: 10)! == (255, 255, 255, 255))
        #expect(target.pixel(x: 20, y: 10)! == (0, 0, 255, 255)) // still red, in BGRA order
        #expect(target.pixel(x: 8, y: 40)! == (255, 0, 0, 255)) // still blue
    }

    @Test func layerTransformPlacesPixels() throws {
        let document = Document(size: CGSize(width: 100, height: 80), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let id = try #require(document.addImageLayer(quadrantImage(width: 20, height: 20), name: "Q", center: CGPoint(x: 50, y: 40)))
        #expect(pixel(document, 5, 5) == .clear)
        #expect(pixel(document, 42, 32) == .red)
        #expect(pixel(document, 58, 48) == .white)
        document.updateLayer(id, name: "Move") { $0.transform = $0.transform.concatenating(CGAffineTransform(translationX: 30, y: 0)) }
        #expect(pixel(document, 42, 32) == .clear)
        #expect(pixel(document, 72, 32) == .red)
        // Doubling about the layer's top-left corner keeps that corner where it is.
        document.updateLayer(id, name: "Scale") { $0.scale(x: 2, y: 2, aboutLocal: .zero) }
        #expect(document.layer(id)!.documentBounds == CGRect(x: 70, y: 30, width: 40, height: 40))
        #expect(pixel(document, 75, 35) == .red)
        #expect(pixel(document, 95, 65) == .white)
    }

    @Test func largeImagesAreShrunkToFitWhenAdded() throws {
        let document = Document(size: CGSize(width: 100, height: 100), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let id = try #require(document.addImageLayer(solidImage(width: 400, height: 200, .white), name: "Big"))
        #expect(document.layer(id)!.documentBounds == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func blendModesAndOpacity() throws {
        let document = try #require(Document(image: solidImage(width: 8, height: 8, RGBAColor(red: 1, green: 0.5, blue: 0))))
        let id = try #require(document.addImageLayer(solidImage(width: 8, height: 8, RGBAColor(red: 0.5, green: 0.5, blue: 1)), name: "Top"))
        #expect(pixel(document, 4, 4).isClose(to: Pixel(r: 128, g: 128, b: 255, a: 255)))
        document.updateLayer(id, name: "Blend") { $0.blendMode = .multiply }
        #expect(pixel(document, 4, 4).isClose(to: Pixel(r: 128, g: 64, b: 0, a: 255)))
        document.updateLayer(id, name: "Blend") {
            $0.blendMode = .normal
            $0.opacity = 0.5
        }
        #expect(pixel(document, 4, 4).isClose(to: Pixel(r: 191, g: 128, b: 128, a: 255)))
        document.updateLayer(id, name: "Hide") { $0.isVisible = false }
        #expect(pixel(document, 4, 4).isClose(to: Pixel(r: 255, g: 128, b: 0, a: 255)))
    }
}

@MainActor
@Suite struct GeometryTests {
    @Test func cropCutsAndExtends() throws {
        let document = try #require(Document(image: quadrantImage()))
        document.crop(to: CGRect(x: 32, y: 0, width: 32, height: 24))
        #expect(document.size == CGSize(width: 32, height: 24))
        #expect(pixel(document, 3, 3) == .green)
        document.undo()
        #expect(document.size == CGSize(width: 64, height: 48))
        // A frame reaching past the bottom edge extends the canvas with transparency.
        document.crop(to: CGRect(x: 0, y: 0, width: 64, height: 96))
        #expect(document.size == CGSize(width: 64, height: 96))
        #expect(pixel(document, 2, 45) == .blue)
        #expect(pixel(document, 2, 70) == .clear)
    }

    @Test func rotateAndFlip() throws {
        let document = try #require(Document(image: quadrantImage()))
        document.rotate(quarterTurns: 1)
        #expect(document.size == CGSize(width: 48, height: 64))
        // Clockwise: the red top-left quadrant ends up top-right, blue comes to the top-left.
        #expect(pixel(document, 45, 2) == .red)
        #expect(pixel(document, 2, 2) == .blue)
        #expect(pixel(document, 45, 60) == .green)
        document.rotate(quarterTurns: -1)
        #expect(pixel(document, 2, 2) == .red)
        document.flip(horizontal: true)
        #expect(pixel(document, 2, 2) == .green)
        document.flip(horizontal: false)
        #expect(pixel(document, 2, 2) == .white)
        document.rotate(quarterTurns: 2)
        #expect(pixel(document, 2, 2) == .red)
    }

    @Test func resizeStretchesAndCanvasSizeAnchors() throws {
        let document = try #require(Document(image: quadrantImage()))
        document.resize(to: CGSize(width: 128, height: 24))
        #expect(document.size == CGSize(width: 128, height: 24))
        #expect(pixel(document, 10, 3) == .red)
        #expect(pixel(document, 120, 20) == .white)
        document.undo()
        document.setCanvasSize(CGSize(width: 84, height: 68), anchor: CGPoint(x: 1, y: 1))
        #expect(pixel(document, 2, 2) == .clear)
        #expect(pixel(document, 22, 22) == .red)
        #expect(pixel(document, 82, 66) == .white)
    }

    @Test func straightenTurnsThePicture() throws {
        let document = try #require(Document(image: quadrantImage(width: 60, height: 60)))
        // A frame tilted by a quarter turn is the same as rotating the picture the other way.
        document.crop(to: CGRect(x: 0, y: 0, width: 60, height: 60), angle: .pi / 2)
        #expect(pixel(document, 5, 5) == .green)
        #expect(pixel(document, 5, 55) == .red)
    }
}

@MainActor
@Suite struct PaintingTests {
    @Test func brushStrokePaintsAndUndoes() throws {
        let document = try #require(Document(image: solidImage(width: 60, height: 40, .white)))
        var settings = BrushSettings()
        settings.size = 10
        settings.hardness = 1
        settings.color = RGBAColor(red: 1, green: 0, blue: 0)
        let stroke = try #require(BrushStroke(document: document, settings: settings))
        stroke.move(to: CGPoint(x: 10, y: 10))
        stroke.move(to: CGPoint(x: 50, y: 10))
        stroke.end(name: "Brush")
        #expect(pixel(document, 30, 10) == .red)
        #expect(pixel(document, 30, 30) == .white)
        #expect(document.history.undoName == "Brush")
        document.undo()
        #expect(pixel(document, 30, 10) == .white)
        document.redo()
        #expect(pixel(document, 30, 10) == .red)
    }

    @Test func strokeSegmentsJoinWithoutSeams() throws {
        let document = try #require(Document(image: solidImage(width: 200, height: 120, .white)))
        var settings = BrushSettings()
        settings.size = 30
        settings.hardness = 1
        settings.color = .black
        let stroke = try #require(BrushStroke(document: document, settings: settings))
        // Fractional coordinates, as real mouse input in a zoomed view produces.
        for step in 0...20 {
            let t = CGFloat(step) / 20
            stroke.move(to: CGPoint(x: 20.3 + 160.4 * t, y: 30.7 + 60.2 * t))
        }
        stroke.end(name: "Brush")
        for step in 0...200 {
            let t = CGFloat(step) / 200
            let x = Int(20.3 + 160.4 * t), y = Int(30.7 + 60.2 * t)
            #expect(pixel(document, x, y) == Pixel(r: 0, g: 0, b: 0, a: 255), "seam at \(x), \(y)")
        }
    }

    @Test func halfOpaqueStrokeDoesNotBuildUpOnItself() throws {
        let document = try #require(Document(image: solidImage(width: 60, height: 40, .white)))
        var settings = BrushSettings()
        settings.size = 12
        settings.hardness = 1
        settings.opacity = 0.5
        settings.color = .black
        let stroke = try #require(BrushStroke(document: document, settings: settings))
        for x in stride(from: 10, through: 50, by: 2) { stroke.move(to: CGPoint(x: x, y: 20)) }
        for x in stride(from: 50, through: 10, by: -2) { stroke.move(to: CGPoint(x: x, y: 20)) }
        stroke.end(name: "Brush")
        #expect(pixel(document, 30, 20).isClose(to: Pixel(r: 128, g: 128, b: 128, a: 255), tolerance: 2))
    }

    @Test func eraserAndSoftBrush() throws {
        let document = try #require(Document(image: solidImage(width: 60, height: 40, .white)))
        var settings = BrushSettings()
        settings.size = 20
        settings.hardness = 0.2
        settings.mode = .erase
        let stroke = try #require(BrushStroke(document: document, settings: settings))
        stroke.move(to: CGPoint(x: 30, y: 20))
        stroke.end(name: "Eraser")
        #expect(pixel(document, 30, 20).a < 10)
        let edge = pixel(document, 37, 20).a
        #expect(edge > 20 && edge < 240)
        #expect(pixel(document, 50, 20) == .white)
    }

    @Test func selectionLimitsPaint() throws {
        let document = try #require(Document(image: solidImage(width: 40, height: 40, .white)))
        document.setSelection(Selection.rectangle(CGRect(x: 0, y: 0, width: 20, height: 40), in: document.size))
        document.fill(with: RGBAColor(red: 0, green: 0, blue: 1))
        #expect(pixel(document, 5, 5) == .blue)
        #expect(pixel(document, 30, 5) == .white)
        document.invertSelection()
        document.erase()
        #expect(pixel(document, 30, 5) == .clear)
        #expect(pixel(document, 5, 5) == .blue)
        document.setSelection(nil)
        #expect(document.selection == nil)
    }

    @Test func selectionShapesCombine() throws {
        let size = CGSize(width: 40, height: 40)
        let left = try #require(Selection.rectangle(CGRect(x: 0, y: 0, width: 20, height: 40), in: size))
        let top = try #require(Selection.rectangle(CGRect(x: 0, y: 0, width: 40, height: 10), in: size))
        #expect(left.bounds == CGRect(x: 0, y: 0, width: 20, height: 40))
        #expect(left.combined(with: top, mode: .add).bounds == CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(left.combined(with: top, mode: .intersect).bounds == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(left.combined(with: top, mode: .subtract).bounds == CGRect(x: 0, y: 10, width: 20, height: 30))
        let ellipse = try #require(Selection.ellipse(CGRect(x: 10, y: 10, width: 20, height: 20), in: size))
        #expect(ellipse.bounds == CGRect(x: 10, y: 10, width: 20, height: 20))
        let triangle = try #require(Selection.polygon([CGPoint(x: 5, y: 5), CGPoint(x: 35, y: 5), CGPoint(x: 5, y: 35)], in: size))
        #expect(triangle.data[7 * 40 + 7] == 255)
        #expect(triangle.data[30 * 40 + 30] == 0)
    }

    @Test func magicWandAndPaintBucket() throws {
        let document = try #require(Document(image: quadrantImage()))
        document.selectSimilar(at: CGPoint(x: 5, y: 5), tolerance: 10, contiguous: true, sampleAllLayers: false, combine: .replace)
        #expect(document.selection?.bounds == CGRect(x: 0, y: 0, width: 32, height: 24))
        document.setSelection(nil)
        document.floodFill(at: CGPoint(x: 50, y: 40), color: .black, tolerance: 10, contiguous: true, sampleAllLayers: false)
        #expect(pixel(document, 60, 45) == Pixel(r: 0, g: 0, b: 0, a: 255))
        #expect(pixel(document, 2, 2) == .red)
    }

    @Test func floodFillRespectsContiguity() throws {
        // Two white areas separated by a black bar.
        var bytes = [UInt8](repeating: 255, count: 9 * 3 * 4)
        for y in 0..<3 {
            let offset = (y * 9 + 4) * 4
            bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
        }
        let near = try #require(Selection.flood(pixels: bytes, width: 9, height: 3, at: CGPoint(x: 1, y: 1), tolerance: 0, contiguous: true))
        #expect(near.bounds == CGRect(x: 0, y: 0, width: 4, height: 3))
        let everywhere = try #require(Selection.flood(pixels: bytes, width: 9, height: 3, at: CGPoint(x: 1, y: 1), tolerance: 0, contiguous: false))
        #expect(everywhere.bounds == CGRect(x: 0, y: 0, width: 9, height: 3))
        #expect(everywhere.data[4] == 0)
    }

    @Test func paintingOnMovedLayerBakesItsPlacement() throws {
        let document = Document(size: CGSize(width: 80, height: 60), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let id = try #require(document.addImageLayer(solidImage(width: 20, height: 20, .white), name: "Patch", center: CGPoint(x: 20, y: 20)))
        document.fill(with: RGBAColor(red: 1, green: 0, blue: 0))
        // The fill covers the canvas, and the layer is now canvas-sized.
        #expect(document.layer(id)!.isAligned(to: document.size))
        #expect(pixel(document, 70, 50) == .red)
        document.undo()
        #expect(!document.layer(id)!.isAligned(to: document.size))
        #expect(pixel(document, 70, 50) == .clear)
        #expect(pixel(document, 20, 20) == .white)
    }

    @Test func paintingWithTextActiveCreatesLayer() throws {
        let document = try #require(Document(image: solidImage(width: 80, height: 60, .white)))
        document.addLayer(Layer(name: "Text", content: .text(TextContent())))
        #expect(document.layers.count == 2)
        document.fill(with: .black)
        #expect(document.layers.count == 3)
        #expect(document.activeLayer?.isRaster == true)
        document.undo()
        #expect(document.layers.count == 2)
    }

    @Test func gradientRunsBetweenPoints() throws {
        let document = try #require(Document(image: solidImage(width: 100, height: 10, .white)))
        document.drawGradient(from: CGPoint(x: 0, y: 5), to: CGPoint(x: 100, y: 5), startColor: .black, endColor: .white, radial: false)
        #expect(pixel(document, 2, 5).r < 20)
        #expect(pixel(document, 97, 5).r > 235)
        let middle = pixel(document, 50, 5).r
        #expect(middle > 100 && middle < 160)
    }

    @Test func floatSelectionLiftsPixels() throws {
        let document = try #require(Document(image: quadrantImage()))
        document.setSelection(Selection.rectangle(CGRect(x: 0, y: 0, width: 32, height: 24), in: document.size))
        let id = try #require(document.floatSelection())
        #expect(document.layers.count == 2)
        #expect(document.selection == nil)
        #expect(document.layer(id)!.documentBounds == CGRect(x: 0, y: 0, width: 32, height: 24))
        #expect(pixel(document, 5, 5) == .red)
        document.updateLayer(id, name: "Move") { $0.transform = $0.transform.concatenating(CGAffineTransform(translationX: 32, y: 24)) }
        #expect(pixel(document, 5, 5) == .clear)
        #expect(pixel(document, 40, 30) == .red)
        document.undo()
        document.undo()
        #expect(document.layers.count == 1)
        #expect(pixel(document, 5, 5) == .red)
    }
}

@MainActor
@Suite struct ObjectLayerTests {
    @Test func textShapesAndRegionsRender() throws {
        let document = try #require(Document(image: quadrantImage(width: 400, height: 300)))
        var text = TextContent()
        text.string = "MEME TEXT"
        text.fontName = "Impact"
        text.fontSize = 48
        text.outlineWidth = 4
        var textLayer = Layer(name: "Text", content: .text(text))
        textLayer.transform = CGAffineTransform(translationX: 60, y: 20)
        document.addLayer(textLayer)
        let box = document.layer(textLayer.id)!.documentBounds
        #expect(box.width > 150 && box.height > 40)
        // Somewhere inside the box there must be white glyph pixels.
        let bytes = document.pixels()
        var whites = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) where x < 200 && y < 150 {
                let o = (y * 400 + x) * 4
                if bytes[o] > 250 && bytes[o + 1] > 250 && bytes[o + 2] > 250 { whites += 1 }
            }
        }
        #expect(whites > 300)

        var arrow = ShapeContent(kind: .arrow, points: [CGPoint(x: 40, y: 260), CGPoint(x: 180, y: 180)])
        arrow.strokeColor = RGBAColor(red: 1, green: 1, blue: 0)
        arrow.strokeWidth = 8
        document.addLayer(Layer(name: "Arrow", content: .shape(arrow)))
        #expect(pixel(document, 110, 220).isClose(to: Pixel(r: 255, g: 255, b: 0, a: 255), tolerance: 6))

        var ellipse = ShapeContent(kind: .ellipse, points: [CGPoint(x: 250, y: 30), CGPoint(x: 370, y: 110)])
        ellipse.fillColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        document.addLayer(Layer(name: "Ellipse", content: .shape(ellipse)))
        #expect(pixel(document, 310, 70).isClose(to: Pixel(r: 0, g: 128, b: 0, a: 255), tolerance: 4))

        var region = Layer(name: "Pixelate", content: .effect(EffectRegion(effect: .pixelate, size: CGSize(width: 120, height: 100))))
        region.transform = CGAffineTransform(translationX: 140, y: 100)
        document.addLayer(region)
        // Pixelation paints each cell with the color at its center. The cell around the middle of the picture
        // is centered in the blue quadrant, so the red pixels in its corner turn blue.
        #expect(pixel(document, 199, 149) == .blue)
        #expect(pixel(document, 20, 160) == .blue)
        dump(document, "objects")

        document.rasterizeLayer(textLayer.id)
        #expect(document.layer(textLayer.id)!.isAligned(to: document.size))
        document.flatten()
        #expect(document.layers.count == 1)
        dump(document, "objects-flattened")
    }

    @Test func scalingShapesKeepsStrokeWidth() {
        var layer = Layer(name: "R", content: .shape(ShapeContent(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 30)])))
        layer.scale(x: 2, y: 3, aboutLocal: CGPoint(x: 10, y: 10))
        #expect(layer.shape!.pointBounds == CGRect(x: 10, y: 10, width: 80, height: 60))
        #expect(layer.shape!.strokeWidth == 6)
        #expect(layer.transform == .identity)

        var region = Layer(name: "B", content: .effect(EffectRegion(effect: .blur, size: CGSize(width: 40, height: 20))))
        region.transform = CGAffineTransform(translationX: 100, y: 100)
        // Growing from the bottom-right corner keeps that corner at (140, 120).
        region.scale(x: 2, y: 2, aboutLocal: CGPoint(x: 40, y: 20))
        #expect(region.documentBounds == CGRect(x: 60, y: 80, width: 80, height: 40))
    }

    @Test func mergeDownCombinesTwoLayers() throws {
        let document = try #require(Document(image: solidImage(width: 40, height: 40, .white)))
        let top = try #require(document.addImageLayer(solidImage(width: 10, height: 10, .black), name: "Dot", center: CGPoint(x: 20, y: 20)))
        document.mergeDown(top)
        #expect(document.layers.count == 1)
        #expect(pixel(document, 20, 20) == Pixel(r: 0, g: 0, b: 0, a: 255))
        #expect(pixel(document, 5, 5) == .white)
    }
}

@MainActor
@Suite struct ColorTests {
    @Test func adjustmentsMoveColorsTheRightWay() throws {
        let gray = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)
        let document = try #require(Document(image: solidImage(width: 8, height: 8, gray)))
        let id = document.activeLayerID!
        document.updateLayer(id, name: "Warm") { $0.adjustments.temperature = 0.8 }
        let warm = pixel(document, 4, 4)
        #expect(warm.r > warm.b + 10)
        document.updateLayer(id, name: "Cool") { $0.adjustments.temperature = -0.8 }
        let cool = pixel(document, 4, 4)
        #expect(cool.b > cool.r + 10)
        document.updateLayer(id, name: "Bright") {
            $0.adjustments = Adjustments()
            $0.adjustments.brightness = 0.5
        }
        #expect(pixel(document, 4, 4).r > 150)
        document.updateLayer(id, name: "Exposure") {
            $0.adjustments = Adjustments()
            $0.adjustments.exposure = -0.5
        }
        #expect(pixel(document, 4, 4).r < 100)

        let colorful = try #require(Document(image: solidImage(width: 8, height: 8, RGBAColor(red: 0.9, green: 0.3, blue: 0.2))))
        colorful.updateLayer(colorful.activeLayerID!, name: "Gray") { $0.adjustments.saturation = -1 }
        let flat = pixel(colorful, 4, 4)
        #expect(abs(flat.r - flat.g) < 4 && abs(flat.g - flat.b) < 4)
        colorful.applyAdjustments(colorful.activeLayerID!)
        #expect(colorful.activeLayer!.adjustments.isNeutral)
        #expect(pixel(colorful, 4, 4).isClose(to: flat))
    }

    @Test func slidersMergeIntoOneUndoStep() throws {
        let document = try #require(Document(image: solidImage(width: 8, height: 8, .white)))
        let id = document.activeLayerID!
        for value in [0.1, 0.2, 0.3] {
            document.updateLayer(id, name: "Brightness", key: "brightness") { $0.adjustments.brightness = value }
        }
        #expect(document.history.entries.count == 1)
        document.endInteraction()
        document.updateLayer(id, name: "Brightness", key: "brightness") { $0.adjustments.brightness = 0.9 }
        #expect(document.history.entries.count == 2)
        document.undo()
        #expect(document.activeLayer!.adjustments.brightness == 0.3)
        document.undo()
        #expect(document.activeLayer!.adjustments.brightness == 0)
    }

    @Test func historyTracksSavedState() throws {
        let document = try #require(Document(image: solidImage(width: 8, height: 8, .white)))
        #expect(!document.history.isDirty)
        document.fill(with: .black)
        #expect(document.history.isDirty)
        document.history.markSaved()
        #expect(!document.history.isDirty)
        document.undo()
        #expect(document.history.isDirty)
        document.redo()
        #expect(!document.history.isDirty)
        document.history.jump(to: 0)
        #expect(pixel(document, 2, 2) == .white)
    }

    @Test(arguments: EffectCatalog.all.map(\.id))
    func everyEffectRuns(id: String) throws {
        let effect = try #require(EffectCatalog.find(id))
        let document = try #require(Document(image: quadrantImage(width: 96, height: 72)))
        document.applyEffect(effect, values: [:])
        #expect(document.size == CGSize(width: 96, height: 72))
        #expect(document.history.undoName == effect.name)
        // The corner stays opaque: no effect may eat the edges of the layer.
        #expect(pixel(document, 1, 1).a > 200, "\(id) left a transparent edge")
        dump(document, "effect-\(id)")
    }

    @Test func effectsStayInsideSelection() throws {
        let document = try #require(Document(image: quadrantImage()))
        document.setSelection(Selection.rectangle(CGRect(x: 0, y: 0, width: 32, height: 24), in: document.size))
        document.applyEffect(try #require(EffectCatalog.find("invert")), values: [:])
        #expect(pixel(document, 5, 5) == Pixel(r: 0, g: 255, b: 255, a: 255))
        #expect(pixel(document, 60, 5) == .green)
    }

    @Test func colorPickerReadsUnpremultipliedColor() throws {
        let document = try #require(Document(image: quadrantImage()))
        let color = try #require(document.color(at: CGPoint(x: 60, y: 5)))
        #expect(color.green > 0.99 && color.red < 0.01 && color.alpha > 0.99)
    }
}

@MainActor
@Suite struct ProjectTests {
    @Test func projectRoundTrip() throws {
        let document = try #require(Document(image: quadrantImage()))
        var text = TextContent()
        text.string = "Hello"
        var layer = Layer(name: "Caption", content: .text(text))
        layer.transform = CGAffineTransform(translationX: 5, y: 7)
        layer.opacity = 0.5
        layer.blendMode = .screen
        document.addLayer(layer)
        document.addLayer(Layer(name: "Line", content: .shape(ShapeContent(kind: .line, points: [.zero, CGPoint(x: 9, y: 9)]))))
        document.updateLayer(document.layers[0].id, name: "Adjust") { $0.adjustments.contrast = 0.4 }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pixix-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.pixix")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ProjectFile.write(document, to: url)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("preview.png").path))

        let loaded = try ProjectFile.read(from: url)
        #expect(loaded.size == document.size)
        #expect(loaded.layers.count == 3)
        #expect(loaded.layers[1].text?.string == "Hello")
        #expect(loaded.layers[1].opacity == 0.5)
        #expect(loaded.layers[1].blendMode == .screen)
        #expect(loaded.layers[1].transform == CGAffineTransform(translationX: 5, y: 7))
        #expect(loaded.layers[0].adjustments.contrast == 0.4)
        #expect(loaded.layers[2].shape?.kind == .line)
        #expect(loaded.pixels() == document.pixels())
    }
}
