import Testing
@testable import PixixCodec

@Test func recentCacheLetsGoOfTheOldestFirst() {
    var cache = RecentCache<String, Int>(costLimit: 100, countLimit: 10)
    cache.insert(1, for: "a", cost: 30)
    cache.insert(2, for: "b", cost: 30)
    cache.insert(3, for: "c", cost: 30)
    // Using "a" makes "b" the oldest.
    #expect(cache.value(for: "a") == 1)
    cache.insert(4, for: "d", cost: 30)
    #expect(cache.peek("b") == nil)
    #expect(Set(cache.keys) == ["a", "c", "d"])
    #expect(cache.totalCost == 90)
}

@Test func recentCacheKeepsToItsCount() {
    var cache = RecentCache<Int, Int>(costLimit: 1000, countLimit: 3)
    for key in 1...5 { cache.insert(key, for: key, cost: 1) }
    #expect(Set(cache.keys) == [3, 4, 5])
    #expect(cache.totalCost == 3)
}

@Test func recentCacheRefusesWhatWouldCrowdOutTheRest() {
    var cache = RecentCache<String, Int>(costLimit: 100, countLimit: 10)
    cache.insert(1, for: "small", cost: 20)
    let storedHuge = cache.insert(2, for: "huge", cost: 60)
    #expect(!storedHuge)
    #expect(cache.peek("huge") == nil)
    #expect(cache.peek("small") == 1)
    // Half of the limit is still allowed.
    let storedHalf = cache.insert(3, for: "half", cost: 50)
    #expect(storedHalf)
}

@Test func recentCacheReplacesAndRemoves() {
    var cache = RecentCache<String, Int>(costLimit: 100, countLimit: 10)
    cache.insert(1, for: "a", cost: 10)
    cache.insert(2, for: "a", cost: 25)
    #expect(cache.peek("a") == 2)
    #expect(cache.totalCost == 25)
    // A replacement that is too large leaves nothing behind under the old key.
    cache.insert(3, for: "a", cost: 80)
    #expect(cache.peek("a") == nil)
    #expect(cache.totalCost == 0)

    for key in ["x|full", "x|preview", "y|full"] { cache.insert(0, for: key, cost: 5) }
    cache.removeAll { $0.hasPrefix("x|") }
    #expect(cache.keys == ["y|full"])
    #expect(cache.totalCost == 5)
    cache.removeAll()
    #expect(cache.count == 0)
    #expect(cache.totalCost == 0)
}
