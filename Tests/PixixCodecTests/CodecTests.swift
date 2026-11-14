import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PixixCodec

/// A gradient with optional transparency, so encoders have real content to compress.
func makeTestImage(width: Int, height: Int, alpha: Bool = false, seed: Double = 0) -> CGImage {
    let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue
    )!
    if !alpha {
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let colors = [
        CGColor(red: 1, green: seed, blue: 0, alpha: 1), CGColor(red: 0, green: 0.4, blue: 1, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!
    context.clip(to: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    return context.makeImage()!
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixix-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test(arguments: ImageFormat.allCases)
func stillRoundTrip(format: ImageFormat) throws {
    let image = makeTestImage(width: 320, height: 200, alpha: true)
    var settings = ExportSettings()
    settings.format = format
    let result = try ImageEncoder.export(.image(image, properties: nil), settings: settings)
    #expect(result.data.count > 100)
    let decoded = try ImageSource(data: result.data)
    #expect(decoded.info.pixelSize == CGSize(width: 320, height: 200))
    #expect(decoded.info.typeIdentifier == format.typeIdentifier)
    #expect(decoded.info.frameCount == 1)
    _ = try decoded.image()
}

@Test func resizeModes() {
    let size = CGSize(width: 4000, height: 3000)
    #expect(ResizeMode.original.targetSize(for: size) == (4000, 3000))
    #expect(ResizeMode.percent(50).targetSize(for: size) == (2000, 1500))
    #expect(ResizeMode.longEdge(1920).targetSize(for: size) == (1920, 1440))
    #expect(ResizeMode.longEdge(1920).targetSize(for: CGSize(width: 3000, height: 4000)) == (1440, 1920))
    #expect(ResizeMode.exact(width: 100, height: 900).targetSize(for: size) == (100, 900))
}

@Test func exportResizesAndStretches() throws {
    let image = makeTestImage(width: 800, height: 600)
    var settings = ExportSettings()
    settings.format = .jpeg
    settings.resize = .exact(width: 200, height: 400)
    let result = try ImageEncoder.export(.image(image, properties: nil), settings: settings)
    #expect(try ImageSource(data: result.data).info.pixelSize == CGSize(width: 200, height: 400))
}

@Test func jpegFlattensTransparencyOntoBackground() throws {
    let image = makeTestImage(width: 64, height: 64, alpha: true)
    var settings = ExportSettings()
    settings.format = .jpeg
    settings.quality = 1
    settings.background = RGBAColor(red: 1, green: 0, blue: 0)
    let data = try ImageEncoder.export(.image(image, properties: nil), settings: settings).data
    let decoded = try ImageSource(data: data).image()
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Sample the top-left corner, which the gradient does not cover.
    context.draw(decoded, in: CGRect(x: 0, y: -63, width: 64, height: 64))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    #expect(pixel[0] > 240 && pixel[1] < 20 && pixel[2] < 20)
}

@Test func sizeLimitLowersQuality() throws {
    let image = makeTestImage(width: 1200, height: 900)
    var settings = ExportSettings()
    settings.format = .jpeg
    settings.quality = 0.95
    let unlimited = try ImageEncoder.export(.image(image, properties: nil), settings: settings)
    settings.maxFileSizeKB = max(1, unlimited.data.count / 1024 / 2)
    let limited = try ImageEncoder.export(.image(image, properties: nil), settings: settings)
    #expect(limited.data.count <= settings.maxFileSizeKB! * 1024)
    #expect(limited.quality < 0.95)
    #expect(limited.fitsLimit)
}

@Test(arguments: [ImageFormat.gif, .webp, .png])
func animationRoundTrip(format: ImageFormat) throws {
    let frames = (0..<5).map { AnimationFrame(image: makeTestImage(width: 96, height: 64, seed: Double($0) / 5), delay: 0.2) }
    var settings = ExportSettings()
    settings.format = format
    settings.resize = .percent(50)
    let result = try ImageEncoder.export(.frames(frames, properties: nil), settings: settings)
    #expect(result.frameCount == 5)
    let decoded = try ImageSource(data: result.data)
    #expect(decoded.info.frameCount == 5)
    #expect(decoded.info.pixelSize == CGSize(width: 48, height: 32))
    #expect(abs(decoded.delay(at: 2) - 0.2) < 0.011)
    #expect(try decoded.allFrames().count == 5)
}

@Test func animationToStillFormatKeepsFirstFrame() throws {
    let frames = (0..<3).map { AnimationFrame(image: makeTestImage(width: 40, height: 40, seed: Double($0) / 3), delay: 0.1) }
    var settings = ExportSettings()
    settings.format = .jpeg
    let result = try ImageEncoder.export(.frames(frames, properties: nil), settings: settings)
    #expect(result.frameCount == 1)
    #expect(try ImageSource(data: result.data).info.frameCount == 1)
}

@Test func webpLosslessIsExact() throws {
    let image = makeTestImage(width: 50, height: 30)
    let data = try ImageEncoder.encode(image, format: .webp, quality: 1)
    let decoded = try ImageSource(data: data).image()
    func bytes(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 50 * 30 * 4)
        out.withUnsafeMutableBytes {
            let c = CGContext(
                data: $0.baseAddress, width: 50, height: 30, bitsPerComponent: 8, bytesPerRow: 200,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            c.draw(image, in: CGRect(x: 0, y: 0, width: 50, height: 30))
        }
        return out
    }
    #expect(bytes(image) == bytes(decoded))
}

@Test func orientationTableIsConsistent() {
    for start in 1...8 {
        var value = start
        for _ in 0..<4 { value = FileRotation.rotated(orientation: value, clockwise: true) }
        #expect(value == start)
        let there = FileRotation.rotated(orientation: start, clockwise: true)
        #expect(FileRotation.rotated(orientation: there, clockwise: false) == start)
    }
}

@Test(arguments: [ImageFormat.jpeg, .png, .webp])
func rotateFileSwapsDimensions(format: ImageFormat) throws {
    let folder = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("image.\(format.fileExtension)")
    try ImageEncoder.encode(makeTestImage(width: 120, height: 80), format: format, quality: 0.9).write(to: url)
    try FileRotation.rotate(url: url, clockwise: true)
    let source = try ImageSource(url: url)
    #expect(source.info.pixelSize == CGSize(width: 80, height: 120))
    let image = try source.image()
    #expect(image.width == 80 && image.height == 120)
}

@Test func downsampledDecodeRespectsLimit() throws {
    let data = try ImageEncoder.encode(makeTestImage(width: 2000, height: 1000), format: .jpeg, quality: 0.8)
    let image = try ImageSource(data: data).image(maxPixelSize: 500)
    #expect(image.width == 500 && image.height == 250)
}

@Test func uniqueURLAvoidsCollisions() throws {
    let folder = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("a.png")
    try Data([1]).write(to: original)
    let first = FileWriter.uniqueURL(near: original, fileExtension: "jpg")
    #expect(first.lastPathComponent == "a.jpg")
    #expect(FileWriter.uniqueURL(near: original).lastPathComponent == "a 2.png")
}

@Test func readableTypesCoverCommonExtensions() {
    for ext in ["jpg", "png", "gif", "webp", "heic", "avif", "tiff", "bmp", "cr2"] {
        #expect(ReadableTypes.isReadable(URL(fileURLWithPath: "/tmp/x.\(ext)")), "\(ext)")
    }
    #expect(!ReadableTypes.isReadable(URL(fileURLWithPath: "/tmp/x.txt")))
    #expect(!ReadableTypes.isReadable(URL(fileURLWithPath: "/tmp/x.mp4")))
}

@Test func replaceKeepsTheOldFileInTheTrash() throws {
    let folder = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("photo.jpg")
    // Nothing to keep the first time: the file is simply written.
    #expect(try FileWriter.replace(url, with: Data([1, 2, 3]), trashingOriginal: true) == nil)
    let trashed = try FileWriter.replace(url, with: Data([4, 5]), trashingOriginal: true)
    defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
    #expect(try Data(contentsOf: url) == Data([4, 5]))
    // The Trash exists for the user's own volumes; elsewhere the old contents are simply replaced.
    if let trashed { #expect(try Data(contentsOf: trashed) == Data([1, 2, 3])) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["photo.jpg"])
    #expect(try FileWriter.replace(url, with: Data([6]), trashingOriginal: false) == nil)
    #expect(try Data(contentsOf: url) == Data([6]))
}

@Test func histogramCountsTones() throws {
    // Left half black, right half pure red.
    let context = CGContext(
        data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(RGBAColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    context.setFillColor(RGBAColor(red: 1, green: 0, blue: 0).cgColor)
    context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
    let histogram = try #require(Histogram(image: context.makeImage()!))
    #expect(histogram.red[0] == 1024 && histogram.red[255] == 1024)
    #expect(histogram.green[0] == 2048 && histogram.blue[0] == 2048)
    #expect(histogram.luminance[0] == 1024 && histogram.luminance[76] == 1024)
    // Fully transparent pictures have nothing to count.
    let empty = CGContext(
        data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    #expect(Histogram(image: empty.makeImage()!)?.luminance.reduce(0, +) == 0)
}

@Test func coordinateLinksToMaps() {
    let place = ImageDetails.Coordinate(latitude: -33.8568, longitude: 151.2153)
    #expect(place.mapsURL?.absoluteString == "https://maps.apple.com/?ll=-33.856800,151.215300&q=-33.856800,151.215300")
}

/// Pixels of an image as RGBA bytes in sRGB, whatever its own layout.
private func rgbaBytes(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

@Test(arguments: 1...8, [nil, 10])
func decodeTurnsLikeImageIO(orientation: Int, maxPixelSize: Int?) throws {
    // Every pixel different, so any turn or mirror image shows. A preview is half the size.
    let width = 20, height = 12
    var pixels = [UInt8]()
    for y in 0..<height {
        for x in 0..<width { pixels += [UInt8(x * 12), UInt8(y * 20), UInt8(20 + x * 5 + y * 7), 255] }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )!
    let url = temporaryDirectory().appendingPathComponent("turned.tiff")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try ImageSource(url: url).image(maxPixelSize: maxPixelSize)
    // What ImageIO itself makes of the same file.
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let reference = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize ?? max(width, height),
    ] as CFDictionary)!
    #expect(decoded.width == reference.width)
    #expect(decoded.height == reference.height)
    #expect(rgbaBytes(decoded) == rgbaBytes(reference))
    // The turn itself, in case the decode above fell back to the thumbnail call.
    guard maxPixelSize == nil else { return }
    let turned = try #require(Resampler.oriented(CGImageSourceCreateImageAtIndex(source, 0, nil)!, orientation: orientation))
    #expect(rgbaBytes(turned.image) == rgbaBytes(reference))
    // A turned picture is in a surface, for the screen; an upright one is ImageIO's own.
    #expect((turned.surface != nil) == (orientation != 1))
}

@Test(arguments: ["16-bit", "cmyk", "gray"])
func fullDecodeOfUnusualLayoutsMatchesThumbnail(kind: String) throws {
    let width = 8, height = 6
    let (space, bits, info, type): (CGColorSpace, Int, UInt32, String) = switch kind {
    case "16-bit": (CGColorSpace(name: CGColorSpace.sRGB)!, 16, CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue, "public.png")
    case "cmyk": (CGColorSpace(name: CGColorSpace.genericCMYK)!, 8, CGImageAlphaInfo.none.rawValue, "public.jpeg")
    default: (CGColorSpace(name: CGColorSpace.linearGray)!, 8, CGImageAlphaInfo.none.rawValue, "public.png")
    }
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info
    ))
    context.setFillColor(CGColor(gray: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let url = temporaryDirectory().appendingPathComponent("odd")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try ImageSource(url: url).image()
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let reference = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(width, height),
    ] as CFDictionary))
    #expect(decoded.bitsPerComponent == reference.bitsPerComponent)
    #expect(decoded.colorSpace?.model == reference.colorSpace?.model)
}
