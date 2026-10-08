import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Finds what a picture is of: the people, animals and things in front of the background.
/// The work is the system's, the same that lifts a subject out of a photo in Photos and Preview.
enum SubjectFinder {
    /// Coverage of the subjects, one byte per pixel of the image, top row first. Nil when nothing stands out.
    nonisolated static func mask(for image: CGImage) throws -> Data? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), width > 0, height > 0 else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var coverage = Data(count: width * height)
        coverage.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            let bytes = out.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
                for x in 0..<width {
                    bytes[y * width + x] = UInt8(min(max(row[x], 0), 1) * 255)
                }
            }
        }
        if width == image.width, height == image.height { return coverage }
        return resample(coverage, width: width, height: height, toWidth: image.width, height: image.height)
    }

    /// The mask usually comes back at the size of the picture. When it does not, stretch it to fit.
    private nonisolated static func resample(_ coverage: Data, width: Int, height: Int, toWidth newWidth: Int, height newHeight: Int) -> Data? {
        guard let provider = CGDataProvider(data: coverage as CFData), let mask = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }
        var result = Data(count: newWidth * newHeight)
        let drawn = result.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: newWidth,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(mask, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            return true
        }
        return drawn ? result : nil
    }
}
