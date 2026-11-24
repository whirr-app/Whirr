import Foundation

/// The learned-ad store as values. Persistence holds the rows; this type holds the rules.
public struct SignatureCreative: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    /// Shingles of a kept range: they hit for any episode outside the teaching group.
    case learned
    /// Shingles of a range the listener undid: they never hit, from the library or the store.
    case tombstone
  }

  public let id: Int64
  public let kind: Kind
  /// Refreshed whenever the creative matches; tombstones are refreshed when they veto a hit.
  public let lastSeen: Date
  /// The range in the teaching episode it was learned from or undone in, so a later analysis of
  /// that episode can replace the creative for an overlapping range. For an ad merged from several
  /// groups' copies it is the range of the copy whose print was kept, and replaces nothing.
  public let start: Double
  public let end: Double
  /// The episodes that taught it: one group's, or several groups' once copies are merged. No
  /// episode whose group holds all of them matches it. `replay.py`'s `Lookup` excluded only the
  /// teaching episode itself. The two agree while an ad has one teaching group and groups are
  /// stable. When a later link joins groups this is the stricter reading, since the newly joined
  /// episode is a copy of the teacher.
  public let teachers: Set<EpisodeKey>
  public let hashes: Set<UInt64>
  /// A listener's mark taught it. It never expires, is evicted last, and is never merged with,
  /// replaced by or absorbed into another creative.
  public let confirmed: Bool

  public init(
    id: Int64, kind: Kind, lastSeen: Date, start: Double, end: Double, teachers: Set<EpisodeKey>,
    hashes: Set<UInt64>, confirmed: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.lastSeen = lastSeen
    self.start = start
    self.end = end
    self.teachers = teachers
    self.hashes = hashes
    self.confirmed = confirmed
  }
}

/// A creative to insert, before Persistence assigns its id.
public struct NewSignatureCreative: Sendable, Equatable {
  public let kind: SignatureCreative.Kind
  public let start: Double
  public let end: Double
  public let teachers: Set<EpisodeKey>
  public let hashes: Set<UInt64>
  public let confirmed: Bool

  public init(
    kind: SignatureCreative.Kind, start: Double, end: Double, teachers: Set<EpisodeKey>,
    hashes: Set<UInt64>, confirmed: Bool = false
  ) {
    self.kind = kind
    self.start = start
    self.end = end
    self.teachers = teachers
    self.hashes = hashes
    self.confirmed = confirmed
  }
}

public struct SignatureStore: Sendable {
  public static let hashCap = 200_000
  public static let expiry: TimeInterval = 90 * 24 * 60 * 60

  public let creatives: [SignatureCreative]

  private let learnedByHash: [UInt64: [Int]]
  private let tombstonedByHash: [UInt64: [Int64]]

  public init(creatives: [SignatureCreative]) {
    self.creatives = creatives
    var learned: [UInt64: [Int]] = [:]
    var tombstoned: [UInt64: [Int64]] = [:]
    for (position, creative) in creatives.enumerated() {
      switch creative.kind {
      case .learned:
        for hash in creative.hashes { learned[hash, default: []].append(position) }
      case .tombstone:
        for hash in creative.hashes { tombstoned[hash, default: []].append(creative.id) }
      }
    }
    self.learnedByHash = learned
    self.tombstonedByHash = tombstoned
  }

  /// Ids of learned creatives holding `hash`, except those every one of whose teachers is in
  /// `group`. An ad taught by one group never matches that group. An ad merged from several
  /// groups' copies (`LearnedAdMerging`) matches each of them, as the copy another group taught
  /// would: with `isDisjoint` it would match none of the episodes that carry it.
  public func learnedMatches(_ hash: UInt64, excludingGroup group: Set<EpisodeKey>) -> [Int64] {
    (learnedByHash[hash] ?? []).compactMap { position in
      let creative = creatives[position]
      return creative.teachers.isEmpty || !creative.teachers.isSubset(of: group) ? creative.id : nil
    }
  }

  public func isTombstoned(_ hash: UInt64) -> Bool {
    tombstonedByHash[hash] != nil
  }

  /// Ids of tombstones holding `hash`.
  public func tombstones(holding hash: UInt64) -> [Int64] {
    tombstonedByHash[hash] ?? []
  }

  /// One learned creative per kept range: the shingles lying wholly inside it
  /// (`start <= shingle.start && shingle.end <= end`, `replay.py` `learn`). A range holding no
  /// shingle yields nothing.
  public static func learning(
    from transcript: PreparedTranscript, kept: [KeptRange], teachers: Set<EpisodeKey>
  ) -> [NewSignatureCreative] {
    kept.compactMap { range in
      let hashes = Set(
        transcript.shingles.lazy.filter { range.start <= $0.start && $0.end <= range.end }.map(\.hash))
      return hashes.isEmpty
        ? nil
        : NewSignatureCreative(
          kind: .learned, start: range.start, end: range.end, teachers: teachers, hashes: hashes)
    }
  }

  /// A tombstone for an undone range: every shingle overlapping it at all, so no part of it can
  /// recur as a hit.
  public static func tombstone(
    from transcript: PreparedTranscript, start: Double, end: Double, teachers: Set<EpisodeKey>
  ) -> NewSignatureCreative? {
    let hashes = Set(
      transcript.shingles.lazy.filter { $0.start < end && $0.end > start }.map(\.hash))
    return hashes.isEmpty
      ? nil
      : NewSignatureCreative(
        kind: .tombstone, start: start, end: end, teachers: teachers, hashes: hashes)
  }

  /// Creatives unseen for longer than `expiry` as of `now`. A confirmed creative never expires.
  public func expired(asOf now: Date) -> [Int64] {
    creatives.filter { Self.isExpired(confirmed: $0.confirmed, lastSeen: $0.lastSeen, asOf: now) }
      .map(\.id)
  }

  /// The one expiry rule: a creative unseen for longer than `expiry` is due for removal, and a
  /// confirmed creative never is. The backup filters its learned ads with this same predicate, so
  /// it neither carries an ad the next pass would delete nor omits one the store keeps.
  public static func isExpired(confirmed: Bool, lastSeen: Date, asOf now: Date) -> Bool {
    confirmed == false && now.timeIntervalSince(lastSeen) > expiry
  }

  /// Creatives to evict, least recently seen first (ties by ascending id), until the total hash
  /// count of the rest is at most `cap`; the confirmed ones come after every other. Run after
  /// `expired(asOf:)` is applied.
  public func evictions(cap: Int = SignatureStore.hashCap) -> [Int64] {
    var remaining = creatives.reduce(0) { $0 + $1.hashes.count }
    var evicted: [Int64] = []
    let ordered = creatives.sorted {
      ($0.confirmed ? 1 : 0, $0.lastSeen, $0.id) < ($1.confirmed ? 1 : 0, $1.lastSeen, $1.id)
    }
    for creative in ordered {
      if remaining <= cap { break }
      evicted.append(creative.id)
      remaining -= creative.hashes.count
    }
    return evicted
  }
}
