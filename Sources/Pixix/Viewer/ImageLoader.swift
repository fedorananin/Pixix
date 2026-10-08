import AppKit
import PixixCodec

/// A decoded image together with what is known about its file.
struct LoadedImage: Sendable {
    var image: CGImage
    var info: ImageInfo
    /// False when `image` is a downsampled preview.
    var isFull: Bool
    var modified: Date?

    var cost: Int { image.bytesPerRow * image.height }
}

/// Decodes images off the main thread and keeps recent results in memory.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private final class Box {
        let value: LoadedImage
        init(_ value: LoadedImage) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()
    private var tasks: [String: Task<LoadedImage, Error>] = [:]
    /// What each window still needs. A decode goes on for as long as any window wants it.
    private var wanted: [ObjectIdentifier: Set<URL>] = [:]

    private init() {
        let memory = ProcessInfo.processInfo.physicalMemory
        cache.totalCostLimit = Int(min(memory / 8, 2 << 30))
    }

    private func key(_ url: URL, full: Bool) -> String {
        url.path(percentEncoded: false) + (full ? "|full" : "|preview")
    }

    private nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The best cached version, as long as the file has not changed since it was decoded.
    func cached(_ url: URL, requireFull: Bool = false) -> LoadedImage? {
        let candidates = requireFull ? [true] : [true, false]
        for full in candidates {
            guard let hit = cache.object(forKey: key(url, full: full) as NSString)?.value else { continue }
            if hit.modified == Self.modificationDate(url) { return hit }
            cache.removeObject(forKey: key(url, full: full) as NSString)
        }
        return nil
    }

    /// Decodes at most `maxPixel` along the longer edge; nil asks for the full image.
    func load(_ url: URL, maxPixel: Int?, priority: TaskPriority = .userInitiated) async throws -> LoadedImage {
        let wantsFull = maxPixel == nil
        if let hit = cached(url, requireFull: wantsFull) { return hit }
        let taskKey = key(url, full: wantsFull)
        if let running = tasks[taskKey] { return try await running.value }

        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try Self.decode(url, maxPixel: maxPixel)
        }
        tasks[taskKey] = task
        defer { tasks[taskKey] = nil }
        let loaded = try await task.value
        cache.setObject(Box(loaded), forKey: key(url, full: loaded.isFull) as NSString, cost: loaded.cost)
        return loaded
    }

    /// Warms the cache for images the user is likely to open next.
    func prefetch(_ urls: [URL], maxPixel: Int) {
        for url in urls where cached(url) == nil && tasks[key(url, full: false)] == nil {
            Task { _ = try? await load(url, maxPixel: maxPixel, priority: .utility) }
        }
    }

    /// Says which files a window needs now, and cancels the decodes that no window needs any more.
    func setWanted(_ urls: Set<URL>, by owner: AnyObject) {
        wanted[ObjectIdentifier(owner)] = urls
        let keep = wanted.values.reduce(into: Set<URL>()) { $0.formUnion($1) }
        let keepKeys = Set(keep.flatMap { [key($0, full: true), key($0, full: false)] })
        for (taskKey, task) in tasks where !keepKeys.contains(taskKey) {
            task.cancel()
        }
    }

    /// A window that closed wants nothing.
    func forget(_ owner: AnyObject) {
        wanted[ObjectIdentifier(owner)] = nil
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: key(url, full: true) as NSString)
        cache.removeObject(forKey: key(url, full: false) as NSString)
    }

    /// Carries what is cached for a file over to its new name.
    func move(_ old: URL, to new: URL) {
        for full in [true, false] {
            guard let box = cache.object(forKey: key(old, full: full) as NSString) else { continue }
            cache.setObject(box, forKey: key(new, full: full) as NSString, cost: box.value.cost)
            cache.removeObject(forKey: key(old, full: full) as NSString)
        }
    }

    private nonisolated static func decode(_ url: URL, maxPixel: Int?) throws -> LoadedImage {
        let source = try ImageSource(url: url)
        let longEdge = Int(max(source.info.pixelSize.width, source.info.pixelSize.height))
        // A preview only pays off when it is clearly smaller than the real thing.
        let full = maxPixel.map { Double(longEdge) <= Double($0) * 1.25 } ?? true
        let image = try source.image(maxPixelSize: full || source.info.isAnimated ? nil : maxPixel)
        return LoadedImage(
            image: image, info: source.info, isFull: full || source.info.isAnimated, modified: modificationDate(url)
        )
    }
}

/// Plays an animated image, decoding frames a little ahead of time.
@MainActor
final class AnimationPlayer {
    let source: ImageSource
    private let onFrame: (CGImage, Int) -> Void
    private var frames: [Int: CGImage] = [:]
    private var delays: [Int: TimeInterval] = [:]
    private var loop: Task<Void, Never>?
    private let keepsAllFrames: Bool
    private(set) var index = 0
    private(set) var isPlaying = false

    var frameCount: Int { source.info.frameCount }

    init(source: ImageSource, firstFrame: CGImage?, onFrame: @escaping (CGImage, Int) -> Void) {
        self.source = source
        self.onFrame = onFrame
        let bytes = Int(source.info.pixelSize.width * source.info.pixelSize.height) * 4 * source.info.frameCount
        keepsAllFrames = bytes <= 400 << 20
        if let firstFrame { frames[0] = firstFrame }
    }

    func play() {
        guard !isPlaying, frameCount > 1 else { return }
        isPlaying = true
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            var deadline = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.index
                guard let image = await self.frame(at: current), !Task.isCancelled else { return }
                self.onFrame(image, current)
                let next = (current + 1) % self.frameCount
                // Decode the following frame while this one is on screen.
                async let upcoming = self.frame(at: next)
                deadline = max(deadline, clock.now - .milliseconds(50)) + .seconds(self.delay(at: current))
                try? await clock.sleep(until: deadline)
                _ = await upcoming
                if Task.isCancelled { return }
                self.index = next
                self.trim(around: next)
            }
        }
    }

    func pause() {
        isPlaying = false
        loop?.cancel()
        loop = nil
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func step(by offset: Int) {
        pause()
        index = ((index + offset) % frameCount + frameCount) % frameCount
        let target = index
        Task { [weak self] in
            guard let self, let image = await self.frame(at: target), self.index == target else { return }
            self.onFrame(image, target)
        }
    }

    func stop() {
        pause()
        frames.removeAll()
    }

    private func delay(at index: Int) -> TimeInterval {
        if let known = delays[index] { return known }
        let value = source.delay(at: index)
        delays[index] = value
        return value
    }

    private func frame(at index: Int) async -> CGImage? {
        if let hit = frames[index] { return hit }
        let source = self.source
        let image = await Task.detached(priority: .userInitiated) { try? source.image(at: index) }.value
        if let image { frames[index] = image }
        return image
    }

    private func trim(around index: Int) {
        guard !keepsAllFrames else { return }
        let keep: Set<Int> = [index, (index + 1) % frameCount, (index + 2) % frameCount]
        frames = frames.filter { keep.contains($0.key) }
    }
}
