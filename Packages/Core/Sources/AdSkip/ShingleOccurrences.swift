import Foundation

/// Which episodes contain each shingle hash, as two parallel arrays sorted by (hash, ordinal):
/// 12 bytes an occurrence, against roughly 60 for nested dictionaries. Ordinals are positions in
/// the sorted `keys`. Parallel because a `(UInt64, Int32)` pair strides 16 bytes and the search
/// only needs the hashes.
public struct ShingleOccurrences: Sendable, Equatable {
  /// Every episode key, sorted; an episode's ordinal is its index here.
  public let keys: [EpisodeKey]
  /// Each episode's distinct-hash count, by ordinal.
  public let hashCounts: [Int]
  let hashes: [UInt64]
  let ordinals: [Int32]

  /// Adds episodes one at a time so a caller can release each episode's hashes immediately.
  public struct Builder {
    private var keys: [EpisodeKey] = []
    private var counts: [Int] = []
    private var entries: [Entry] = []
    private var seen: Set<EpisodeKey> = []

    fileprivate struct Entry {
      var hash: UInt64
      var ordinal: Int32
    }

    public init() {}

    /// `hashes` must be distinct. A duplicate `key` is a programmer error.
    public mutating func add(_ key: EpisodeKey, hashes: some Collection<UInt64>) {
      precondition(seen.insert(key).inserted, "duplicate episode key")
      let ordinal = Int32(keys.count)
      keys.append(key)
      counts.append(hashes.count)
      // No `reserveCapacity` per episode: reserving exactly defeats geometric growth, and each add
      // then reallocates the whole table (a 3.7 GB peak at 300 episodes against 243 MB without).
      for hash in hashes { entries.append(Entry(hash: hash, ordinal: ordinal)) }
    }

    /// Re-numbers ordinals into sorted key order, then sorts by (hash, ordinal).
    public consuming func build() -> ShingleOccurrences {
      let order = keys.indices.sorted { keys[$0] < keys[$1] }
      var rank = [Int32](repeating: 0, count: keys.count)
      for (sorted, original) in order.enumerated() { rank[original] = Int32(sorted) }
      for i in entries.indices { entries[i].ordinal = rank[Int(entries[i].ordinal)] }
      entries.sort { ($0.hash, $0.ordinal) < ($1.hash, $1.ordinal) }
      var hashes: [UInt64] = []
      var ordinals: [Int32] = []
      hashes.reserveCapacity(entries.count)
      ordinals.reserveCapacity(entries.count)
      for entry in entries {
        hashes.append(entry.hash)
        ordinals.append(entry.ordinal)
      }
      entries = []
      return ShingleOccurrences(
        keys: order.map { keys[$0] }, hashCounts: order.map { counts[$0] }, hashes: hashes,
        ordinals: ordinals)
    }
  }

  init(keys: [EpisodeKey], hashCounts: [Int], hashes: [UInt64], ordinals: [Int32]) {
    self.keys = keys
    self.hashCounts = hashCounts
    self.hashes = hashes
    self.ordinals = ordinals
  }

  public init(shingles: [EpisodeKey: Set<UInt64>]) {
    var builder = Builder()
    for (key, set) in shingles { builder.add(key, hashes: set) }
    self = builder.build()
  }

  /// Total (hash, episode) pairs.
  public var count: Int { hashes.count }

  /// Positions in the table holding `hash`; empty when absent. Ordinals ascend within the range.
  func run(of hash: UInt64) -> Range<Int> {
    var low = 0
    var high = hashes.count
    while low < high {
      let mid = (low + high) >> 1
      if hashes[mid] < hash { low = mid + 1 } else { high = mid }
    }
    var end = low
    while end < hashes.count && hashes[end] == hash { end += 1 }
    return low..<end
  }

  func ordinal(at position: Int) -> Int { Int(ordinals[position]) }

  /// Calls `body` with each maximal run of equal hashes that has at least two owners.
  func forEachSharedRun(_ body: (Range<Int>) -> Void) {
    var start = 0
    while start < hashes.count {
      var end = start + 1
      while end < hashes.count && hashes[end] == hashes[start] { end += 1 }
      if end - start > 1 { body(start..<end) }
      start = end
    }
  }
}
