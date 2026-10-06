import Foundation

/// A linear undo list. Entries are closures, so any kind of change can be recorded.
@MainActor
public final class History {
    public struct Entry: Identifiable {
        public let id = UUID()
        public let name: String
        /// Rough memory held by the entry, in bytes.
        let cost: Int
        let key: String?
        let undo: () -> Void
        let redo: () -> Void
    }

    public private(set) var entries: [Entry] = []
    /// Number of entries currently applied.
    public private(set) var position = 0
    public var onChange: (() -> Void)?

    private var savedEntry: UUID?
    private var savedAtStart = true
    private var isSealed = true

    public var memoryBudget = 3 << 30
    public var maxEntries = 300

    public init() {}

    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position < entries.count }
    public var undoName: String? { canUndo ? entries[position - 1].name : nil }
    public var redoName: String? { canRedo ? entries[position].name : nil }

    /// True when the document differs from what was last saved.
    public var isDirty: Bool {
        if position == 0 { return !savedAtStart }
        return entries[position - 1].id != savedEntry
    }

    public func markSaved() {
        savedAtStart = position == 0
        savedEntry = position > 0 ? entries[position - 1].id : nil
        isSealed = true
        onChange?()
    }

    /// Records a change that has already been applied.
    /// Consecutive records with the same `key` collapse into one step, so a slider drag is a single undo.
    public func record(name: String, cost: Int = 0, key: String? = nil, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        if let key, !isSealed, position == entries.count, let last = entries.last, last.key == key {
            entries[entries.count - 1] = Entry(name: name, cost: max(cost, last.cost), key: key, undo: last.undo, redo: redo)
            onChange?()
            return
        }
        if position < entries.count {
            // Recording after an undo drops the redo branch. If the saved state was in it, it is gone for good.
            if let savedEntry, entries[position...].contains(where: { $0.id == savedEntry }) {
                self.savedEntry = nil
                savedAtStart = false
            }
            entries.removeSubrange(position...)
        }
        entries.append(Entry(name: name, cost: cost, key: key, undo: undo, redo: redo))
        position = entries.count
        isSealed = false
        trim()
        onChange?()
    }

    /// Ends the current run of mergeable records, for example when a slider is released.
    public func seal() {
        isSealed = true
    }

    private func trim() {
        var total = entries.reduce(0) { $0 + $1.cost }
        while entries.count > 1, entries.count > maxEntries || total > memoryBudget {
            total -= entries[0].cost
            if position == 1, savedAtStart { savedAtStart = false }
            entries.removeFirst()
            position -= 1
            // The initial state can no longer be reached.
            savedAtStart = false
        }
    }

    public func undo() {
        guard canUndo else { return }
        isSealed = true
        position -= 1
        entries[position].undo()
        onChange?()
    }

    public func redo() {
        guard canRedo else { return }
        isSealed = true
        entries[position].redo()
        position += 1
        onChange?()
    }

    /// Moves to the state after `count` entries, undoing or redoing as needed.
    public func jump(to count: Int) {
        let target = min(max(count, 0), entries.count)
        isSealed = true
        while position > target {
            position -= 1
            entries[position].undo()
        }
        while position < target {
            entries[position].redo()
            position += 1
        }
        onChange?()
    }
}
