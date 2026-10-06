import AppKit
import Observation
import PixixCodec

/// State behind the export dialog. Re-encodes in the background whenever a setting changes,
/// so the dialog always shows the real output size.
@MainActor
@Observable
final class ExportModel {
    enum SizeMode: String, CaseIterable, Identifiable {
        case original, percent, longEdge, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: "Original"
            case .percent: "Percent"
            case .longEdge: "Long Edge"
            case .custom: "Custom"
            }
        }
    }

    enum Estimate: Equatable {
        case working
        case ready(bytes: Int, width: Int, height: Int, quality: Double, fitsLimit: Bool, frames: Int)
        case failed(String)
    }

    let title: String
    let confirmTitle: String
    let source: ExportSource
    let originalBytes: Int?
    let sourceHasAlpha: Bool

    var format: ImageFormat { didSet { changed() } }
    var quality: Double { didSet { changed() } }
    var sizeMode: SizeMode { didSet { changed() } }
    var percent: Double { didSet { changed() } }
    var longEdge: Int { didSet { changed() } }
    var customWidth: Int { didSet { widthChanged() } }
    var customHeight: Int { didSet { heightChanged() } }
    var keepsAspect = true { didSet { if keepsAspect { widthChanged() } } }
    var limitsFileSize: Bool { didSet { changed() } }
    var limitKB: Int { didSet { changed() } }
    var stripMetadata: Bool { didSet { changed() } }
    var convertToSRGB: Bool { didSet { changed() } }
    var background: Color { didSet { changed() } }

    private(set) var estimate: Estimate = .working
    private(set) var presets: [ExportPreset] = Settings.shared.exportPresets
    var selectedPreset: ExportPreset.ID?
    // View state lives here because the @State macro needs a compiler plugin that only ships with Xcode.
    var presetName = ""
    var isNamingPreset = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastResult: (settings: ExportSettings, result: ExportResult)?
    @ObservationIgnored private var isApplying = false

    typealias Color = RGBAColor

    init(title: String, confirmTitle: String, source: ExportSource, initial: ExportSettings, originalBytes: Int?) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.source = source
        self.originalBytes = originalBytes
        let size = source.pixelSize
        switch source {
        case .image(let image, _): sourceHasAlpha = image.hasAlphaChannel
        case .frames(let frames, _): sourceHasAlpha = frames.first?.image.hasAlphaChannel ?? false
        }
        format = initial.format
        quality = initial.quality
        limitsFileSize = initial.maxFileSizeKB != nil
        limitKB = initial.maxFileSizeKB ?? 500
        stripMetadata = initial.stripMetadata
        convertToSRGB = initial.convertToSRGB
        background = initial.background
        percent = 50
        longEdge = 1920
        customWidth = Int(size.width)
        customHeight = Int(size.height)
        sizeMode = .original
        applyResize(initial.resize)
        changed()
    }

    var sourceSize: CGSize { source.pixelSize }
    var isAnimatedSource: Bool { source.isAnimated }

    private func applyResize(_ resize: ResizeMode) {
        isApplying = true
        defer { isApplying = false }
        switch resize {
        case .original:
            sizeMode = .original
        case .percent(let value):
            sizeMode = .percent
            percent = value
        case .longEdge(let edge):
            sizeMode = .longEdge
            longEdge = edge
        case .exact(let width, let height):
            sizeMode = .custom
            keepsAspect = false
            customWidth = width
            customHeight = height
        }
    }

    var settings: ExportSettings {
        var settings = ExportSettings()
        settings.format = format
        settings.quality = quality
        switch sizeMode {
        case .original: settings.resize = .original
        case .percent: settings.resize = .percent(percent)
        case .longEdge: settings.resize = .longEdge(max(longEdge, 1))
        case .custom: settings.resize = .exact(width: max(customWidth, 1), height: max(customHeight, 1))
        }
        settings.maxFileSizeKB = limitsFileSize && format.hasQuality ? max(limitKB, 1) : nil
        settings.stripMetadata = stripMetadata
        settings.convertToSRGB = convertToSRGB
        settings.background = background
        return settings
    }

    var outputSize: (width: Int, height: Int) { settings.resize.targetSize(for: sourceSize) }

    private func widthChanged() {
        guard !isApplying else { return }
        if keepsAspect, sourceSize.width > 0 {
            isApplying = true
            customHeight = max(1, Int((Double(customWidth) * sourceSize.height / sourceSize.width).rounded()))
            isApplying = false
        }
        changed()
    }

    private func heightChanged() {
        guard !isApplying else { return }
        if keepsAspect, sourceSize.height > 0 {
            isApplying = true
            customWidth = max(1, Int((Double(customHeight) * sourceSize.width / sourceSize.height).rounded()))
            isApplying = false
        }
        changed()
    }

    private func changed() {
        guard !isApplying else { return }
        let settings = self.settings
        if let lastResult, lastResult.settings == settings {
            publish(lastResult.result)
            return
        }
        estimate = .working
        task?.cancel()
        let source = self.source
        task = Task { [weak self] in
            // Let slider drags settle before spending CPU on an encode.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ExportResult, Error> in
                Result { try ImageEncoder.export(source, settings: settings, isCancelled: { Task.isCancelled }) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .success(let result):
                self.lastResult = (settings, result)
                self.publish(result)
            case .failure(let error):
                self.estimate = .failed(error.localizedDescription)
            }
        }
    }

    private func publish(_ result: ExportResult) {
        estimate = .ready(
            bytes: result.data.count, width: result.width, height: result.height, quality: result.quality,
            fitsLimit: result.fitsLimit, frames: result.frameCount
        )
    }

    /// The encoded file for the current settings, reusing the estimate when it is still valid.
    func encode() async throws -> ExportResult {
        let settings = self.settings
        if let lastResult, lastResult.settings == settings { return lastResult.result }
        task?.cancel()
        let source = self.source
        let result = try await Task.detached(priority: .userInitiated) {
            try ImageEncoder.export(source, settings: settings)
        }.value
        lastResult = (settings, result)
        return result
    }

    // MARK: Presets

    func applyPreset(_ id: ExportPreset.ID?) {
        selectedPreset = id
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        isApplying = true
        format = preset.settings.format
        quality = preset.settings.quality
        limitsFileSize = preset.settings.maxFileSizeKB != nil
        if let limit = preset.settings.maxFileSizeKB { limitKB = limit }
        stripMetadata = preset.settings.stripMetadata
        convertToSRGB = preset.settings.convertToSRGB
        background = preset.settings.background
        isApplying = false
        applyResize(preset.settings.resize)
        changed()
    }

    func savePreset(named name: String) {
        let preset = ExportPreset(name: name, settings: settings)
        presets.append(preset)
        Settings.shared.exportPresets = presets
        selectedPreset = preset.id
    }

    func deleteSelectedPreset() {
        presets.removeAll { $0.id == selectedPreset }
        Settings.shared.exportPresets = presets
        selectedPreset = nil
    }
}
