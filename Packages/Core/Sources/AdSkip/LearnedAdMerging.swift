import Foundation

/// When two learned ads are one advertisement, and what the merged ad is. Every episode that
/// carries an ad would otherwise teach its own copy.
public enum LearnedAdMerging {
  /// The share of the smaller hash set two ads must hold in common.
  public static let hashOverlap = 0.8
  /// The share of the shorter print's audio that must recur in the longer.
  public static let audioShare = 0.8
  /// The backup file's limits (`PodcastLearnedAdsSnapshot`), which this target cannot see. An ad
  /// past the hash limit is left out of a backup whole, so an absorb that would pass it is refused.
  public static let maximumTeachers = 256
  public static let maximumHashes = 20_000

  /// What the rule compares.
  public struct Content: Sendable {
    public var hashes: Set<UInt64>
    public var print: AudioPrint?

    public init(hashes: Set<UInt64>, print: AudioPrint?) {
      self.hashes = hashes
      self.print = print.flatMap { $0.isEmpty ? nil : $0 }
    }
  }

  /// Whether two learned ads are the same ad. Hash overlap alone merges two different breaks that
  /// share one advertisement, so the audio must agree too; an ad without a print has only its
  /// hashes to go by.
  public static func isSameAd(_ first: Content, _ second: Content) -> Bool {
    let smaller = min(first.hashes.count, second.hashes.count)
    guard smaller > 0 else { return false }
    let (few, many) =
      first.hashes.count <= second.hashes.count
      ? (first.hashes, second.hashes) : (second.hashes, first.hashes)
    let shared = few.reduce(0) { $0 + (many.contains($1) ? 1 : 0) }
    guard Double(shared) >= hashOverlap * Double(smaller) else { return false }
    guard let a = first.print, let b = second.print else { return true }
    let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
    return AudioRecurrence.share(of: shorter, foundIn: longer) >= audioShare
  }

  /// Whether `candidate`'s print should be the merged ad's rather than `incumbent`'s: the longer
  /// print holds almost all of the other's audio, and a print beats none. A tie keeps the incumbent.
  public static func outlives(_ candidate: AudioPrint?, _ incumbent: AudioPrint?) -> Bool {
    (candidate?.count ?? 0) > (incumbent?.count ?? 0)
  }

  /// Whether an ad holding `hashes` may take in `more`.
  public static func canAbsorb(_ more: Set<UInt64>, into hashes: Set<UInt64>) -> Bool {
    hashes.count + more.count <= maximumHashes || hashes.union(more).count <= maximumHashes
  }

  /// The survivor's teachers after absorbing an ad taught by `more`: the union, in key order past
  /// the survivor's own, up to `maximumTeachers`.
  public static func teachers(_ teachers: Set<EpisodeKey>, adding more: Set<EpisodeKey>) -> Set<EpisodeKey> {
    var result = teachers
    for key in more.subtracting(teachers).sorted(by: { $0.rawValue < $1.rawValue }) {
      guard result.count < maximumTeachers else { break }
      result.insert(key)
    }
    return result
  }

  public struct Collapse: Sendable {
    /// The store with every group of same ads merged into one, in id order. Tombstones, confirmed
    /// ads and ads that merged with nothing are as given.
    public var creatives: [SignatureCreative]
    /// Each ad that was merged away, and the ad that holds it now.
    public var absorbed: [Int64: Int64]
  }

  /// Merges every unconfirmed learned ad into the ads it is the same as, in ascending id order,
  /// until no two survivors are the same ad. The survivor is the ad with the longest print and keeps its id,
  /// print, start and end; it gains the others' hashes and teachers and the latest `lastSeen`.
  ///
  /// A confirmed ad is left as it is: it is never a survivor, never absorbed, and takes in nothing.
  ///
  /// The rule compares pairs, so A can match B and B match C while A and C do not, and the result
  /// depends on id order. It is stable for a given store, and collapsing a collapsed store is a
  /// no-op.
  public static func collapse(_ creatives: [SignatureCreative], prints: [Int64: AudioPrint]) -> Collapse {
    struct Entry {
      var creative: SignatureCreative
      var print: AudioPrint?
    }
    var entries: [Entry?] = []
    var slotsByHash: [UInt64: [Int]] = [:]
    var absorbed: [Int64: Int64] = [:]

    /// Slots holding an ad the entry at `slot` is the same as and may be merged with.
    func matches(of slot: Int) -> [Int] {
      guard let entry = entries[slot] else { return [] }
      var shared: [Int: Int] = [:]
      for hash in entry.creative.hashes {
        for other in slotsByHash[hash] ?? [] where other != slot { shared[other, default: 0] += 1 }
      }
      let content = Content(hashes: entry.creative.hashes, print: entry.print)
      return shared.keys.sorted().filter { other in
        guard let candidate = entries[other] else { return false }
        let smaller = min(entry.creative.hashes.count, candidate.creative.hashes.count)
        guard Double(shared[other] ?? 0) >= hashOverlap * Double(smaller) else { return false }
        return canAbsorb(candidate.creative.hashes, into: entry.creative.hashes)
          && isSameAd(content, Content(hashes: candidate.creative.hashes, print: candidate.print))
      }
    }

    for creative in creatives.sorted(by: { $0.id < $1.id })
    where creative.kind == .learned && creative.confirmed == false {
      var slot = entries.count
      entries.append(Entry(creative: creative, print: prints[creative.id].flatMap { $0.isEmpty ? nil : $0 }))
      for hash in creative.hashes { slotsByHash[hash, default: []].append(slot) }
      // A merged ad holds more than either part did, so it is asked again until nothing joins it.
      while true {
        let others = matches(of: slot)
        guard others.isEmpty == false, var merged = entries[slot] else { break }
        var survivor = slot
        for other in others {
          // Each was the same as the ad that started this round. Once one has merged in, the next
          // must be the same as the result too, or one short ad would join two different breaks
          // that share nothing else.
          guard let candidate = entries[other],
            canAbsorb(candidate.creative.hashes, into: merged.creative.hashes),
            isSameAd(
              Content(hashes: merged.creative.hashes, print: merged.print),
              Content(hashes: candidate.creative.hashes, print: candidate.print))
          else { continue }
          let takesOver =
            outlives(candidate.print, merged.print)
            || (outlives(merged.print, candidate.print) == false && candidate.creative.id < merged.creative.id)
          let (kept, gone) = takesOver ? (candidate, merged) : (merged, candidate)
          merged = Entry(
            creative: SignatureCreative(
              id: kept.creative.id, kind: .learned,
              lastSeen: max(kept.creative.lastSeen, gone.creative.lastSeen),
              start: kept.creative.start, end: kept.creative.end,
              teachers: teachers(kept.creative.teachers, adding: gone.creative.teachers),
              hashes: kept.creative.hashes.union(gone.creative.hashes)),
            print: kept.print)
          absorbed[gone.creative.id] = kept.creative.id
          for (key, value) in absorbed where value == gone.creative.id { absorbed[key] = kept.creative.id }
          if takesOver {
            entries[survivor] = nil
            survivor = other
          } else {
            entries[other] = nil
          }
        }
        entries[survivor] = merged
        for hash in merged.creative.hashes where slotsByHash[hash]?.contains(survivor) != true {
          slotsByHash[hash, default: []].append(survivor)
        }
        slot = survivor
      }
    }

    let merged = entries.compactMap { $0?.creative }
    let result = (creatives.filter { $0.kind != .learned || $0.confirmed } + merged).sorted {
      $0.id < $1.id
    }
    return Collapse(creatives: result, absorbed: absorbed)
  }
}

extension AudioRecurrence {
  /// The share of `print`'s audio that recurs in `other`. Unlike `sharedFraction`, which takes the
  /// smaller of the two shares, a short ad wholly inside a long break scores near 1. Zero when
  /// either print is empty.
  public static func share(of print: AudioPrint, foundIn other: AudioPrint) -> Double {
    guard print.isEmpty == false, other.isEmpty == false else { return 0 }
    let pair = [
      Reference(print: print, keys: [EpisodeKey("first")]),
      Reference(print: other, keys: [EpisodeKey("second")]),
    ]
    let seconds = runs(of: 0, in: pair).reduce(0) { $0 + $1.duration }
    return seconds / (Double(print.count) * AudioPrint.hopSeconds)
  }
}
