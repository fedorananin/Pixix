import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface

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

/// A decoded picture, and the IOSurface its pixels are in when they are in one. A surface goes on screen as it
/// is; the picture is what everything else reads.
public struct DecodedImage: @unchecked Sendable {
    public let image: CGImage
    public let surface: IOSurface?

    public init(image: CGImage, surface: IOSurface? = nil) {
        self.image = image
        self.surface = surface
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
        try decoded(at: index, maxPixelSize: maxPixelSize).image
    }

    /// The same, together with the IOSurface that holds the pixels when they are in one, for showing on screen.
    public func decoded(at index: Int = 0, maxPixelSize: Int? = nil) throws -> DecodedImage {
        let fullEdge = Int(max(info.pixelSize.width, info.pixelSize.height))
        let edge = min(maxPixelSize ?? fullEdge, fullEdge)
        lock.lock()
        defer { lock.unlock() }

        if info.isAnimated {
            // The thumbnail path does not composite partial frames, so animations decode through the frame API.
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, options) else { throw CodecError.cannotDecode }
            if edge < fullEdge, let small = Resampler.resize(frame, longEdge: edge) { return DecodedImage(image: small) }
            return DecodedImage(image: frame)
        }

        if let image = uprightImage(at: index, edge: edge < fullEdge ? edge : nil) { return image }
        // The thumbnail call turns the picture by itself, for a file whose pixels vImage could not take.
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(edge, 1),
        ] as CFDictionary
        if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) { return DecodedImage(image: image) }
        // Some exotic types refuse the thumbnail path.
        let fallback = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, index, fallback) else { throw CodecError.cannotDecode }
        return DecodedImage(image: image)
    }

    /// A frame decoded as it is stored, at most `edge` pixels along the longer side or at full size when nil,
    /// then turned upright by hand.
    ///
    /// The thumbnail call can turn it in the same step, but then it draws the decoded file into a second bitmap,
    /// and Core Graphics keeps the first one in a cache of its own long after both pictures are gone: about a
    /// gigabyte after a dozen 30 MP photos, which only memory pressure ever gives back. A full-size picture is
    /// decoded with no thumbnail call at all, so it also goes on screen as it is instead of being copied once
    /// more by Core Animation. A turned one is put into an IOSurface for the same reason. The caller holds the lock.
    private func uprightImage(at index: Int, edge: Int?) -> DecodedImage? {
        let decoded: CGImage?
        if let edge {
            decoded = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(edge, 1),
            ] as CFDictionary)
        } else {
            decoded = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let decoded else { return nil }
        if info.orientation != 1 { return Resampler.oriented(decoded, orientation: info.orientation) }
        // A full decode keeps the file's own layout. Anything but 8-bit RGB (CMYK, 16 bits, gray) goes the
        // thumbnail way, which hands out the 8-bit RGB the rest of the app is used to.
        if edge == nil, decoded.bitsPerComponent != 8 || decoded.colorSpace?.model != .rgb { return nil }
        return DecodedImage(image: decoded)
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

    /// The picture turned the way an EXIF orientation (1 to 8) says it should be shown.
    ///
    /// The pixels are moved with vImage, not drawn: drawing a picture that ImageIO decoded makes Core Graphics
    /// keep a decoded copy of it in a cache of its own, which outlives the picture. They land in an IOSurface,
    /// which Core Animation shows as it is; a picture that does not come from ImageIO it would copy first, and
    /// the memory of those copies stays with the app after they are gone. The working buffer comes straight from
    /// the kernel for the same reason: `malloc` keeps freed blocks of this size, and they count as if in use.
    public static func oriented(_ image: CGImage, orientation: Int) -> DecodedImage? {
        guard (2...8).contains(orientation) else { return DecodedImage(image: image) }
        let space = renderableColorSpace(for: image)
        // BGRA, premultiplied, as an IOSurface holds it for Core Animation. Opaque pictures get an alpha of 255.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space, bitmapInfo: bitmapInfo),
              var source = MappedPixels(width: image.width, height: image.height)
        else { return nil }
        defer { source.unmap() }
        let none = vImage_Flags(kvImageNoFlags)
        guard vImageBuffer_InitWithCGImage(&source.buffer, &format, nil, image, vImage_Flags(kvImageNoAllocate)) == kvImageNoError
        else { return nil }

        // 5 and 7 are a mirror image followed by a quarter turn clockwise. vImage never works in place, so the
        // mirror image needs a buffer of its own.
        var mirrored: MappedPixels?
        defer { mirrored?.unmap() }
        if orientation == 5 || orientation == 7 {
            guard var buffer = MappedPixels(width: image.width, height: image.height) else { return nil }
            // Kept here so that it is unmapped on the way out; it is the same memory as `buffer`.
            mirrored = buffer
            let result = orientation == 5
                ? vImageVerticalReflect_ARGB8888(&source.buffer, &buffer.buffer, none)
                : vImageHorizontalReflect_ARGB8888(&source.buffer, &buffer.buffer, none)
            guard result == kvImageNoError else { return nil }
        }
        var input = mirrored?.buffer ?? source.buffer
        func turn(into output: inout vImage_Buffer) -> Bool {
            var background: [UInt8] = [0, 0, 0, 0]
            let result: vImage_Error
            switch orientation {
            case 2: result = vImageHorizontalReflect_ARGB8888(&input, &output, none)
            case 3: result = vImageRotate90_ARGB8888(&input, &output, UInt8(kRotate180DegreesClockwise), &background, none)
            case 4: result = vImageVerticalReflect_ARGB8888(&input, &output, none)
            case 8: result = vImageRotate90_ARGB8888(&input, &output, UInt8(kRotate270DegreesClockwise), &background, none)
            default: result = vImageRotate90_ARGB8888(&input, &output, UInt8(kRotate90DegreesClockwise), &background, none)
            }
            return result == kvImageNoError
        }

        let swapped = orientation >= 5
        let width = swapped ? image.height : image.width, height = swapped ? image.width : image.height
        if let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]) {
            if let profile = space.copyICCData() {
                IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, profile)
            }
            surface.lock(options: [], seed: nil)
            var output = vImage_Buffer(
                data: surface.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: surface.bytesPerRow
            )
            let turned = turn(into: &output)
            surface.unlock(options: [], seed: nil)
            guard turned, let result = Self.image(over: surface, space: space, bitmapInfo: bitmapInfo) else { return nil }
            return DecodedImage(image: result, surface: surface)
        }
        // A picture too large for a surface is shown the ordinary way.
        guard var output = MappedPixels(width: width, height: height) else { return nil }
        guard turn(into: &output.buffer), let result = output.makeImage(space: space, bitmapInfo: bitmapInfo) else {
            output.unmap()
            return nil
        }
        return DecodedImage(image: result)
    }

    /// An image that reads the pixels of a surface and keeps the surface alive for as long as it lives.
    private static func image(over surface: IOSurface, space: CGColorSpace, bitmapInfo: CGBitmapInfo) -> CGImage? {
        let owner = Unmanaged.passRetained(surface)
        guard let provider = CGDataProvider(
            dataInfo: owner.toOpaque(), data: surface.baseAddress, size: surface.bytesPerRow * surface.height,
            releaseData: { info, _, _ in
                if let info { Unmanaged<IOSurface>.fromOpaque(info).release() }
            }
        ) else {
            owner.release()
            return nil
        }
        return CGImage(
            width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: surface.bytesPerRow, space: space, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// An RGB color space a bitmap context accepts, as close to the source as possible.
    public static func renderableColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}

/// 32-bit pixels in memory mapped from the kernel rather than taken from `malloc`, so that letting go of them
/// gives the memory back to macOS at once.
struct MappedPixels {
    var buffer: vImage_Buffer
    private let size: Int

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let rowBytes = Self.rowBytes(width)
        let size = rowBytes * height
        let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let pointer, pointer != MAP_FAILED else { return nil }
        self.size = size
        buffer = vImage_Buffer(data: pointer, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
    }

    func unmap() {
        munmap(buffer.data, size)
    }

    /// Rows start on 64-byte boundaries, as vImage and Core Animation like them.
    private static func rowBytes(_ width: Int) -> Int { (width * 4 + 63) / 64 * 64 }

    /// An image that owns these pixels from now on and unmaps them when it goes.
    func makeImage(space: CGColorSpace, bitmapInfo: CGBitmapInfo) -> CGImage? {
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer.data, size: size, releaseData: { _, data, size in
            munmap(UnsafeMutableRawPointer(mutating: data), size)
        }) else { return nil }
        return CGImage(
            width: Int(buffer.width), height: Int(buffer.height), bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: buffer.rowBytes, space: space, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
