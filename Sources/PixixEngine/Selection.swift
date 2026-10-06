import CoreGraphics
import CoreImage
import Foundation

public enum SelectionCombine: String, Sendable, CaseIterable {
    case replace, add, subtract, intersect
}

/// An 8-bit coverage mask the size of the document: 255 is selected, 0 is not. Immutable.
public final class Selection: @unchecked Sendable {
    public let width: Int
    public let height: Int
    /// Tightly packed rows, top row first.
    public let data: Data
    /// The smallest pixel rectangle that holds every selected pixel.
    public let bounds: CGRect
    public let image: CGImage

    public var isEmpty: Bool { bounds.isEmpty }

    init(width: Int, height: Int, data: Data) {
        self.width = width
        self.height = height
        self.data = data
        self.bounds = Self.tightBounds(data, width: width, height: height)
        self.image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private static func tightBounds(_ data: Data, width: Int, height: Int) -> CGRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let pixels = bytes.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = y * width
                var first = -1, last = -1
                for x in 0..<width where pixels[row + x] != 0 {
                    if first < 0 { first = x }
                    last = x
                }
                if first >= 0 {
                    minX = min(minX, first)
                    maxX = max(maxX, last)
                    minY = min(minY, y)
                    maxY = y
                }
            }
        }
        guard maxX >= 0 else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Runs drawing code against a fresh mask. The context has a top-left origin; paint white to select.
    static func draw(size: CGSize, _ body: (CGContext) -> Void) -> Selection? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        var data = Data(count: width * height)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            body(context)
            return true
        }
        return ok ? Selection(width: width, height: height, data: data) : nil
    }

    public static func rectangle(_ rect: CGRect, in size: CGSize) -> Selection? {
        draw(size: size) { context in
            context.setShouldAntialias(false)
            context.fill(rect.pixelAligned)
        }
    }

    public static func ellipse(_ rect: CGRect, in size: CGSize) -> Selection? {
        draw(size: size) { $0.fillEllipse(in: rect) }
    }

    public static func polygon(_ points: [CGPoint], in size: CGSize) -> Selection? {
        guard points.count >= 3 else { return nil }
        return draw(size: size) { context in
            context.addLines(between: points)
            context.closePath()
            context.fillPath(using: .evenOdd)
        }
    }

    public static func all(in size: CGSize) -> Selection? {
        draw(size: size) { $0.fill(CGRect(origin: .zero, size: size)) }
    }

    public func inverted() -> Selection {
        var copy = data
        copy.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let pixels = bytes.bindMemory(to: UInt8.self)
            for index in pixels.indices { pixels[index] = 255 - pixels[index] }
        }
        return Selection(width: width, height: height, data: copy)
    }

    /// Merges another mask of the same size into this one.
    public func combined(with other: Selection, mode: SelectionCombine) -> Selection {
        guard other.width == width, other.height == height, mode != .replace else { return other }
        var result = data
        result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let out = bytes.bindMemory(to: UInt8.self)
            other.data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                let b = input.bindMemory(to: UInt8.self)
                switch mode {
                case .add:
                    for index in out.indices { out[index] = max(out[index], b[index]) }
                case .subtract:
                    for index in out.indices { out[index] = min(out[index], 255 - b[index]) }
                case .intersect:
                    for index in out.indices { out[index] = min(out[index], b[index]) }
                case .replace:
                    break
                }
            }
        }
        return Selection(width: width, height: height, data: result)
    }

    /// Softens the edge by blurring the mask.
    public func feathered(radius: Double, context: CIContext) -> Selection {
        guard radius > 0 else { return self }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let blurred = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        var output = Data(count: width * height)
        output.withUnsafeMutableBytes { bytes in
            context.render(
                blurred, toBitmap: bytes.baseAddress!, rowBytes: width, bounds: extent, format: .R8, colorSpace: nil
            )
        }
        return Selection(width: width, height: height, data: output)
    }

    /// The mask moved by whole pixels; whatever leaves the canvas is lost.
    public func translated(by offset: CGPoint) -> Selection? {
        Selection.draw(size: CGSize(width: width, height: height)) { context in
            context.interpolationQuality = .none
            context.drawUpright(image, in: CGRect(
                x: offset.x.rounded(), y: offset.y.rounded(), width: CGFloat(width), height: CGFloat(height)
            ))
        }
    }

    /// The mask as a Core Image image in Core Image coordinates.
    public func ciImage() -> CIImage {
        CIImage(cgImage: image, options: [.colorSpace: NSNull()])
    }

    // MARK: Flood fill

    /// Selects pixels whose color is within `tolerance` (0...255 per channel) of the pixel at `point`.
    /// `pixels` is premultiplied BGRA, tightly packed. With `contiguous`, only the connected region is taken.
    public static func flood(
        pixels: [UInt8], width: Int, height: Int, at point: CGPoint, tolerance: Int, contiguous: Bool
    ) -> Selection? {
        let startX = Int(point.x.rounded(.down)), startY = Int(point.y.rounded(.down))
        guard startX >= 0, startY >= 0, startX < width, startY < height, pixels.count >= width * height * 4 else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height)
        let origin = (startY * width + startX) * 4
        let b0 = Int(pixels[origin]), g0 = Int(pixels[origin + 1]), r0 = Int(pixels[origin + 2]), a0 = Int(pixels[origin + 3])

        pixels.withUnsafeBufferPointer { source in
            mask.withUnsafeMutableBufferPointer { out in
                @inline(__always) func matches(_ index: Int) -> Bool {
                    let offset = index * 4
                    return abs(Int(source[offset]) - b0) <= tolerance && abs(Int(source[offset + 1]) - g0) <= tolerance
                        && abs(Int(source[offset + 2]) - r0) <= tolerance && abs(Int(source[offset + 3]) - a0) <= tolerance
                }
                if !contiguous {
                    for index in 0..<(width * height) where matches(index) { out[index] = 255 }
                    return
                }
                // Scanline fill: take a whole run at a time and queue the runs above and below it.
                var stack: [(Int, Int)] = [(startX, startY)]
                while let (seedX, y) = stack.popLast() {
                    let row = y * width
                    guard out[row + seedX] == 0, matches(row + seedX) else { continue }
                    var left = seedX, right = seedX
                    while left > 0, out[row + left - 1] == 0, matches(row + left - 1) { left -= 1 }
                    while right < width - 1, out[row + right + 1] == 0, matches(row + right + 1) { right += 1 }
                    for x in left...right { out[row + x] = 255 }
                    for neighbor in [y - 1, y + 1] where neighbor >= 0 && neighbor < height {
                        let other = neighbor * width
                        var x = left
                        while x <= right {
                            if out[other + x] == 0, matches(other + x) {
                                stack.append((x, neighbor))
                                // Skip the rest of this run; the pop will fill it.
                                while x <= right, out[other + x] == 0, matches(other + x) { x += 1 }
                            } else {
                                x += 1
                            }
                        }
                    }
                }
            }
        }
        return Selection(width: width, height: height, data: Data(mask))
    }
}
