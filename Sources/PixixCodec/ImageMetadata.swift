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
    /// Where the picture was taken, in degrees; south and west are negative.
    public var coordinate: Coordinate?

    public struct Coordinate: Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double

        /// The place in Apple Maps.
        public var mapsURL: URL? {
            let place = String(format: "%.6f,%.6f", latitude, longitude)
            return URL(string: "https://maps.apple.com/?ll=\(place)&q=\(place)")
        }
    }

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
            let coordinate = Coordinate(
                latitude: latRef.uppercased() == "S" ? -abs(lat) : lat, longitude: lonRef.uppercased() == "W" ? -abs(lon) : lon
            )
            return ImageDetails(sections: sections, coordinate: coordinate)
        }
        return ImageDetails(sections: sections)
    }
}

/// How the tones of a picture are spread from dark to light, counted on a shrunken copy.
public struct Histogram: Sendable, Equatable {
    /// 256 counts per channel, darkest first.
    public var red = [Int](repeating: 0, count: 256)
    public var green = [Int](repeating: 0, count: 256)
    public var blue = [Int](repeating: 0, count: 256)
    public var luminance = [Int](repeating: 0, count: 256)

    /// The tallest column, for scaling a drawing. The two ends are left out: a blown sky or a black frame
    /// would otherwise flatten everything else.
    public var peak: Int {
        [red, green, blue, luminance].map { $0[1..<255].max() ?? 0 }.max() ?? 0
    }

    public init?(image: CGImage, maxPixel: Int = 256) {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            // Transparent pixels have no tone to count.
            guard alpha > 8 else { continue }
            let r = min(Int(pixels[offset]) * 255 / alpha, 255), g = min(Int(pixels[offset + 1]) * 255 / alpha, 255)
            let b = min(Int(pixels[offset + 2]) * 255 / alpha, 255)
            red[r] += 1
            green[g] += 1
            blue[b] += 1
            luminance[(r * 299 + g * 587 + b * 114) / 1000] += 1
        }
    }
}
