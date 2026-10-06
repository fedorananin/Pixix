import AppKit
import PixixCodec
import PixixEngine
import UniformTypeIdentifiers

/// Makes Pixix the app that opens images, and remembers what opened them before so that can be undone.
///
/// The two directions are not symmetric. An app may claim a file type for itself silently, but handing a
/// type to a different app makes macOS ask the user to confirm, once per type, and the call waits for the
/// answer. `restore()` therefore puts up one dialog per file type.
@MainActor
enum DefaultViewer {
    struct Outcome {
        var changed = 0
        var alreadyOurs = 0
        var failed: [String] = []

        var summary: String {
            var parts = ["\(changed + alreadyOurs) file types now open with Pixix"]
            if !failed.isEmpty { parts.append("macOS declined \(failed.count): \(failed.joined(separator: ", "))") }
            return parts.joined(separator: "; ") + "."
        }
    }

    /// Every type the decoder reads, plus Pixix projects.
    static var contentTypes: [UTType] {
        (ReadableTypes.typeIdentifiers.sorted() + [ProjectFile.typeIdentifier]).compactMap { UTType($0) }
    }

    /// The app bundle this process runs from, or nil when it was started as a bare binary.
    static var bundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    private static var backupURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixix", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("previous-default-apps.json")
    }

    /// Type identifier to the path of the app that used to open it.
    private static func loadBackup() -> [String: String] {
        guard let data = try? Data(contentsOf: backupURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static var hasBackup: Bool { !loadBackup().isEmpty }

    /// How many file types `restore()` would ask about.
    static var backupCount: Int { loadBackup().count }

    private static func isPixix(_ url: URL?) -> Bool {
        guard let url else { return false }
        return Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func register() async -> Outcome {
        var outcome = Outcome()
        guard let bundle = bundleURL else {
            outcome.failed = ["not running from an app bundle"]
            return outcome
        }
        var backup = loadBackup()
        for type in contentTypes {
            let current = NSWorkspace.shared.urlForApplication(toOpen: type)
            if isPixix(current) {
                outcome.alreadyOurs += 1
                continue
            }
            // Keep the first app we ever displaced, not Pixix itself from an earlier run.
            if backup[type.identifier] == nil, let current {
                backup[type.identifier] = current.path(percentEncoded: false)
            }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: bundle, toOpen: type)
                outcome.changed += 1
            } catch {
                outcome.failed.append(type.preferredFilenameExtension ?? type.identifier)
            }
        }
        if let data = try? JSONEncoder().encode(backup) { try? data.write(to: backupURL, options: .atomic) }
        return outcome
    }

    /// Hands every type back to the app that opened it before Pixix took over.
    /// macOS shows a confirmation dialog for each type and this waits for every answer.
    static func restore() async -> String {
        let backup = loadBackup()
        guard !backup.isEmpty else { return "Nothing to restore." }
        var restored = 0
        var kept = 0
        var remaining = backup
        for (identifier, path) in backup.sorted(by: { $0.key < $1.key }) {
            guard let type = UTType(identifier), FileManager.default.fileExists(atPath: path) else {
                remaining[identifier] = nil
                continue
            }
            let app = URL(fileURLWithPath: path)
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            // The call also returns normally when the user chooses to keep Pixix, so look at the outcome.
            if isPixix(NSWorkspace.shared.urlForApplication(toOpen: type)) {
                kept += 1
            } else {
                restored += 1
                remaining[identifier] = nil
            }
        }
        if remaining.isEmpty {
            try? FileManager.default.removeItem(at: backupURL)
        } else if let data = try? JSONEncoder().encode(remaining) {
            try? data.write(to: backupURL, options: .atomic)
        }
        return kept == 0
            ? "\(restored) file types are back with their previous apps."
            : "\(restored) file types are back with their previous apps; \(kept) stay with Pixix."
    }
}
