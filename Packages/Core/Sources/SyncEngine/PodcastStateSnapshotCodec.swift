import CryptoKit
import Foundation
import Persistence

public enum PodcastStateSnapshotCodecError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case invalidFormat, tooLarge, tooManySubscriptions, tooManyEpisodes
  case oversizedString, invalidValue, duplicateIdentity, credentialedURL, digestMismatch
}

/// Portable backups never contain a SQLite store or transport state. The outer wrapper preserves
/// the exact payload bytes; its digest detects corruption, not authorship or authenticity.
public enum PodcastStateSnapshotCodec {
  public static let maxBytes = 32 * 1024 * 1024
  public static let maxSubscriptions = 2_000
  public static let maxEpisodes = 50_000
  public static let maxStringBytes = 8 * 1024

  private struct Envelope: Codable {
    let payload: String
    let sha256: String
  }

  public static func encode(_ snapshot: PodcastStateSnapshot) throws -> Data {
    try validate(snapshot)
    let identities = snapshot.episodeIdentities.map { identity in
      EpisodeIdentitySnapshot(
        subscriptionUUID: identity.subscriptionUUID, generationUUID: identity.generationUUID,
        digest: identity.digest, representativeDigest: identity.representativeDigest,
        aliases: identity.aliases.sorted(by: utf8Less), guid: identity.guid,
        enclosureURL: identity.enclosureURL)
    }.sorted {
      key($0.subscriptionUUID, $0.generationUUID, $0.digest) < key($1.subscriptionUUID, $1.generationUUID, $1.digest)
    }
    let ordered = PodcastStateSnapshot(
      version: snapshot.version, exportedAt: snapshot.exportedAt, appBuild: snapshot.appBuild,
      globalSettings: snapshot.globalSettings,
      subscriptions: snapshot.subscriptions.sorted { $0.subscriptionUUID.uuidString < $1.subscriptionUUID.uuidString },
      lastPlayed: snapshot.lastPlayed, episodeIdentities: identities,
      episodes: snapshot.episodes.sorted {
        key($0.subscriptionUUID, $0.generationUUID, $0.representativeDigest)
          < key($1.subscriptionUUID, $1.generationUUID, $1.representativeDigest)
      }, learnedAds: snapshot.learnedAds, smartLists: snapshot.smartLists)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(ordered)
    guard bytes.count <= maxBytes else { throw PodcastStateSnapshotCodecError.tooLarge }
    return bytes
  }

  public static func decode(_ data: Data) throws -> PodcastStateSnapshot {
    try validateDocument(data)
    let value: PodcastStateSnapshot
    do { value = try JSONDecoder().decode(PodcastStateSnapshot.self, from: data) } catch {
      throw PodcastStateSnapshotCodecError.invalidValue
    }
    try validate(value)
    return value
  }

  public static func encodeWrapped(_ snapshot: PodcastStateSnapshot) throws -> Data {
    let payload = try encode(snapshot)
    guard let text = String(data: payload, encoding: .utf8) else {
      throw PodcastStateSnapshotCodecError.invalidValue
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(Envelope(payload: text, sha256: digest(payload)))
    guard bytes.count <= maxBytes else { throw PodcastStateSnapshotCodecError.tooLarge }
    return bytes
  }

  public static func decodeWrapped(_ data: Data) throws -> PodcastStateSnapshot {
    try validateDocument(data)
    let envelope: Envelope
    do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch {
      throw PodcastStateSnapshotCodecError.invalidValue
    }
    let payload = Data(envelope.payload.utf8)
    guard envelope.sha256 == digest(payload) else { throw PodcastStateSnapshotCodecError.digestMismatch }
    return try decode(payload)
  }

  public static func validate(_ snapshot: PodcastStateSnapshot) throws {
    guard snapshot.format == PodcastStateSnapshot.format else { throw PodcastStateSnapshotCodecError.invalidFormat }
    guard snapshot.version == 1 else { throw PodcastStateSnapshotCodecError.unsupportedVersion(snapshot.version) }
    guard snapshot.subscriptions.count <= maxSubscriptions else {
      throw PodcastStateSnapshotCodecError.tooManySubscriptions
    }
    guard snapshot.episodes.count <= maxEpisodes,
      snapshot.episodeIdentities.count <= maxEpisodes - snapshot.episodes.count
    else { throw PodcastStateSnapshotCodecError.tooManyEpisodes }
    try date(snapshot.exportedAt)
    try date(snapshot.globalSettings.enabledAt)
    if let build = snapshot.appBuild { try string(build) }
    guard snapshot.globalSettings.keepLatestCount >= 0,
      NativePodcastShowSortMode(rawValue: snapshot.globalSettings.showOrderMode) != nil
    else { throw PodcastStateSnapshotCodecError.invalidValue }
    if let learnedAds = snapshot.learnedAds { try PodcastLearnedAdsSnapshotCodec.validate(learnedAds) }
    if let smartLists = snapshot.smartLists { try PodcastSmartListsSnapshotCodec.validate(smartLists) }

    var parents: [UUID: SubscriptionSnapshot] = [:]
    var urls: Set<String> = []
    for sub in snapshot.subscriptions {
      guard parents.updateValue(sub, forKey: sub.subscriptionUUID) == nil,
        urls.insert(sub.normalizedURL).inserted
      else { throw PodcastStateSnapshotCodecError.duplicateIdentity }
      try string(sub.normalizedURL, isURL: true)
      guard sub.canonicalizationVersion == 1,
        PodcastCloudIdentity.normalizedFeedURL(sub.normalizedURL) == sub.normalizedURL,
        PodcastCloudIdentity.subscriptionUUID(feedURL: sub.normalizedURL) == sub.subscriptionUUID,
        sub.lifecycle.subscriptionUUID == sub.subscriptionUUID
      else { throw PodcastStateSnapshotCodecError.invalidValue }
      try string(sub.title, maximum: 4096)
      if let author = sub.author { try string(author, maximum: 4096) }
      try date(sub.subscribedAt)
      if let order = sub.customOrder?.value, order < 0 { throw PodcastStateSnapshotCodecError.invalidValue }
      if let settings = sub.feedSettings {
        guard ["inherit", "enabled", "disabled"].contains(settings.autoDownload),
          ["inherit", "enabled", "disabled"].contains(settings.notificationOverride),
          (settings.keepLatest ?? 0) >= 0,
          settings.trimSilencesOverride.map({ TrimSilencesShowOverride(rawValue: $0) != nil }) ?? true,
          settings.voiceBoostOverride.map({ VoiceBoostShowOverride(rawValue: $0) != nil }) ?? true
        else { throw PodcastStateSnapshotCodecError.invalidValue }
        if let rate = settings.rateStep, !ItemPlaybackSettingsRateBounds.supportedSteps.contains(rate) {
          throw PodcastStateSnapshotCodecError.invalidValue
        }
      }
    }

    var identities: [String: EpisodeIdentitySnapshot] = [:]
    var aliasCount = 0
    for identity in snapshot.episodeIdentities {
      try parent(identity.subscriptionUUID, generation: identity.generationUUID, in: parents)
      try validDigest(identity.digest)
      try validDigest(identity.representativeDigest)
      guard identity.aliases.count <= maxEpisodes - aliasCount else {
        throw PodcastStateSnapshotCodecError.tooManyEpisodes
      }
      aliasCount += identity.aliases.count
      var aliases: Set<Data> = []
      for alias in identity.aliases {
        try string(alias)
        guard !alias.isEmpty, aliases.insert(Data(alias.utf8)).inserted else {
          throw PodcastStateSnapshotCodecError.duplicateIdentity
        }
      }
      if let guid = identity.guid { try string(guid) }
      if let url = identity.enclosureURL { try string(url, isURL: true) }
      let identityKey = key(identity.subscriptionUUID, identity.generationUUID, identity.digest)
      guard identities.updateValue(identity, forKey: identityKey) == nil else {
        throw PodcastStateSnapshotCodecError.duplicateIdentity
      }
    }
    for identity in snapshot.episodeIdentities {
      let representative = key(identity.subscriptionUUID, identity.generationUUID, identity.representativeDigest)
      guard let canonical = identities[representative], canonical.representativeDigest == canonical.digest,
        identity.representativeDigest <= identity.digest
      else { throw PodcastStateSnapshotCodecError.invalidValue }
    }

    var episodes: Set<String> = []
    for episode in snapshot.episodes {
      try parent(episode.subscriptionUUID, generation: episode.generationUUID, in: parents)
      try validDigest(episode.representativeDigest)
      let reference = key(episode.subscriptionUUID, episode.generationUUID, episode.representativeDigest)
      guard episodes.insert(reference).inserted else { throw PodcastStateSnapshotCodecError.duplicateIdentity }
      if episode.resolution == .resolved, identities[reference] == nil {
        throw PodcastStateSnapshotCodecError.invalidValue
      }
      try string(episode.identityKey)
      guard !episode.identityKey.isEmpty else { throw PodcastStateSnapshotCodecError.invalidValue }
      if let alias = episode.alternateIdentityKey {
        try string(alias)
        guard !alias.isEmpty else { throw PodcastStateSnapshotCodecError.invalidValue }
      }
      if episode.resolution == .resolved {
        let aliases = Set((identities[reference]?.aliases ?? []).map { Data($0.utf8) })
        guard aliases.contains(Data(episode.identityKey.utf8)) else {
          throw PodcastStateSnapshotCodecError.invalidValue
        }
        if let alternate = episode.alternateIdentityKey, !aliases.contains(Data(alternate.utf8)) {
          throw PodcastStateSnapshotCodecError.invalidValue
        }
      }
      if let guid = episode.guid { try string(guid) }
      if let url = episode.enclosureURL { try string(url, isURL: true) }
      try string(episode.title, maximum: 4096)
      try date(episode.publishedAt)
      try date(episode.state?.updatedAt)
      if let duration = episode.duration, !duration.isFinite || duration < 0 {
        throw PodcastStateSnapshotCodecError.invalidValue
      }
      // Whole state values validate finite nonnegative position and epoch ordering at decoding.
      // The restore writer applies its established duration tolerance when projecting playback.
    }
    if let reference = snapshot.lastPlayed?.reference {
      try parent(reference.subscriptionUUID, generation: reference.generationUUID, in: parents)
      guard episodes.contains(key(reference.subscriptionUUID, reference.generationUUID, reference.representativeDigest))
      else {
        throw PodcastStateSnapshotCodecError.invalidValue
      }
    }
  }

  private static func parent(_ subscription: UUID, generation: UUID, in parents: [UUID: SubscriptionSnapshot]) throws {
    guard parents[subscription]?.lifecycle.generationUUID == generation else {
      throw PodcastStateSnapshotCodecError.invalidValue
    }
  }

  private static func validDigest(_ value: String) throws {
    guard value.utf8.count == 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw PodcastStateSnapshotCodecError.invalidValue }
  }

  private static func date(_ value: Date?) throws {
    if let value, !value.timeIntervalSince1970.isFinite { throw PodcastStateSnapshotCodecError.invalidValue }
  }

  private static func string(_ value: String, maximum: Int = maxStringBytes, isURL: Bool = false) throws {
    guard value.utf8.count <= maximum else { throw PodcastStateSnapshotCodecError.oversizedString }
    if isURL {
      guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
        ["https", "http"].contains(scheme), !(url.host ?? "").isEmpty
      else { throw PodcastStateSnapshotCodecError.invalidValue }
      guard url.user == nil, url.password == nil else { throw PodcastStateSnapshotCodecError.credentialedURL }
    }
  }

  private static func key(_ subscription: UUID, _ generation: UUID, _ digest: String) -> String {
    "\(subscription.uuidString)|\(generation.uuidString)|\(digest)"
  }

  private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  /// Check nesting before JSONDecoder allocates the object graph; quoted braces and escaped
  /// quotes do not alter depth. The decoder subsequently rejects malformed JSON syntax.
  private static func validateDocument(_ data: Data) throws {
    guard data.count <= maxBytes else { throw PodcastStateSnapshotCodecError.tooLarge }
    var depth = 0
    var quoted = false
    var escaped = false
    for byte in data {
      if quoted {
        if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
      } else if byte == 34 {
        quoted = true
      } else if byte == 123 || byte == 91 {
        depth += 1
        guard depth <= 16 else { throw PodcastStateSnapshotCodecError.invalidValue }
      } else if byte == 125 || byte == 93 {
        depth -= 1
        guard depth >= 0 else { throw PodcastStateSnapshotCodecError.invalidValue }
      }
    }
    guard depth == 0, !quoted else { throw PodcastStateSnapshotCodecError.invalidValue }
  }
}
