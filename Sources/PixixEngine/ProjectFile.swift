import CoreGraphics
import Foundation
import PixixCodec
import UniformTypeIdentifiers

/// The `.pixix` project: a package folder with a manifest, one PNG per raster layer and a flattened preview.
public enum ProjectFile {
    public static let fileExtension = "pixix"
    public static let typeIdentifier = "me.fedorananin.pixix.project"
    public static var contentType: UTType { UTType(typeIdentifier) ?? UTType(filenameExtension: fileExtension) ?? .package }

    private static let manifestName = "manifest.json"
    private static let previewName = "preview.png"
    /// Version 2 added badges, spotlights, shadows and speech bubbles; version 1 projects still open.
    private static let currentVersion = 2

    private struct Manifest: Codable {
        var version: Int
        var width: Int
        var height: Int
        var colorSpace: String?
        var activeLayer: UUID?
        var layers: [LayerRecord]
    }

    private struct LayerRecord: Codable {
        var id: UUID
        var name: String
        var isVisible: Bool
        var isLocked: Bool
        var opacity: Double
        var blendMode: BlendMode
        var transform: [Double]
        var adjustments: Adjustments
        var filter: PhotoFilter
        /// File name of the pixels, for raster layers.
        var pixels: String?
        var text: TextContent?
        var shape: ShapeContent?
        var effect: EffectRegion?
    }

    public enum ProjectError: Error, LocalizedError {
        case unreadable
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The project could not be read."
            case .newerVersion(let version): "The project was saved by a newer version of Pixix (format \(version))."
            }
        }
    }

    @MainActor
    public static func write(_ document: Document, to url: URL) throws {
        var files: [String: FileWrapper] = [:]
        var records: [LayerRecord] = []
        for (index, layer) in document.layers.enumerated() {
            let t = layer.transform
            var record = LayerRecord(
                id: layer.id, name: layer.name, isVisible: layer.isVisible, isLocked: layer.isLocked,
                opacity: layer.opacity, blendMode: layer.blendMode, transform: [t.a, t.b, t.c, t.d, t.tx, t.ty],
                adjustments: layer.adjustments, filter: layer.filter
            )
            switch layer.content {
            case .raster(let buffer):
                let name = "layer-\(index).png"
                files[name] = FileWrapper(regularFileWithContents: try ImageEncoder.encode(buffer.makeImage(), format: .png, quality: 1))
                record.pixels = name
            case .text(let text): record.text = text
            case .shape(let shape): record.shape = shape
            case .effect(let region): record.effect = region
            }
            records.append(record)
        }
        let manifest = Manifest(
            version: currentVersion, width: Int(document.size.width), height: Int(document.size.height),
            colorSpace: document.colorSpace.name as String?, activeLayer: document.activeLayerID, layers: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        files[manifestName] = FileWrapper(regularFileWithContents: try encoder.encode(manifest))
        if let flat = document.flattenedImage(), let preview = Resampler.resize(flat, longEdge: min(1024, max(flat.width, flat.height))) {
            files[previewName] = FileWrapper(regularFileWithContents: try ImageEncoder.encode(preview, format: .png, quality: 1))
        }
        try FileWrapper(directoryWithFileWrappers: files).write(to: url, options: .atomic, originalContentsURL: nil)
    }

    @MainActor
    public static func read(from url: URL) throws -> Document {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw ProjectError.unreadable }
        guard manifest.version <= currentVersion else { throw ProjectError.newerVersion(manifest.version) }
        let space = manifest.colorSpace.flatMap { CGColorSpace(name: $0 as CFString) } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let document = Document(size: CGSize(width: manifest.width, height: manifest.height), colorSpace: space)
        var layers: [Layer] = []
        for record in manifest.layers {
            let content: LayerContent
            if let name = record.pixels {
                guard let image = try? ImageSource(url: url.appendingPathComponent(name)).image(),
                      let buffer = PixelBuffer(image: image, colorSpace: space)
                else { throw ProjectError.unreadable }
                content = .raster(buffer)
            } else if let text = record.text {
                content = .text(text)
            } else if let shape = record.shape {
                content = .shape(shape)
            } else if let effect = record.effect {
                content = .effect(effect)
            } else {
                continue
            }
            var layer = Layer(name: record.name, content: content)
            layer.id = record.id
            layer.isVisible = record.isVisible
            layer.isLocked = record.isLocked
            layer.opacity = record.opacity
            layer.blendMode = record.blendMode
            if record.transform.count == 6 {
                let t = record.transform
                layer.transform = CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5])
            }
            layer.adjustments = record.adjustments
            layer.filter = record.filter
            layers.append(layer)
        }
        guard !layers.isEmpty else { throw ProjectError.unreadable }
        let active = manifest.activeLayer.flatMap { id in layers.contains { $0.id == id } ? id : nil } ?? layers.last?.id
        document.load(DocumentState(size: document.size, layers: layers, activeLayerID: active, selection: nil))
        return document
    }
}
