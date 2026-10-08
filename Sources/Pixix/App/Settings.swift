import Foundation
import PixixCodec

enum SortOrder: String, CaseIterable, Identifiable {
    case name, dateModified, dateCreated, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .size: "Size"
        }
    }
}

struct ExportPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var settings: ExportSettings
}

/// User preferences, stored in the app's defaults.
@MainActor
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var sortOrder: SortOrder {
        get { SortOrder(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .name }
        set { defaults.set(newValue.rawValue, forKey: "sortOrder") }
    }

    var sortDescending: Bool {
        get { defaults.bool(forKey: "sortDescending") }
        set { defaults.set(newValue, forKey: "sortDescending") }
    }

    /// An ordinary mouse wheel zooms while it is over the picture, instead of scrolling.
    var wheelZooms: Bool {
        get { defaults.object(forKey: "wheelZooms") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wheelZooms") }
    }

    /// Going past the last image continues from the first.
    var wrapAround: Bool {
        get { defaults.object(forKey: "wrapAround") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wrapAround") }
    }

    /// A picture opened while another is on screen gets a window of its own instead of replacing it.
    var opensNewWindows: Bool {
        get { defaults.object(forKey: "opensNewWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "opensNewWindows") }
    }

    /// Text in pictures can be selected and copied.
    var liveText: Bool {
        get { defaults.object(forKey: "liveText") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "liveText") }
    }

    /// The first Save of an editing session moves the file as it was to the Trash.
    var keepsOriginalInTrash: Bool {
        get { defaults.object(forKey: "keepsOriginalInTrash") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepsOriginalInTrash") }
    }

    /// Where Copy to Folder and Move to Folder went last.
    var lastDestinationFolder: URL? {
        get { defaults.string(forKey: "lastDestinationFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path(percentEncoded: false), forKey: "lastDestinationFolder") }
    }

    var showsFilmstrip: Bool {
        get { defaults.bool(forKey: "showsFilmstrip") }
        set { defaults.set(newValue, forKey: "showsFilmstrip") }
    }

    var slideshowInterval: Double {
        get { defaults.object(forKey: "slideshowInterval") as? Double ?? 4 }
        set { defaults.set(newValue, forKey: "slideshowInterval") }
    }

    // MARK: Screenshots

    /// Pixix takes screenshots: it claims a global shortcut and stays in the menu bar when its windows are closed.
    var capturesScreenshots: Bool {
        get { defaults.bool(forKey: "capturesScreenshots") }
        set { defaults.set(newValue, forKey: "capturesScreenshots") }
    }

    /// The shortcut that starts a screenshot. Nil when the user cleared it and uses the menu bar icon alone.
    var captureHotKey: KeyCombo? {
        get { decode("captureHotKey") ?? (defaults.bool(forKey: "captureHotKeyCleared") ? nil : .standard) }
        set {
            encode(newValue, "captureHotKey")
            defaults.set(newValue == nil, forKey: "captureHotKeyCleared")
        }
    }

    /// Where Save puts screenshots.
    var captureFolder: URL {
        get {
            defaults.string(forKey: "captureFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        }
        set { defaults.set(newValue.path(percentEncoded: false), forKey: "captureFolder") }
    }

    var captureFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "captureFormat") ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "captureFormat") }
    }

    /// The proportions the selection is held to, as "16:9". Nil leaves it free.
    var captureAspect: String? {
        get { defaults.string(forKey: "captureAspect") }
        set { defaults.set(newValue, forKey: "captureAspect") }
    }

    /// The markup tool, color and line width used last, so the next screenshot starts with them.
    var captureTool: String? {
        get { defaults.string(forKey: "captureTool") }
        set { defaults.set(newValue, forKey: "captureTool") }
    }

    var captureColor: RGBAColor? {
        get { decode("captureColor") }
        set { encode(newValue, "captureColor") }
    }

    /// In points, so it looks the same on a Retina display and an ordinary one.
    var captureLineWidth: Double {
        get { defaults.object(forKey: "captureLineWidth") as? Double ?? 3 }
        set { defaults.set(newValue, forKey: "captureLineWidth") }
    }

    /// macOS asks for the Screen Recording permission once; after that the app has to explain it itself.
    var didAskForScreenAccess: Bool {
        get { defaults.bool(forKey: "didAskForScreenAccess") }
        set { defaults.set(newValue, forKey: "didAskForScreenAccess") }
    }

    /// The settings of the most recent export, replayed by Export Again.
    var lastExport: ExportSettings? {
        get { decode("lastExport") }
        set { encode(newValue, "lastExport") }
    }

    var exportPresets: [ExportPreset] {
        get {
            decode("exportPresets") ?? Self.defaultPresets
        }
        set { encode(newValue, "exportPresets") }
    }

    private static var defaultPresets: [ExportPreset] {
        func make(_ name: String, _ configure: (inout ExportSettings) -> Void) -> ExportPreset {
            var settings = ExportSettings()
            configure(&settings)
            return ExportPreset(name: name, settings: settings)
        }
        return [
            make("JPEG · 1920 px") { $0.format = .jpeg; $0.quality = 0.82; $0.resize = .longEdge(1920) },
            make("JPEG · 1280 px · small") { $0.format = .jpeg; $0.quality = 0.7; $0.resize = .longEdge(1280) },
            make("WebP · 1920 px") { $0.format = .webp; $0.quality = 0.8; $0.resize = .longEdge(1920) },
            make("PNG · original size") { $0.format = .png },
        ]
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
