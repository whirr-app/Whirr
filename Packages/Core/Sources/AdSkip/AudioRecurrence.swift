import Foundation

/// Where an episode's audio recurs in another episode or a learned ad (`audiocand.py` `Library`
/// and `audio_runs`, refinement on). Every constant and comparison is the harness's; the parity
/// command must reproduce its runs to the frame.
///
/// The harness sorts every frame of the library into one in-memory index; this port streams
/// instead, reading every print once per query and keeping only the occurrences of the query's own
/// hashes. Same result; prints may be memory-mapped.
public enum AudioRecurrence {
  /// Frames in a block, about 1 s.
  public static let blockFrames = 86
  /// A block or refinement window matches below this bit error rate.
  public static let maximumBitErrorRate = 0.35
  /// Votes an offset needs within a chunk.
  public static let minimumVotes = 4
  /// Offsets tested per chunk, most votes first.
  public static let offsetsPerChunk = 20
  /// Frames in a voting chunk, about 20 s.
  public static let chunkFrames = 1720
  /// A hash occurring more often than this anywhere in the library never votes. An absolute
  /// count, tuned on a 108-copy library, not scaled to the library's size.
  public static let commonOccurrences = 300
  /// Frames in an edge-refinement window.
  public static let refinementFrames = 32

  /// One print in the library. Two references never match each other when their keys meet: an
  /// episode carries its own key and its linked copies', a learned ad its teachers'.
  public struct Reference: Sendable {
    public let print: AudioPrint
    public let keys: Set<EpisodeKey>

    public init(print: AudioPrint, keys: Set<EpisodeKey>) {
      self.print = print
      self.keys = keys
    }
  }

  /// Per 1 s block of the query: whether it recurs, and the reference and frame offset that
  /// first matched it (`Library.blocks`).
  struct Blocks {
    var hit: [Bool]
    var reference: [Int]
    var offset: [Int]
  }

  /// One reference's audio playing in the query: where in the query, in seconds.
  public struct Alignment: Equatable, Sendable {
    /// Index into the library.
    public let reference: Int
    public let span: TimeSpan

    public init(reference: Int, span: TimeSpan) {
      self.reference = reference
      self.span = span
    }
  }

  /// A query's runs and alignments from one vote.
  public struct Recurrence: Sendable {
    /// Exactly `runs(of:in:)`.
    public let runs: [TimeSpan]
    /// Every reference stretch the vote selects by reference then start.
    public let alignments: [Alignment]
  }

  /// The smaller of the two shares of each print that recurs in the other. Copies of one episode
  /// share almost all their audio, different episodes only the ads and jingles they have in
  /// common. Zero when either print is empty.
  public static func sharedFraction(of first: AudioPrint, and second: AudioPrint) -> Double {
    guard first.isEmpty == false, second.isEmpty == false else { return 0 }
    let pair = [
      Reference(print: first, keys: [EpisodeKey("first")]),
      Reference(print: second, keys: [EpisodeKey("second")]),
    ]
    func share(_ query: Int) -> Double {
      let seconds = runs(of: query, in: pair).reduce(0) { $0 + $1.duration }
      return seconds / (Double(pair[query].print.count) * AudioPrint.hopSeconds)
    }
    return min(share(0), share(1))
  }

  /// Stretches of recurring audio in `library[query]`, in seconds.
  public static func runs(of query: Int, in library: [Reference]) -> [TimeSpan] {
    runs(of: query, in: library, blocks: blocks(of: query, in: library))
  }

  /// Every alignment of `library[query]`. Unlike a run, an alignment ends where its reference's
  /// audio stops matching even if another reference's carries on, as one run can hold an ad and
  /// the different ad or shared programme next to it.
  ///
  /// Each (reference, offset) the vote selects for a chunk is tested against every block of the
  /// chunk and its neighbours, not only blocks an earlier candidate left unmatched. Offsets of one
  /// reference within two frames are pooled (drift between encodings of one recording) and refined
  /// at the offset that passed the most blocks.
  public static func alignments(of query: Int, in library: [Reference]) -> [Alignment] {
    recurrence(of: query, in: library).alignments
  }

  /// `runs` and `alignments` from one pass over the library.
  public static func recurrence(of query: Int, in library: [Reference]) -> Recurrence {
    var passing: [Int: [Int: Set<Int>]] = [:]
    let blocks = blocks(of: query, in: library) { reference, offset, block in
      passing[reference, default: [:]][offset, default: []].insert(block)
    }
    let runs = runs(of: query, in: library, blocks: blocks)
    let alignments = library[query].print.withWords { f in
      var alignments: [Alignment] = []
      for reference in passing.keys.sorted() {
        let byOffset = passing[reference] ?? [:]
        var pools: [[Int]] = []
        for offset in byOffset.keys.sorted() {
          if let last = pools.last?.last, offset - last <= 2 {
            pools[pools.count - 1].append(offset)
          } else {
            pools.append([offset])
          }
        }
        let print = library[reference].print
        for pool in pools {
          var blocks = Set<Int>()
          var offset = pool[0]
          var most = 0
          for candidate in pool {
            let passed = byOffset[candidate] ?? []
            blocks.formUnion(passed)
            if passed.count > most {
              offset = candidate
              most = passed.count
            }
          }
          let sorted = blocks.sorted()
          var i = 0
          while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            let ks = refinedStart(f, print, offset, sorted[i] * blockFrames)
            let ke = refinedEnd(f, print, offset, (sorted[j] + 1) * blockFrames)
            if ke > ks {
              alignments.append(
                Alignment(
                  reference: reference,
                  span: TimeSpan(start: AudioPrint.time(ofFrame: ks), end: AudioPrint.time(ofFrame: ke - 1))))
            }
            i = j + 1
          }
        }
      }
      return alignments.sorted {
        ($0.reference, $0.span.start, $0.span.end) < ($1.reference, $1.span.start, $1.span.end)
      }
    }
    return Recurrence(runs: runs, alignments: alignments)
  }

  private static func runs(of query: Int, in library: [Reference], blocks: Blocks) -> [TimeSpan] {
    library[query].print.withWords { f in
      var runs: [TimeSpan] = []
      let count = blocks.hit.count
      var b = 0
      while b < count {
        guard blocks.hit[b] else {
          b += 1
          continue
        }
        var e = b
        while e < count && blocks.hit[e] { e += 1 }
        let ks = refinedStart(
          f, library[blocks.reference[b]].print, blocks.offset[b], b * blockFrames)
        let ke = refinedEnd(
          f, library[blocks.reference[e - 1]].print, blocks.offset[e - 1], e * blockFrames)
        if ke > ks {
          runs.append(TimeSpan(start: AudioPrint.time(ofFrame: ks), end: AudioPrint.time(ofFrame: ke - 1)))
        }
        b = e
      }
      return runs
    }
  }

  /// A stretch's first frame, from its first block's: back while the window before still
  /// matches, at most a block, then forward past windows that do not.
  private static func refinedStart(
    _ f: UnsafeBufferPointer<UInt32>, _ reference: AudioPrint, _ offset: Int, _ low: Int
  ) -> Int {
    var k = low
    while k - 1 >= low - blockFrames
      && windowErrorRate(f, reference, offset, k - 1) < maximumBitErrorRate
    {
      k -= 1
    }
    while k < low + blockFrames && windowErrorRate(f, reference, offset, k) >= maximumBitErrorRate {
      k += 1
    }
    return k
  }

  /// A stretch's end frame, exclusive, from its last block's: the mirror of `refinedStart`.
  private static func refinedEnd(
    _ f: UnsafeBufferPointer<UInt32>, _ reference: AudioPrint, _ offset: Int, _ high: Int
  ) -> Int {
    let window = refinementFrames
    var k = high
    while k + 1 <= high + blockFrames
      && windowErrorRate(f, reference, offset, k + 1 - window) < maximumBitErrorRate
    {
      k += 1
    }
    while k > high - blockFrames
      && windowErrorRate(f, reference, offset, k - window) >= maximumBitErrorRate
    {
      k -= 1
    }
    return k
  }

  /// `Library.wber`: the bit error rate of the window at frame `k` of the query against the
  /// reference at `offset`, or 1 when either side runs out.
  private static func windowErrorRate(
    _ f: UnsafeBufferPointer<UInt32>, _ reference: AudioPrint, _ offset: Int, _ k: Int
  ) -> Double {
    let window = refinementFrames
    return reference.withWords { g in
      if k < 0 || k + window > f.count || k + offset < 0 || k + offset + window > g.count {
        return 1.0
      }
      var bits = 0
      for j in 0..<window { bits += (f[k + j] ^ g[k + offset + j]).nonzeroBitCount }
      return Double(bits) / Double(32 * window)
    }
  }

  /// `passed`, when given, hears every (reference, offset, block) that passes, including blocks
  /// an earlier candidate already matched; the blocks themselves are the same either way.
  static func blocks(
    of query: Int, in library: [Reference],
    passed: ((_ reference: Int, _ offset: Int, _ block: Int) -> Void)? = nil
  ) -> Blocks {
    library[query].print.withWords { f in
      let n = f.count
      let blockCount = n / blockFrames
      var result = Blocks(
        hit: [Bool](repeating: false, count: blockCount),
        reference: [Int](repeating: -1, count: blockCount),
        offset: [Int](repeating: 0, count: blockCount))
      let table = QueryTable(evenFramesOf: f)
      guard table.distinctCount > 0 else { return result }

      // Every occurrence of a query hash in the library is counted; occurrences in a reference
      // the query may match are kept until the hash proves common.
      var occurrences = [Int32](repeating: 0, count: table.distinctCount)
      var matches: [(distinct: Int32, reference: Int32, position: Int32)] = []
      let keys = library[query].keys
      for (index, reference) in library.enumerated() {
        let eligible = index != query && reference.keys.isDisjoint(with: keys)
        reference.print.withWords { g in
          for p in 0..<g.count {
            guard let d = table.distinctIndex(of: g[p]) else { continue }
            occurrences[d] += 1
            if eligible && occurrences[d] <= Int32(commonOccurrences) {
              matches.append((Int32(d), Int32(index), Int32(p)))
            }
          }
        }
      }

      // Votes for (chunk, reference, offset), keyed so that sorting the keys orders them as the
      // harness's packed key does: chunk, then reference, then offset.
      var votes: [UInt64: Int32] = [:]
      for match in matches where occurrences[Int(match.distinct)] <= Int32(commonOccurrences) {
        for i in table.positions(ofDistinct: Int(match.distinct)) {
          let offset = Int(match.position) - i
          votes[voteKey(chunk: i / chunkFrames, reference: Int(match.reference), offset: offset), default: 0] += 1
        }
      }
      var selected = votes.filter { $0.value >= Int32(minimumVotes) }.map { (key: $0.key, votes: $0.value) }
      // `np.lexsort((-votes, ch))` over keys in ascending order: chunk, most votes, key.
      selected.sort {
        let lc = chunk(of: $0.key)
        let rc = chunk(of: $1.key)
        if lc != rc { return lc < rc }
        if $0.votes != $1.votes { return $0.votes > $1.votes }
        return $0.key < $1.key
      }

      var rank = 0
      var previousChunk = -1
      for entry in selected {
        let c = chunk(of: entry.key)
        rank = c == previousChunk ? rank + 1 : 0
        previousChunk = c
        guard rank < offsetsPerChunk else { continue }
        let t = referenceIndex(of: entry.key)
        let o = offset(of: entry.key)
        library[t].print.withWords { g in
          let b0 = max(0, c == 0 ? 0 : ((c - 1) * chunkFrames) / blockFrames)
          let b1 = min(blockCount, ((c + 2) * chunkFrames) / blockFrames + 1)
          guard b0 < b1 else { return }
          for b in b0..<b1 where result.hit[b] == false || passed != nil {
            let a0 = b * blockFrames
            let t0 = a0 + o
            guard t0 >= 0 && t0 + blockFrames <= g.count else { continue }
            var bits = 0
            for j in 0..<blockFrames { bits += (f[a0 + j] ^ g[t0 + j]).nonzeroBitCount }
            if Double(bits) / Double(32 * blockFrames) < maximumBitErrorRate {
              passed?(t, o, b)
              if result.hit[b] == false {
                result.hit[b] = true
                result.reference[b] = t
                result.offset[b] = o
              }
            }
          }
        }
      }
      return result
    }
  }

  private static let offsetBias = 1 << 23

  private static func voteKey(chunk: Int, reference: Int, offset: Int) -> UInt64 {
    precondition(reference < 1 << 20 && abs(offset) < offsetBias && chunk < 1 << 20)
    return UInt64(chunk) << 44 | UInt64(reference) << 24 | UInt64(offset + offsetBias)
  }

  private static func chunk(of key: UInt64) -> Int { Int(key >> 44) }
  private static func referenceIndex(of key: UInt64) -> Int { Int((key >> 24) & 0xF_FFFF) }
  private static func offset(of key: UInt64) -> Int { Int(key & 0xFF_FFFF) - offsetBias }
}

/// The query's even frames by hash (`idx = np.arange(0, n, 2)`), with a bitmap that rejects most
/// library frames before the hash lookup.
private struct QueryTable {
  private var slots: [Int32]
  private var slotKeys: [UInt32]
  private let mask: Int
  private var bitmap: [UInt64]
  /// Even-frame positions grouped by distinct hash: `positions[starts[d]..<starts[d + 1]]`.
  private var starts: [Int]
  private var positionList: [Int]
  private(set) var distinctCount = 0

  init(evenFramesOf f: UnsafeBufferPointer<UInt32>) {
    let evenCount = (f.count + 1) / 2
    var capacity = 16
    while capacity < evenCount * 2 { capacity <<= 1 }
    slots = [Int32](repeating: -1, count: capacity)
    slotKeys = [UInt32](repeating: 0, count: capacity)
    mask = capacity - 1
    bitmap = [UInt64](repeating: 0, count: (1 << 24) / 64)
    var distinctOf = [Int32](repeating: 0, count: evenCount)
    var hashes: [UInt32] = []
    for e in 0..<evenCount {
      let h = f[e * 2]
      var slot = Self.slot(of: h, mask: mask)
      while slots[slot] >= 0 && slotKeys[slot] != h { slot = (slot + 1) & mask }
      if slots[slot] < 0 {
        slots[slot] = Int32(hashes.count)
        slotKeys[slot] = h
        hashes.append(h)
        let bit = Int(h >> 8)
        bitmap[bit >> 6] |= 1 << UInt64(bit & 63)
      }
      distinctOf[e] = slots[slot]
    }
    distinctCount = hashes.count
    var counts = [Int](repeating: 0, count: hashes.count + 1)
    for d in distinctOf { counts[Int(d) + 1] += 1 }
    for d in 0..<hashes.count { counts[d + 1] += counts[d] }
    starts = counts
    var fill = counts
    positionList = [Int](repeating: 0, count: evenCount)
    for e in 0..<evenCount {
      let d = Int(distinctOf[e])
      positionList[fill[d]] = e * 2
      fill[d] += 1
    }
  }

  private static func slot(of hash: UInt32, mask: Int) -> Int {
    Int(truncatingIfNeeded: (UInt64(hash) &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
  }

  @inline(__always)
  func distinctIndex(of hash: UInt32) -> Int? {
    let bit = Int(hash >> 8)
    guard bitmap[bit >> 6] & (1 << UInt64(bit & 63)) != 0 else { return nil }
    var slot = Self.slot(of: hash, mask: mask)
    while true {
      let value = slots[slot]
      if value < 0 { return nil }
      if slotKeys[slot] == hash { return Int(value) }
      slot = (slot + 1) & mask
    }
  }

  /// Even frames holding distinct hash `d`, ascending.
  func positions(ofDistinct d: Int) -> ArraySlice<Int> {
    positionList[starts[d]..<starts[d + 1]]
  }
}
