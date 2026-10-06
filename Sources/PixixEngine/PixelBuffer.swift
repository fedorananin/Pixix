import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import IOSurface

/// Premultiplied BGRA pixels, 8 bits per channel, stored in an IOSurface so that both
/// Core Graphics (on the CPU) and Core Image (on the GPU) can work on them without copies.
public final class PixelBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let surface: IOSurface
    public let colorSpace: CGColorSpace

    static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    /// Core Image and Metal refuse textures larger than this.
    public static let maxDimension = 16384

    public var bytesPerRow: Int { surface.bytesPerRow }
    public var byteCount: Int { bytesPerRow * height }
    public var size: CGSize { CGSize(width: width, height: height) }
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// A transparent buffer.
    public init?(width: Int, height: Int, colorSpace: CGColorSpace) {
        guard width > 0, height > 0, width <= Self.maxDimension, height <= Self.maxDimension,
              let surface = IOSurface(properties: [
                  .width: width, .height: height, .bytesPerElement: 4,
                  .pixelFormat: kCVPixelFormatType_32BGRA,
              ])
        else { return nil }
        self.width = width
        self.height = height
        self.surface = surface
        self.colorSpace = colorSpace
        if let profile = colorSpace.copyICCData() {
            IOSurfaceSetValue(surface, "IOSurfaceColorSpace" as CFString, profile)
        }
    }

    /// A buffer holding the image, converted to `colorSpace`.
    public convenience init?(image: CGImage, colorSpace: CGColorSpace) {
        self.init(width: image.width, height: image.height, colorSpace: colorSpace)
        withContext { context in
            context.setBlendMode(.copy)
            context.drawUpright(image, in: bounds)
        }
    }

    /// Runs drawing code against the pixels. The context has a top-left origin.
    public func withContext<T>(_ body: (CGContext) throws -> T) rethrows -> T {
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let context = CGContext(
            data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: Self.bitmapInfo
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return try body(context)
    }

    /// Direct read access to the bytes.
    public func withBytes<T>(_ body: (UnsafeRawBufferPointer, _ bytesPerRow: Int) throws -> T) rethrows -> T {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        return try body(UnsafeRawBufferPointer(start: surface.baseAddress, count: byteCount), bytesPerRow)
    }

    public func withMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer, _ bytesPerRow: Int) throws -> T) rethrows -> T {
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        return try body(UnsafeMutableRawBufferPointer(start: surface.baseAddress, count: byteCount), bytesPerRow)
    }

    public func copy() -> PixelBuffer {
        let twin = PixelBuffer(width: width, height: height, colorSpace: colorSpace)!
        withBytes { source, _ in
            twin.withMutableBytes { destination, _ in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<min(source.count, destination.count)]))
            }
        }
        return twin
    }

    /// An independent snapshot of the pixels.
    public func makeImage() -> CGImage {
        let data = withBytes { bytes, _ in Data(bytes) }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    /// An image that reads the live pixels without copying. It must not outlive the closure,
    /// and the buffer must not be drawn into while it is in use.
    public func withUnsafeImage<T>(_ body: (CGImage) throws -> T) rethrows -> T {
        try withBytes { bytes, rowBytes in
            let provider = CGDataProvider(
                dataInfo: nil, data: bytes.baseAddress!, size: bytes.count, releaseData: { _, _, _ in }
            )!
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )!
            return try body(image)
        }
    }

    /// The pixels as a Core Image image, with no color management applied.
    public func ciImage() -> CIImage {
        CIImage(ioSurface: surface, options: [.colorSpace: NSNull()])
    }

    /// Raw bytes of a pixel rectangle, row by row. The rectangle must lie inside the buffer.
    public func bytes(in rect: CGRect) -> Data {
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0 else { return Data() }
        return withBytes { bytes, rowBytes in
            var data = Data(count: w * h * 4)
            data.withUnsafeMutableBytes { out in
                for row in 0..<h {
                    let source = UnsafeRawBufferPointer(rebasing: bytes[((y + row) * rowBytes + x * 4)...].prefix(w * 4))
                    UnsafeMutableRawBufferPointer(rebasing: out[(row * w * 4)...].prefix(w * 4)).copyMemory(from: source)
                }
            }
            return data
        }
    }

    public func setBytes(_ data: Data, in rect: CGRect) {
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0, data.count >= w * h * 4 else { return }
        withMutableBytes { bytes, rowBytes in
            data.withUnsafeBytes { input in
                for row in 0..<h {
                    let source = UnsafeRawBufferPointer(rebasing: input[(row * w * 4)...].prefix(w * 4))
                    UnsafeMutableRawBufferPointer(rebasing: bytes[((y + row) * rowBytes + x * 4)...].prefix(w * 4))
                        .copyMemory(from: source)
                }
            }
        }
    }

    /// Premultiplied color at a pixel, as blue, green, red, alpha.
    public func pixel(x: Int, y: Int) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return withBytes { bytes, rowBytes in
            let offset = y * rowBytes + x * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
    }
}
