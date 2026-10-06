import CoreGraphics
import Foundation
import ImageIO

/// Rotates an image file in place.
public enum FileRotation {
    /// The EXIF orientation that results from turning an image with `orientation` by a quarter turn.
    public static func rotated(orientation: Int, clockwise: Bool) -> Int {
        let cw: [Int: Int] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
        if clockwise { return cw[orientation] ?? 6 }
        return cw.first(where: { $0.value == orientation })?.key ?? 8
    }

    /// Rotates by 90°. JPEG, TIFF and HEIC only get a new orientation tag, so no pixels are re-encoded.
    /// Other writable formats are decoded, turned and written again.
    public static func rotate(url: URL, clockwise: Bool) throws {
        let source = try ImageSource(url: url)
        guard !source.info.isAnimated else { throw CodecError.unsupportedFormat("Rotating an animation") }
        guard let format = ImageFormat(typeIdentifier: source.info.typeIdentifier) else {
            throw CodecError.unsupportedFormat("Rotating this file type")
        }

        if format == .jpeg || format == .tiff || format == .heic {
            let newOrientation = rotated(orientation: source.info.orientation, clockwise: clockwise)
            let output = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(output, source.info.typeIdentifier as CFString, 1, nil) {
                let options = [kCGImageDestinationOrientation: newOrientation] as CFDictionary
                var error: Unmanaged<CFError>?
                if CGImageDestinationCopyImageSource(destination, source.source, options, &error), output.length > 0 {
                    try FileWriter.write(output as Data, to: url)
                    return
                }
            }
        }

        let image = try source.image()
        guard let turned = image.rotatedQuarter(clockwise: clockwise) else { throw CodecError.cannotDecode }
        let data = try ImageEncoder.encode(turned, format: format, quality: 0.92, properties: source.properties())
        try FileWriter.write(data, to: url)
    }
}

extension CGImage {
    /// A copy turned by 90°.
    public func rotatedQuarter(clockwise: Bool) -> CGImage? {
        let space = Resampler.renderableColorSpace(for: self)
        let alpha: CGImageAlphaInfo = hasAlphaChannel ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: alpha.rawValue
        ) else { return nil }
        // Core Graphics has a bottom-left origin, so a positive angle turns counterclockwise.
        if clockwise {
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
