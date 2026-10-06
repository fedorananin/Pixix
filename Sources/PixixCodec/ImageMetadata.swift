import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Human-readable file details for the Info panel.
public struct ImageDetails: Sendable {
    public struct Row: Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public struct Section: Sendable, Identifiable {
        public var title: String
        public var rows: [Row]
        public var id: String { title }
    }

    public var sections: [Section]

    public static func read(url: URL) -> ImageDetails {
        var sections: [Section] = []
        var file: [Row] = [Row(label: "Name", value: url.lastPathComponent)]

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        if let size = values?.fileSize {
            file.append(Row(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        if let created = values?.creationDate { file.append(Row(label: "Created", value: dates.string(from: created))) }
        if let modified = values?.contentModificationDate { file.append(Row(label: "Modified", value: dates.string(from: modified))) }
        file.append(Row(label: "Folder", value: url.deletingLastPathComponent().path(percentEncoded: false)))

        guard let source = try? ImageSource(url: url) else {
            return ImageDetails(sections: [Section(title: "File", rows: file)])
        }
        let props = source.properties()
        let info = source.info

        var image: [Row] = []
        let width = Int(info.pixelSize.width), height = Int(info.pixelSize.height)
        image.append(Row(label: "Dimensions", value: "\(width) × \(height)"))
        let megapixels = Double(width * height) / 1_000_000
        if megapixels >= 0.1 { image.append(Row(label: "Megapixels", value: String(format: "%.1f MP", megapixels))) }
        let typeName = UTType(info.typeIdentifier)?.localizedDescription ?? info.typeIdentifier
        image.append(Row(label: "Format", value: typeName))
        if info.isAnimated { image.append(Row(label: "Frames", value: "\(info.frameCount)")) }
        if let model = props[kCGImagePropertyColorModel] as? String { image.append(Row(label: "Color model", value: model)) }
        if let profile = props[kCGImagePropertyProfileName] as? String { image.append(Row(label: "Color profile", value: profile)) }
        if let depth = props[kCGImagePropertyDepth] as? Int { image.append(Row(label: "Bit depth", value: "\(depth)")) }
        image.append(Row(label: "Alpha", value: info.hasAlpha ? "Yes" : "No"))
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double { image.append(Row(label: "Resolution", value: "\(Int(dpi.rounded())) dpi")) }

        sections.append(Section(title: "File", rows: file))
        sections.append(Section(title: "Image", rows: image))

        var camera: [Row] = []
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            let full = (make.map { model.hasPrefix($0) ? model : "\($0) \(model)" }) ?? model
            camera.append(Row(label: "Camera", value: full))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { camera.append(Row(label: "Lens", value: lens)) }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { camera.append(Row(label: "Taken", value: taken)) }
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            let text = exposure < 1 ? "1/\(Int((1 / exposure).rounded())) s" : String(format: "%.1f s", exposure)
            camera.append(Row(label: "Exposure", value: text))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double { camera.append(Row(label: "Aperture", value: String(format: "ƒ/%.1f", aperture))) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { camera.append(Row(label: "ISO", value: "\(iso)")) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { camera.append(Row(label: "Focal length", value: String(format: "%.0f mm", focal))) }
        if !camera.isEmpty { sections.append(Section(title: "Camera", rows: camera)) }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            sections.append(Section(title: "Location", rows: [
                Row(label: "Coordinates", value: String(format: "%.5f° %@, %.5f° %@", lat, latRef, lon, lonRef)),
            ]))
        }
        return ImageDetails(sections: sections)
    }
}
