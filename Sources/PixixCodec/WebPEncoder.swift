import Accelerate
import CoreGraphics
import CWebP
import Foundation

/// WebP writing through the vendored libwebp. ImageIO reads WebP but cannot write it.
enum WebPEncoder {
    /// Straight-alpha RGBA bytes in sRGB, the layout libwebp imports.
    private struct Pixels {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var stride: Int
    }

    private static func pixels(of image: CGImage) throws -> Pixels {
        let width = image.width, height = image.height
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            if image.hasAlphaChannel {
                var view = vImage_Buffer(
                    data: buffer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: stride
                )
                vImageUnpremultiplyData_RGBA8888(&view, &view, vImage_Flags(kvImageNoFlags))
            }
            return true
        }
        guard ok else { throw CodecError.cannotEncode("out of memory") }
        return Pixels(bytes: bytes, width: width, height: height, stride: stride)
    }

    private static func makeConfig(quality: Double) throws -> WebPConfig {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw CodecError.cannotEncode("WebP configuration failed") }
        if quality >= 0.995 {
            config.lossless = 1
            config.quality = 75 // In lossless mode this is compression effort, not fidelity.
            config.exact = 0
        } else {
            config.quality = Float(min(max(quality, 0), 1) * 100)
        }
        config.method = 4
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else { throw CodecError.cannotEncode("WebP configuration is invalid") }
        return config
    }

    private static func withPicture<T>(
        _ pixels: Pixels, lossless: Bool, _ body: (inout WebPPicture) throws -> T
    ) throws -> T {
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw CodecError.cannotEncode("WebP picture setup failed") }
        picture.width = Int32(pixels.width)
        picture.height = Int32(pixels.height)
        picture.use_argb = lossless ? 1 : 0
        let imported = pixels.bytes.withUnsafeBufferPointer {
            WebPPictureImportRGBA(&picture, $0.baseAddress, Int32(pixels.stride))
        }
        guard imported != 0 else { throw CodecError.cannotEncode("out of memory") }
        defer { WebPPictureFree(&picture) }
        return try body(&picture)
    }

    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        guard image.width <= 16383, image.height <= 16383 else {
            throw CodecError.cannotEncode("WebP is limited to 16383 pixels per side")
        }
        var config = try makeConfig(quality: quality)
        let source = try pixels(of: image)
        return try withPicture(source, lossless: config.lossless != 0) { picture in
            var writer = WebPMemoryWriter()
            WebPMemoryWriterInit(&writer)
            defer { WebPMemoryWriterClear(&writer) }
            return try withUnsafeMutablePointer(to: &writer) { writerPointer in
                picture.writer = WebPMemoryWrite
                picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
                guard WebPEncode(&config, &picture) != 0 else {
                    throw CodecError.cannotEncode("WebP encoder error \(picture.error_code.rawValue)")
                }
                return Data(bytes: writerPointer.pointee.mem, count: writerPointer.pointee.size)
            }
        }
    }

    static func encodeAnimated(_ frames: [AnimationFrame], quality: Double) throws -> Data {
        guard let first = frames.first else { throw CodecError.cannotEncode("no frames") }
        let width = first.image.width, height = first.image.height
        guard width <= 16383, height <= 16383 else {
            throw CodecError.cannotEncode("WebP is limited to 16383 pixels per side")
        }
        var config = try makeConfig(quality: quality)

        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else { throw CodecError.cannotEncode("WebP animation setup failed") }
        options.anim_params.loop_count = 0
        guard let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &options) else {
            throw CodecError.cannotEncode("WebP animation setup failed")
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var timestamp = 0.0
        for frame in frames {
            let source = try pixels(of: frame.image)
            guard source.width == width, source.height == height else {
                throw CodecError.cannotEncode("animation frames differ in size")
            }
            try withPicture(source, lossless: config.lossless != 0) { picture in
                guard WebPAnimEncoderAdd(encoder, &picture, Int32(timestamp.rounded()), &config) != 0 else {
                    throw CodecError.cannotEncode("WebP animation encoder failed")
                }
            }
            timestamp += max(frame.delay, 0.01) * 1000
        }
        guard WebPAnimEncoderAdd(encoder, nil, Int32(timestamp.rounded()), nil) != 0 else {
            throw CodecError.cannotEncode("WebP animation encoder failed")
        }
        var output = WebPData()
        WebPDataInit(&output)
        defer { WebPDataClear(&output) }
        guard WebPAnimEncoderAssemble(encoder, &output) != 0, let bytes = output.bytes else {
            throw CodecError.cannotEncode("WebP animation assembly failed")
        }
        return Data(bytes: bytes, count: output.size)
    }
}
