import CoreGraphics
import Foundation
import ImageIO

public struct RGBAColor: Codable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

    public var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }
}

public enum ResizeMode: Codable, Sendable, Hashable {
    case original
    case percent(Double)
    case longEdge(Int)
    /// Exact pixel size; stretches when the ratio differs from the source.
    case exact(width: Int, height: Int)

    /// Output pixel size for a source of the given size.
    public func targetSize(for source: CGSize) -> (width: Int, height: Int) {
        let w = max(source.width, 1), h = max(source.height, 1)
        switch self {
        case .original:
            return (Int(w), Int(h))
        case .percent(let percent):
            let scale = max(percent, 0.1) / 100
            return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
        case .longEdge(let edge):
            let scale = Double(max(edge, 1)) / Double(max(w, h))
            return (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
        case .exact(let width, let height):
            return (max(1, width), max(1, height))
        }
    }
}

public struct ExportSettings: Codable, Sendable, Hashable {
    public var format: ImageFormat = .jpeg
    /// 0...1. For WebP, 1 means lossless.
    public var quality: Double = 0.85
    public var resize: ResizeMode = .original
    /// When set, quality is lowered until the file fits. Only for formats with a quality setting.
    public var maxFileSizeKB: Int?
    public var stripMetadata = false
    public var convertToSRGB = false
    /// Fills transparency when the format has no alpha channel.
    public var background: RGBAColor = .white

    public init() {}
}

public enum ExportSource: @unchecked Sendable {
    case image(CGImage, properties: [CFString: Any]?)
    case frames([AnimationFrame], properties: [CFString: Any]?)

    public var pixelSize: CGSize {
        switch self {
        case .image(let image, _): CGSize(width: image.width, height: image.height)
        case .frames(let frames, _): frames.first.map { CGSize(width: $0.image.width, height: $0.image.height) } ?? .zero
        }
    }

    public var isAnimated: Bool {
        if case .frames(let frames, _) = self { return frames.count > 1 }
        return false
    }
}

public struct ExportResult: Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    /// The quality actually used, after any size-limit search.
    public var quality: Double
    public var frameCount: Int
    /// False when a size limit was requested but could not be reached.
    public var fitsLimit: Bool
}

public enum ImageEncoder {
    /// Runs the whole export: resize, flatten, encode, and the optional file-size search.
    public static func export(
        _ source: ExportSource, settings: ExportSettings, isCancelled: @Sendable () -> Bool = { false }
    ) throws -> ExportResult {
        let target = settings.resize.targetSize(for: source.pixelSize)

        if case .frames(let frames, _) = source, frames.count > 1, settings.format.supportsAnimation {
            var prepared: [AnimationFrame] = []
            prepared.reserveCapacity(frames.count)
            for frame in frames {
                if isCancelled() { throw CodecError.cancelled }
                let image = try prepare(frame.image, width: target.width, height: target.height, settings: settings)
                prepared.append(AnimationFrame(image: image, delay: frame.delay))
            }
            let data = try encodeAnimated(prepared, format: settings.format, quality: settings.quality)
            return ExportResult(
                data: data, width: target.width, height: target.height, quality: settings.quality,
                frameCount: prepared.count, fitsLimit: fits(data, settings)
            )
        }

        let image: CGImage
        let properties: [CFString: Any]?
        switch source {
        case .image(let img, let props):
            image = img
            properties = props
        case .frames(let frames, let props):
            guard let first = frames.first else { throw CodecError.cannotEncode("no frames") }
            image = first.image
            properties = props
        }
        let prepared = try prepare(image, width: target.width, height: target.height, settings: settings)
        let metadata = settings.stripMetadata ? nil : properties

        var quality = settings.quality
        var data = try encode(prepared, format: settings.format, quality: quality, properties: metadata)
        if let limitKB = settings.maxFileSizeKB, settings.format.hasQuality, data.count > limitKB * 1024 {
            // Bisect quality; file size is monotonic enough in practice for every lossy encoder we use.
            var low = 0.02, high = min(quality, 0.99)
            var best: (Data, Double)?
            for _ in 0..<7 {
                if isCancelled() { throw CodecError.cancelled }
                let mid = (low + high) / 2
                let attempt = try encode(prepared, format: settings.format, quality: mid, properties: metadata)
                if attempt.count <= limitKB * 1024 {
                    best = (attempt, mid)
                    low = mid
                } else {
                    high = mid
                }
            }
            if let best {
                data = best.0
                quality = best.1
            } else {
                quality = low
                data = try encode(prepared, format: settings.format, quality: low, properties: metadata)
            }
        }
        return ExportResult(
            data: data, width: target.width, height: target.height, quality: quality, frameCount: 1,
            fitsLimit: fits(data, settings)
        )
    }

    private static func fits(_ data: Data, _ settings: ExportSettings) -> Bool {
        guard let limit = settings.maxFileSizeKB else { return true }
        return data.count <= limit * 1024
    }

    /// Resizes, converts the color space and flattens transparency as the settings demand.
    static func prepare(_ image: CGImage, width: Int, height: Int, settings: ExportSettings) throws -> CGImage {
        let hasAlpha = image.hasAlphaChannel
        let needsFlatten = hasAlpha && !settings.format.supportsAlpha
        let sourceSpace = Resampler.renderableColorSpace(for: image)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // WebP carries no profile in our writer, so its pixels must already be sRGB.
        let wantsSRGB = settings.convertToSRGB || settings.format == .webp || settings.format == .gif || settings.format == .bmp
        let space = wantsSRGB ? srgb : sourceSpace
        let needsConversion = image.colorSpace.map { !CFEqual($0, space) } ?? true
        let needsResize = image.width != width || image.height != height
        guard needsFlatten || needsConversion || needsResize else { return image }

        let alphaInfo: CGImageAlphaInfo = needsFlatten || !hasAlpha ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: alphaInfo.rawValue
        ) else { throw CodecError.cannotEncode("out of memory") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if needsFlatten {
            context.setFillColor(settings.background.cgColor)
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw CodecError.cannotEncode("out of memory") }
        return result
    }

    /// Encodes one still image.
    public static func encode(
        _ image: CGImage, format: ImageFormat, quality: Double, properties: [CFString: Any]? = nil
    ) throws -> Data {
        if format == .webp {
            return try WebPEncoder.encode(image, quality: quality)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier as CFString, 1, nil) else {
            throw CodecError.unsupportedFormat(format.displayName)
        }
        var options = sanitizedMetadata(properties)
        if format.hasQuality {
            options[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        if format == .tiff {
            var tiff = options[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            options[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CodecError.cannotEncode("the \(format.displayName) encoder failed")
        }
        return output as Data
    }

    /// Encodes an animation. Every frame must already have the same pixel size.
    public static func encodeAnimated(_ frames: [AnimationFrame], format: ImageFormat, quality: Double) throws -> Data {
        guard !frames.isEmpty else { throw CodecError.cannotEncode("no frames") }
        switch format {
        case .webp:
            return try WebPEncoder.encodeAnimated(frames, quality: quality)
        case .gif, .png:
            let isGIF = format == .gif
            let dictionaryKey = isGIF ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
            let loopKey = isGIF ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
            let delayKey = isGIF ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
            let unclampedKey = isGIF ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, format.typeIdentifier as CFString, frames.count, nil
            ) else { throw CodecError.unsupportedFormat(format.displayName) }
            CGImageDestinationSetProperties(destination, [dictionaryKey: [loopKey: 0]] as CFDictionary)
            for frame in frames {
                let props = [dictionaryKey: [delayKey: frame.delay, unclampedKey: frame.delay]] as CFDictionary
                CGImageDestinationAddImage(destination, frame.image, props)
            }
            guard CGImageDestinationFinalize(destination) else {
                throw CodecError.cannotEncode("the \(format.displayName) encoder failed")
            }
            return output as Data
        default:
            throw CodecError.unsupportedFormat("Animated \(format.displayName)")
        }
    }

    /// Keeps descriptive metadata and drops everything that describes the old pixel layout.
    private static func sanitizedMetadata(_ properties: [CFString: Any]?) -> [CFString: Any] {
        guard let properties else { return [:] }
        var result: [CFString: Any] = [:]
        let keep: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary,
        ]
        for key in keep {
            if let value = properties[key] { result[key] = value }
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            result[kCGImagePropertyExifDictionary] = exif
        }
        // Pixels are always written upright.
        result[kCGImagePropertyOrientation] = 1
        if let dpi = properties[kCGImagePropertyDPIWidth] { result[kCGImagePropertyDPIWidth] = dpi }
        if let dpi = properties[kCGImagePropertyDPIHeight] { result[kCGImagePropertyDPIHeight] = dpi }
        return result
    }
}

extension CGImage {
    public var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}

public enum FileWriter {
    /// Replaces the file in one step, so a failure never leaves a half-written file behind.
    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// A free name next to `url`: "photo.jpg" becomes "photo 2.jpg" and so on. Optionally swaps the extension.
    public static func uniqueURL(near url: URL, suffix: String = "", fileExtension: String? = nil) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + suffix
        let ext = fileExtension ?? url.pathExtension
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
