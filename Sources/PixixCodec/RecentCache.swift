/// Keeps values up to a total cost and a number of entries, and lets go of the one used longest ago first.
///
/// Unlike `NSCache` it drops nothing behind its owner's back and says what it holds, so the owner can empty it
/// when what it holds is no longer of use. Not thread-safe: the owner keeps it on one thread or actor.
public struct RecentCache<Key: Hashable, Value> {
    public let costLimit: Int
    public let countLimit: Int
    public private(set) var totalCost = 0

    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    public init(costLimit: Int, countLimit: Int) {
        self.costLimit = max(costLimit, 0)
        self.countLimit = max(countLimit, 1)
    }

    public var count: Int { entries.count }
    public var keys: [Key] { Array(entries.keys) }

    /// The value, which counts as used just now.
    public mutating func value(for key: Key) -> Value? {
        guard entries[key] != nil else { return nil }
        clock += 1
        entries[key]?.lastUse = clock
        return entries[key]?.value
    }

    /// The value, leaving the order of use as it was.
    public func peek(_ key: Key) -> Value? { entries[key]?.value }

    /// Stores a value and lets go of the oldest ones until the limits hold again. A value that would take more
    /// than half of the cost limit is not stored and pushes nothing out: keeping it would cost everything else.
    /// Returns whether the value was stored.
    @discardableResult
    public mutating func insert(_ value: Value, for key: Key, cost: Int) -> Bool {
        removeValue(for: key)
        guard cost <= costLimit / 2 else { return false }
        clock += 1
        entries[key] = Entry(value: value, cost: cost, lastUse: clock)
        totalCost += cost
        while totalCost > costLimit || entries.count > countLimit {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            removeValue(for: oldest)
        }
        return true
    }

    @discardableResult
    public mutating func removeValue(for key: Key) -> Value? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        totalCost -= entry.cost
        return entry.value
    }

    public mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in entries.keys where shouldRemove(key) { removeValue(for: key) }
    }

    public mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }
}
