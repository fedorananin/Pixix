import AppKit
import PixixCodec

/// A decoded image together with what is known about its file.
struct LoadedImage: Sendable {
    var image: CGImage
    /// Where the pixels of `image` are when they are in an IOSurface, which the canvas shows instead.
    var surface: IOSurface?
    var info: ImageInfo
    /// False when `image` is a downsampled preview.
    var isFull: Bool
    var modified: Date?

    /// What the picture may take in memory once it has been on screen: its pixels, and as much again for a copy
    /// Core Animation can make to show them and keep for as long as the image lives. Pictures decoded the way
    /// `ImageSource` does it now are shown without one, so this errs on the side of keeping fewer.
    var cost: Int { image.bytesPerRow * image.height * 2 }
}

/// Decodes images off the main thread and keeps recent results in memory, for the windows that are open.
///
/// The cache is there to make flipping back and forth instant, not to remember a whole folder: a decode takes
/// a fraction of a second, and a picture that takes more than half the limit is not kept at all. The window
/// on screen holds its own picture, so nothing it shows depends on the cache. When a window closes, what only it
/// wanted goes, and with the last window everything goes, because with the menu bar icon the process can wait for
/// days. When macOS runs short of memory it goes too.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private var cache: RecentCache<String, LoadedImage>
    private var tasks: [String: Task<LoadedImage, Error>] = [:]
    /// What each window still needs. A decode goes on for as long as any window wants it.
    private var wanted: [ObjectIdentifier: Set<URL>] = [:]
    private var pressure: DispatchSourceMemoryPressure?

    private init() {
        let memory = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        // A sixteenth of the memory, at most 1 GB: the current picture at full size, the previews of its
        // neighbors and a few pictures seen just before.
        cache = RecentCache(costLimit: min(memory / 16, 1 << 30), countLimit: 24)
        // Decoded pictures are the cheapest memory there is to give back: they can be read again.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.cache.removeAll() }
        }
        source.resume()
        pressure = source
    }

    private func key(_ url: URL, full: Bool) -> String {
        url.path(percentEncoded: false) + (full ? "|full" : "|preview")
    }

    nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The best cached version, as long as the file has not changed since it was decoded.
    func cached(_ url: URL, requireFull: Bool = false) -> LoadedImage? {
        let candidates = requireFull ? [true] : [true, false]
        for full in candidates {
            guard let hit = cache.value(for: key(url, full: full)) else { continue }
            if hit.modified == Self.modificationDate(url) { return hit }
            cache.removeValue(for: key(url, full: full))
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
        defer { if tasks[taskKey] == task { tasks[taskKey] = nil } }
        let loaded = try await task.value
        // A decode that was cancelled halfway still finishes, but nobody wants what it made any more.
        if !task.isCancelled {
            cache.insert(loaded, for: key(url, full: loaded.isFull), cost: loaded.cost)
        }
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
        cancelUnwanted()
    }

    /// A window that closed wants nothing. What no other window wants goes with it.
    func forget(_ owner: AnyObject) {
        wanted[ObjectIdentifier(owner)] = nil
        let keep = cancelUnwanted()
        cache.removeAll { !keep.contains($0) }
    }

    /// Cancels every decode no window wants. Returns the keys that are still wanted.
    @discardableResult
    private func cancelUnwanted() -> Set<String> {
        let urls = wanted.values.reduce(into: Set<URL>()) { $0.formUnion($1) }
        let keep = Set(urls.flatMap { [key($0, full: true), key($0, full: false)] })
        for (taskKey, task) in tasks where !keep.contains(taskKey) {
            task.cancel()
        }
        return keep
    }

    func invalidate(_ url: URL) {
        cache.removeValue(for: key(url, full: true))
        cache.removeValue(for: key(url, full: false))
    }

    /// Carries what is cached for a file over to its new name.
    func move(_ old: URL, to new: URL) {
        for full in [true, false] {
            guard let loaded = cache.removeValue(for: key(old, full: full)) else { continue }
            cache.insert(loaded, for: key(new, full: full), cost: loaded.cost)
        }
    }

    /// What the cache holds, for the diagnostic scenarios.
    var summary: String {
        "\(cache.count) picture(s), \(cache.totalCost >> 20) MB"
    }

    private nonisolated static func decode(_ url: URL, maxPixel: Int?) throws -> LoadedImage {
        let source = try ImageSource(url: url)
        let longEdge = Int(max(source.info.pixelSize.width, source.info.pixelSize.height))
        // A preview only pays off when it is clearly smaller than the real thing.
        let full = maxPixel.map { Double(longEdge) <= Double($0) * 1.25 } ?? true
        let decoded = try source.decoded(maxPixelSize: full || source.info.isAnimated ? nil : maxPixel)
        return LoadedImage(
            image: decoded.image, surface: decoded.surface, info: source.info, isFull: full || source.info.isAnimated,
            modified: modificationDate(url)
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
