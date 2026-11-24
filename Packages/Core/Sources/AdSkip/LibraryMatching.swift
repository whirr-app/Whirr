import Foundation

/// Which on-device episodes contain each shingle hash.
public struct LibraryIndex: Sendable {
  private let occurrences: ShingleOccurrences

  public init(shingles: [EpisodeKey: Set<UInt64>]) {
    self.init(occurrences: ShingleOccurrences(shingles: shingles))
  }

  public init(occurrences: ShingleOccurrences) {
    self.occurrences = occurrences
  }

  /// True when an episode outside `group` contains `hash`.
  public func occursOutside(_ hash: UInt64, group: Set<EpisodeKey>) -> Bool {
    for position in occurrences.run(of: hash)
    where !group.contains(occurrences.keys[occurrences.ordinal(at: position)]) {
      return true
    }
    return false
  }
}

/// The hit rule for one episode: a shingle hits when it occurs in another episode
/// group of the library, or in a learned creative not taught by this episode's group, and no
/// tombstone holds it.
public enum LibraryMatching {
  public struct Candidate: Sendable, Equatable {
    public let range: CandidateRange
    /// Learned creatives that supplied a hit inside this range. Non-empty means the range came
    /// (at least in part) from the store: Undo drops these, and only a kept range refreshes them.
    public let storeCreatives: Set<Int64>

    public init(range: CandidateRange, storeCreatives: Set<Int64>) {
      self.range = range
      self.storeCreatives = storeCreatives
    }
  }

  public struct Result: Sendable, Equatable {
    public let candidates: [Candidate]
    /// Tombstones that vetoed a shingle anywhere in the episode, for refreshing their last-seen
    /// date: an undo stays in force while the ad it undid keeps airing.
    public let matchedTombstones: Set<Int64>

    public init(candidates: [Candidate], matchedTombstones: Set<Int64>) {
      self.candidates = candidates
      self.matchedTombstones = matchedTombstones
    }
  }

  public static func candidates(
    for episode: EpisodeKey, transcript: PreparedTranscript, groups: EpisodeGroups,
    library: LibraryIndex, store: SignatureStore
  ) -> Result {
    let group = groups.members(of: episode)
    var tombstones: Set<Int64> = []
    var learnedByHash: [UInt64: [Int64]] = [:]
    let ranges = RepetitionStage.candidates(in: transcript) { hash in
      let vetoes = store.tombstones(holding: hash)
      if !vetoes.isEmpty {
        tombstones.formUnion(vetoes)
        return false
      }
      let learned = store.learnedMatches(hash, excludingGroup: group)
      if !learned.isEmpty { learnedByHash[hash] = learned }
      return library.occursOutside(hash, group: group) || !learned.isEmpty
    }
    // Every hit shingle of a range lies inside it: extension only widens the run it came from.
    let candidates = ranges.map { range in
      var creatives: Set<Int64> = []
      for shingle in transcript.shingles
      where shingle.start < range.end && shingle.end > range.start {
        if let learned = learnedByHash[shingle.hash] { creatives.formUnion(learned) }
      }
      return Candidate(range: range, storeCreatives: creatives)
    }
    return Result(candidates: candidates, matchedTombstones: tombstones)
  }
}
