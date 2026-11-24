import Foundation
import GRDB
import Persistence

/// After a feed refresh, match held remote episode state to the feed's local episodes, and
/// keep what does not match within a bound.
///
/// A new device learns episode identities from the publisher, not CloudKit, so a remote state
/// often arrives before its episode exists locally. `PodcastCloudHoldingApplier` holds it under
/// its keyed record-name components; each feed refresh may bring new identities, so it retries.
///
/// Matching, in order, stopping at the first rule with exactly one candidate:
///
/// 1. the keyed digest of a local episode's identity key or alternate identity key equals the
///    record name's digest component (the representative case);
/// 2. the record's non-empty GUID equals exactly one local episode's GUID;
/// 3. the record's credential-free enclosure URL equals exactly one local episode's.
///
/// Anything ambiguous stays held; nothing is matched by title. A match goes to the applier, and
/// only a state it actually projected is released, since releasing an unprojected one would lose
/// remote history.
public enum PodcastCloudEpisodeStateResolution {
  /// The retention bound on held remote states across all feeds. Oldest first, because a state
  /// whose episode has not appeared in that long is the least likely ever to resolve. Held states
  /// count against the plan's 50,000-reference budget alongside identity records.
  public static let retentionLimit = 5_000

  public struct Outcome: Sendable, Equatable {
    /// Matched and projected; the held copy is released.
    public var applied = 0
    /// Matched, but the applier does not project episode state yet; kept.
    public var matchedButRetained = 0
    /// More than one local candidate under the first rule that found any; kept.
    public var ambiguous = 0
    /// No local candidate yet; kept.
    public var unmatched = 0
    /// Removed by the retention bound.
    public var pruned = 0

    public init() {}
  }

  public static func resolve(
    afterRefreshOf feedId: Int64, database: AppDatabase, recordNameKey: PodcastCloudRecordNameKey,
    applier: any PodcastCloudRemoteApplying, retentionLimit: Int = retentionLimit
  ) async throws -> Outcome {
    try await database.writeAsync { db in
      try resolve(
        in: db, feedId: feedId, recordNameKey: recordNameKey, applier: applier,
        retentionLimit: retentionLimit)
    }
  }

  /// The same resolution inside the caller's transaction. The projecting applier runs it as a
  /// record is admitted, so a state whose episode already exists lands without waiting for a
  /// refresh.
  public static func resolve(
    in db: Database, feedId: Int64, recordNameKey: PodcastCloudRecordNameKey,
    applier: any PodcastCloudRemoteApplying, retentionLimit: Int = retentionLimit
  ) throws -> Outcome {
    var outcome = Outcome()
    guard
      let feedURL = try String.fetchOne(
        db, sql: "SELECT feedURL FROM rssFeed WHERE id = ?", arguments: [feedId]),
      let subscriptionUUID = PodcastCloudIdentity.subscriptionUUID(feedURL: feedURL)?
        .uuidString.lowercased(),
      let entry = try PodcastCloudRegistryStore.entry(in: db, subscriptionUUID: subscriptionUUID),
      let keyed = try keyedParent(
        subscriptionUUID: entry.subscriptionUUID, generationUUID: entry.generationUUID,
        key: recordNameKey)
    else { return outcome }

    let held = try PodcastCloudRegistryStore.unresolved(
      in: db, subscriptionUUID: keyed.subscription, generationUUID: keyed.generation)
    if held.isEmpty == false {
      let episodes = try localEpisodes(
        in: db,
        feedIDs: try PodcastCloudLocalCatalogue.feedIDs(in: db, subscriptionUUID: subscriptionUUID))
      var byDigest: [String: Set<Int64>] = [:]
      for episode in episodes {
        for identityKey in [episode.identityKey, episode.alternateIdentityKey].compactMap({ $0 }) {
          let digest = try keyedDigest(
            subscriptionUUID: entry.subscriptionUUID, generationUUID: entry.generationUUID,
            identityKey: identityKey, key: recordNameKey)
          byDigest[digest, default: []].insert(episode.id)
        }
      }

      for state in held {
        guard let decoded = decode(state.payload) else {
          outcome.unmatched += 1
          continue
        }
        switch match(
          digest: state.episodeDigest, identity: decoded.identity, byDigest: byDigest,
          episodes: episodes)
        {
        case .noCandidate:
          outcome.unmatched += 1
        case .ambiguous:
          outcome.ambiguous += 1
        case .one(let episodeId):
          let projected: Bool
          switch decoded.value {
          case .state(let value):
            projected = try applier.applyResolvedEpisodeState(
              PodcastCloudResolvedEpisodeState(
                recordName: state.recordName, episodeId: episodeId, state: value,
                identity: decoded.identity),
              in: db)
          case .saved(let register):
            projected = try applier.applyResolvedSaved(
              PodcastCloudResolvedSaved(recordName: state.recordName, episodeId: episodeId, register: register),
              in: db)
          }
          if projected {
            try PodcastCloudRegistryStore.resolveUnresolved(in: db, recordName: state.recordName)
            outcome.applied += 1
          } else {
            outcome.matchedButRetained += 1
          }
        }
      }
    }
    outcome.pruned = try PodcastCloudRegistryStore.pruneUnresolved(in: db, keeping: retentionLimit)
    return outcome
  }

  enum HeldValue {
    case state(PodcastCloudEpisodeState)
    case saved(PodcastCloudSavedRegister)
  }

  static func decode(_ payload: Data) -> (value: HeldValue, identity: PodcastCloudEpisodeIdentityFields)? {
    guard let fields = try? PodcastCloudRecordPayload.decode(payload) else { return nil }
    switch fields.recordType {
    case PodcastCloudRecordLayout.episodeState.name:
      guard let decoded = try? PodcastCloudRecordCodec.decodeEpisodeState(fields) else { return nil }
      return (.state(decoded.state), decoded.identity)
    case PodcastCloudRecordLayout.savedEpisode.name:
      guard let decoded = try? PodcastCloudRecordCodec.decodeSavedEpisode(fields) else { return nil }
      return (.saved(decoded.register), decoded.identity)
    default:
      return nil
    }
  }

  // MARK: - Matching

  struct LocalEpisode: Sendable, Equatable {
    let id: Int64
    let identityKey: String
    let alternateIdentityKey: String?
    let guid: String?
    let enclosureURL: String?
  }

  enum Match: Equatable {
    case noCandidate
    case ambiguous
    case one(Int64)
  }

  static func match(
    digest: String, identity: PodcastCloudEpisodeIdentityFields, byDigest: [String: Set<Int64>],
    episodes: [LocalEpisode]
  ) -> Match {
    if let candidates = byDigest[digest], candidates.isEmpty == false {
      return candidates.count == 1 ? .one(candidates.first!) : .ambiguous
    }
    if let guid = identity.guid, guid.isEmpty == false {
      let candidates = episodes.filter { $0.guid == guid }
      if candidates.count == 1 { return .one(candidates[0].id) }
      if candidates.count > 1 { return .ambiguous }
    }
    if let enclosure = identity.enclosureURL.flatMap(credentialFree) {
      let candidates = episodes.filter { $0.enclosureURL.flatMap(credentialFree) == enclosure }
      if candidates.count == 1 { return .one(candidates[0].id) }
      if candidates.count > 1 { return .ambiguous }
    }
    return .noCandidate
  }

  /// An enclosure URL with any user-info removed, or `nil` when it does not parse. A URL that
  /// carried credentials is still matched on its credential-free form; the credentials never take
  /// part in identity.
  static func credentialFree(_ raw: String) -> String? {
    guard var components = URLComponents(string: raw), components.host != nil else { return nil }
    components.user = nil
    components.password = nil
    return components.string
  }

  // MARK: - Keyed names

  /// The keyed forms of a subscription and generation, taken from a record name the identity
  /// module mints, so there is exactly one implementation of the keying.
  static func keyedParent(
    subscriptionUUID: String, generationUUID: String, key: PodcastCloudRecordNameKey
  ) throws -> (subscription: String, generation: String)? {
    let name = try PodcastCloudIdentity.recordName(
      kind: "settings", components: [subscriptionUUID, generationUUID], key: key)
    let parts = name.split(separator: ".").map(String.init)
    guard parts.count == 4 else { return nil }
    return (parts[2], parts[3])
  }

  static func keyedDigest(
    subscriptionUUID: String, generationUUID: String, identityKey: String,
    key: PodcastCloudRecordNameKey
  ) throws -> String {
    let name = try PodcastCloudIdentity.recordName(
      kind: "state",
      components: [
        subscriptionUUID, generationUUID, PodcastCloudIdentity.episodeDigest(identityKey: identityKey),
      ],
      key: key)
    return PodcastCloudKeyedRecordName(name)?.digest ?? ""
  }

  static func localEpisodes(in db: Database, feedIDs: [Int64]) throws -> [LocalEpisode] {
    guard feedIDs.isEmpty == false else { return [] }
    let placeholders = Array(repeating: "?", count: feedIDs.count).joined(separator: ", ")
    return try Row.fetchAll(
      db,
      sql: """
        SELECT id, identityKey, alternateIdentityKey, guid, enclosureURL FROM rssEpisode
        WHERE feedId IN (\(placeholders)) ORDER BY id
        """, arguments: StatementArguments(feedIDs)
    ).map {
      LocalEpisode(
        id: $0["id"], identityKey: $0["identityKey"],
        alternateIdentityKey: $0["alternateIdentityKey"], guid: $0["guid"],
        enclosureURL: $0["enclosureURL"])
    }
  }
}

extension PodcastCloudSyncCoordinator {
  /// Entry point for the refresh path: call after a feed refresh commits. A no-op while
  /// the account's record-name key is unknown, because nothing can be matched without it.
  @discardableResult
  public func resolveEpisodeStates(afterRefreshOf feedId: Int64) async throws
    -> PodcastCloudEpisodeStateResolution.Outcome
  {
    guard let key = recordNameKeys.current else { return PodcastCloudEpisodeStateResolution.Outcome() }
    return try await PodcastCloudEpisodeStateResolution.resolve(
      afterRefreshOf: feedId, database: database, recordNameKey: key, applier: applier)
  }
}
