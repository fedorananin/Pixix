import CoreGraphics
import Foundation
import ImageIO

public enum CodecError: Error, LocalizedError {
    case cannotOpen(URL)
    case cannotDecode
    case cannotEncode(String)
    case unsupportedFormat(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): "Cannot open “\(url.lastPathComponent)”."
        case .cannotDecode: "The image could not be decoded."
        case .cannotEncode(let why): "The image could not be saved: \(why)"
        case .unsupportedFormat(let name): "\(name) cannot be written."
        case .cancelled: "Cancelled."
        }
    }
}

/// Basic facts about an image file, read without decoding pixels.
public struct ImageInfo: Sendable {
    /// Size in pixels after the EXIF orientation is applied.
    public var pixelSize: CGSize
    public var frameCount: Int
    public var typeIdentifier: String
    /// EXIF orientation, 1...8.
    public var orientation: Int
    public var hasAlpha: Bool

    public var isAnimated: Bool { frameCount > 1 }
}

/// One frame of an animation.
public struct AnimationFrame: @unchecked Sendable {
    public var image: CGImage
    public var delay: TimeInterval

    public init(image: CGImage, delay: TimeInterval) {
        self.image = image
        self.delay = delay
    }
}

/// A thread-safe handle to an open image file.
public final class ImageSource: @unchecked Sendable {
    public let url: URL
    let source: CGImageSource
    public let info: ImageInfo
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetStatus(source) == .statusComplete || CGImageSourceGetCount(source) > 0
        else { throw CodecError.cannotOpen(url) }
        self.source = source
        self.info = try Self.readInfo(source)
    }

    public init(data: Data) throws {
        self.url = URL(fileURLWithPath: "/dev/null")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else { throw CodecError.cannotDecode }
        self.source = source
        self.info = try Self.readInfo(source)
    }

    private static func readInfo(_ source: CGImageSource) throws -> ImageInfo {
        let count = CGImageSourceGetCount(source)
        guard count > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw CodecError.cannotDecode }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = orientation >= 5
        let type = CGImageSourceGetType(source) as String? ?? "public.image"
        // Multi-page TIFF and multi-image HEIC are not animations.
        let animatedTypes: Set<String> = [
            "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis",
        ]
        let frames = animatedTypes.contains(type) ? count : 1
        return ImageInfo(
            pixelSize: swapped ? CGSize(width: height, height: width) : CGSize(width: width, height: height),
            frameCount: frames,
            typeIdentifier: type,
            orientation: orientation,
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false
        )
    }

    /// Decodes a frame with orientation applied. `maxPixelSize` limits the longer edge; nil means full size.
    public func image(at index: Int = 0, maxPixelSize: Int? = nil) throws -> CGImage {
        let fullEdge = Int(max(info.pixelSize.width, info.pixelSize.height))
        let edge = min(maxPixelSize ?? fullEdge, fullEdge)
        lock.lock()
        defer { lock.unlock() }

        if info.isAnimated {
            // The thumbnail path does not composite partial frames, so animations decode through the frame API.
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, options) else { throw CodecError.cannotDecode }
            if edge < fullEdge, let small = Resampler.resize(frame, longEdge: edge) { return small }
            return frame
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(edge, 1),
        ] as CFDictionary
        if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) { return image }
        // Some exotic types refuse the thumbnail path.
        let fallback = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, index, fallback) else { throw CodecError.cannotDecode }
        return image
    }

    /// Display duration of a frame in seconds.
    public func delay(at index: Int) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { return 0.1 }
        for value in props.values {
            guard let dict = value as? [String: Any] else { continue }
            let raw = (dict["UnclampedDelayTime"] as? Double) ?? (dict["DelayTime"] as? Double)
            if let raw {
                // Browsers treat near-zero delays as 100 ms; follow them so GIFs look as authors intended.
                return raw < 0.011 ? 0.1 : raw
            }
        }
        return 0.1
    }

    /// All frames, optionally scaled. Meant for export, not playback.
    public func allFrames(maxPixelSize: Int? = nil) throws -> [AnimationFrame] {
        try (0..<info.frameCount).map { index in
            AnimationFrame(image: try image(at: index, maxPixelSize: maxPixelSize), delay: delay(at: index))
        }
    }

    /// Raw property dictionary of the first frame, used to carry metadata into an export.
    public func properties(at index: Int = 0) -> [CFString: Any] {
        lock.lock()
        defer { lock.unlock() }
        return CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    }
}

public enum Resampler {
    /// High quality resize to exact pixel dimensions.
    public static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        if image.width == width, image.height == height { return image }
        let space = renderableColorSpace(for: image)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func resize(_ image: CGImage, longEdge: Int) -> CGImage? {
        let current = max(image.width, image.height)
        guard current > 0 else { return nil }
        let scale = Double(longEdge) / Double(current)
        return resize(
            image,
            width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded()))
        )
    }

    /// An RGB color space a bitmap context accepts, as close to the source as possible.
    public static func renderableColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}
