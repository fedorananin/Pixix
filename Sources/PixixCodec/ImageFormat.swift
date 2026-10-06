import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Formats Pixix can write.
public enum ImageFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case jpeg, png, webp, heic, avif, tiff, gif, bmp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .webp: "WebP"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .webp: "webp"
        case .heic: "heic"
        case .avif: "avif"
        case .tiff: "tiff"
        case .gif: "gif"
        case .bmp: "bmp"
        }
    }

    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .webp: "org.webmproject.webp"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .bmp: "com.microsoft.bmp"
        }
    }

    public var supportsAlpha: Bool {
        switch self {
        case .jpeg, .bmp: false
        default: true
        }
    }

    /// Whether the quality slider has any effect.
    public var hasQuality: Bool {
        switch self {
        case .jpeg, .webp, .heic, .avif: true
        default: false
        }
    }

    /// Whether Pixix can write several frames into this format.
    public var supportsAnimation: Bool {
        switch self {
        case .gif, .webp, .png: true
        default: false
        }
    }

    public init?(typeIdentifier: String) {
        guard let match = Self.allCases.first(where: { $0.typeIdentifier == typeIdentifier }) else { return nil }
        self = match
    }

    public init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "jpe", "jfif": self = .jpeg
        case "png", "apng": self = .png
        case "webp": self = .webp
        case "heic", "heif": self = .heic
        case "avif": self = .avif
        case "tif", "tiff": self = .tiff
        case "gif": self = .gif
        case "bmp": self = .bmp
        default: return nil
        }
    }
}

/// What the system decoder can open.
public enum ReadableTypes {
    public static let typeIdentifiers: Set<String> = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    private static let extensionCache = ExtensionCache()

    /// True when the file extension maps to a type ImageIO can decode.
    public static func isReadable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return extensionCache.lookup(ext) {
            guard let type = UTType(filenameExtension: ext) else { return false }
            if typeIdentifiers.contains(type.identifier) { return true }
            // Camera RAW extensions resolve to specific types that conform to a readable parent.
            return type.conforms(to: .rawImage) && type.conforms(to: .image)
        }
    }

    /// File extensions for the Open panel.
    public static var contentTypes: [UTType] {
        typeIdentifiers.compactMap { UTType($0) }
    }
}

private final class ExtensionCache: @unchecked Sendable {
    private var cache: [String: Bool] = [:]
    private let lock = NSLock()

    func lookup(_ ext: String, compute: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[ext] { return hit }
        let value = compute()
        cache[ext] = value
        return value
    }
}
