import Foundation
import PixixCodec

/// The list of images being browsed and the position in it.
@MainActor
final class FolderBrowser {
    private(set) var files: [URL]
    private(set) var index: Int = 0
    /// Called when the list or the position changes. The flag says whether the current file changed.
    var onChange: ((_ currentChanged: Bool) -> Void)?

    /// True when the list is a whole folder rather than files the user picked explicitly.
    private let followsFolder: Bool
    private var folder: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var rescanTask: Task<Void, Never>?

    var current: URL? { files.indices.contains(index) ? files[index] : nil }
    var count: Int { files.count }

    init(urls: [URL]) {
        files = urls
        followsFolder = urls.count == 1
        if followsFolder, let first = urls.first {
            folder = first.deletingLastPathComponent()
            startWatching()
            rescan()
        }
    }

    // The watcher's cancel handler closes the descriptor once the source is released.

    func stop() {
        watcher?.cancel()
        watcher = nil
        rescanTask?.cancel()
    }

    func neighbor(offset: Int, wrap: Bool) -> URL? {
        guard !files.isEmpty else { return nil }
        var target = index + offset
        if wrap, files.count > 1 {
            target = ((target % files.count) + files.count) % files.count
        }
        return files.indices.contains(target) ? files[target] : nil
    }

    @discardableResult
    func move(by offset: Int, wrap: Bool) -> Bool {
        guard files.count > 1 else { return false }
        var target = index + offset
        if wrap {
            target = ((target % files.count) + files.count) % files.count
        } else {
            target = min(max(target, 0), files.count - 1)
        }
        return go(to: target)
    }

    @discardableResult
    func go(to target: Int) -> Bool {
        guard files.indices.contains(target), target != index else { return false }
        index = target
        onChange?(true)
        return true
    }

    /// Drops a file that was deleted and moves to the nearest remaining one.
    func remove(_ url: URL) {
        guard let position = files.firstIndex(of: url) else { return }
        let wasCurrent = position == index
        files.remove(at: position)
        if position < index || index >= files.count { index = max(0, index - 1) }
        onChange?(wasCurrent)
    }

    /// Puts a file into the list, for example after undoing a deletion or saving a copy.
    func insert(_ url: URL, select: Bool) {
        if !files.contains(url) {
            files.append(url)
            sortKeepingCurrent(preferred: select ? url : current)
        } else if select, let position = files.firstIndex(of: url) {
            index = position
        }
        onChange?(select)
    }

    private func sortKeepingCurrent(preferred: URL?) {
        guard followsFolder else {
            if let preferred, let position = files.firstIndex(of: preferred) { index = position }
            return
        }
        files = Self.sorted(files, order: Settings.shared.sortOrder, descending: Settings.shared.sortDescending)
        if let preferred, let position = files.firstIndex(of: preferred) { index = position }
    }

    /// Reads the folder again, keeping the current file selected.
    func rescan() {
        guard followsFolder, let folder else { return }
        let order = Settings.shared.sortOrder
        let descending = Settings.shared.sortDescending
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            let listed = await Task.detached(priority: .userInitiated) {
                Self.list(folder: folder, order: order, descending: descending)
            }.value
            guard let self, !Task.isCancelled else { return }
            let previous = self.current
            guard listed != self.files else { return }
            if let previous, let position = listed.firstIndex(of: previous) {
                self.files = listed
                self.index = position
                self.onChange?(false)
            } else if let previous, FileManager.default.fileExists(atPath: previous.path(percentEncoded: false)) {
                // The current file is not something we would list (odd extension); keep showing it.
                self.files = listed + [previous]
                self.index = listed.count
                self.onChange?(false)
            } else {
                self.files = listed
                self.index = min(self.index, max(0, listed.count - 1))
                self.onChange?(true)
            }
        }
    }

    nonisolated static func list(folder: URL, order: SortOrder, descending: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return sorted(contents.filter { ReadableTypes.isReadable($0) }, order: order, descending: descending)
    }

    nonisolated static func sorted(_ urls: [URL], order: SortOrder, descending: Bool) -> [URL] {
        func name(_ a: URL, _ b: URL) -> Bool {
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        let result: [URL]
        switch order {
        case .name:
            result = urls.sorted(by: name)
        case .dateModified, .dateCreated:
            let key: URLResourceKey = order == .dateModified ? .contentModificationDateKey : .creationDateKey
            let dated = urls.map { url -> (URL, Date) in
                let values = try? url.resourceValues(forKeys: [key])
                let date = order == .dateModified ? values?.contentModificationDate : values?.creationDate
                return (url, date ?? .distantPast)
            }
            result = dated.sorted { $0.1 == $1.1 ? name($0.0, $1.0) : $0.1 < $1.1 }.map(\.0)
        case .size:
            let sized = urls.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            result = sized.sorted { $0.1 == $1.1 ? name($0.0, $1.0) : $0.1 < $1.1 }.map(\.0)
        }
        return descending ? result.reversed() : result
    }

    private func startWatching() {
        guard let folder else { return }
        let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private var pendingRescan: DispatchWorkItem?

    private func scheduleRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
