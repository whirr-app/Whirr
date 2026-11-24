import ABSApi
import Foundation
import Persistence

/// Pure coordinator helpers live outside the actor so the actor file remains a readable flight
/// sequence. All helpers use the existing normalized feed-URL identity policy.
enum NativeEpisodeServerSaveSupport {
  /// Reconciliation and removal can outlive the native RSS row. Their flights still use the
  /// shared account-fence container, so provide a source-free command placeholder that those paths
  /// never send or use for matching.
  static func commandForDurableIdentity(
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String
  ) -> NativeEpisodeServerSaveCommand {
    NativeEpisodeServerSaveCommand(
      feedId: feedId,
      episodeId: episodeId,
      episodeIdentityKey: episodeIdentityKey,
      feedTitle: "",
      feedAuthor: nil,
      feedSynopsis: nil,
      episodeGUID: nil,
      episodeTitle: nil,
      episodeSynopsis: nil,
      enclosureType: nil,
      declaredBytes: nil,
      durationSeconds: nil,
      seasonNumber: nil,
      episodeNumber: nil,
      publishedAt: nil,
      feedURL: URL(string: "https://identity.invalid/")!,
      enclosureURL: URL(string: "https://identity.invalid/")!)
  }

  static func usableServerIdentity(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty == false
      && value.utf8.count <= 512
      && value.utf8.allSatisfy { $0 != 0 }
  }

  static func normalizedGUID(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func normalizedURL(_ value: String) -> String? {
    PodcastFeedIdentity.normalized(value)
  }

  static func preflightPresence(
    command: NativeEpisodeServerSaveCommand,
    media: PodcastMedia
  ) -> NativeEpisodeServerSavePreflightPresence {
    matchingEpisodeID(command: command, media: media) != nil
      ? .preExisting : .absentBeforeRequest
  }

  /// More than one server row carrying the source GUID proves the episode is already on the
  /// server without saying which row is this one: it is neither presence (no single row to
  /// confirm) nor absence (a download request would add another copy).
  static func hasDuplicateGUIDMatches(
    command: NativeEpisodeServerSaveCommand,
    media: PodcastMedia
  ) -> Bool {
    guard let sourceGUID = normalizedGUID(command.episodeGUID) else { return false }
    let matches = media.episodes.filter { episode in
      normalizedGUID(episode.guid) == sourceGUID && usableServerIdentity(episode.id)
    }
    return matches.count > 1
  }

  /// Returns the opaque Audiobookshelf episode id for the source episode. A non-empty source GUID
  /// matches only an equal, unique, non-empty server GUID, never falling back to URL matching (a
  /// conflicting GUID on the same enclosure URL is no match). URL equality applies only when the
  /// source GUID is absent, needs a non-empty server GUID, and never consults `contentUrl` (a
  /// server-local playback path). Either path returns no match if several episodes qualify.
  static func matchingEpisodeID(
    command: NativeEpisodeServerSaveCommand,
    media: PodcastMedia,
    allowNullServerGUIDForURLFallback: Bool = false
  ) -> String? {
    if let sourceGUID = normalizedGUID(command.episodeGUID) {
      let matches = media.episodes.filter { episode in
        normalizedGUID(episode.guid) == sourceGUID && usableServerIdentity(episode.id)
      }
      return matches.count == 1 ? matches[0].id : nil
    }
    return matchingEpisodeID(
      enclosureURL: command.enclosureURL, media: media,
      allowNullServerGUID: allowNullServerGUIDForURLFallback)
  }

  /// A persisted identity key is either `guid:<value>` or a hashed enclosure identity. Only the
  /// GUID form can be matched against the server list on its own; the hash cannot be expanded
  /// without the RSS row's enclosure URL.
  static func isGUIDIdentityKey(_ episodeIdentityKey: String) -> Bool {
    episodeIdentityKey.hasPrefix("guid:")
  }

  static func matchingEpisodeID(
    guidIdentityKey: String,
    media: PodcastMedia
  ) -> String? {
    guard isGUIDIdentityKey(guidIdentityKey),
      let identity = normalizedGUID(String(guidIdentityKey.dropFirst("guid:".count)))
    else { return nil }
    let matches = media.episodes.filter {
      normalizedGUID($0.guid) == identity && usableServerIdentity($0.id)
    }
    return matches.count == 1 ? matches[0].id : nil
  }

  /// Enclosure-URL matching. A server row without a GUID is a partial re-import the folder
  /// watcher can create after a restart, so the strict form never matches one. Returns no match
  /// when more than one server episode shares the enclosure URL.
  static func matchingEpisodeID(
    enclosureURL: URL,
    media: PodcastMedia,
    allowNullServerGUID: Bool = false
  ) -> String? {
    guard let sourceURL = normalizedURL(enclosureURL.absoluteString) else { return nil }
    let matches = media.episodes.filter { episode in
      guard let candidate = episode.enclosureURL else { return false }
      return (allowNullServerGUID || normalizedGUID(episode.guid) != nil)
        && usableServerIdentity(episode.id)
        && normalizedURL(candidate) == sourceURL
    }
    return matches.count == 1 ? matches[0].id : nil
  }

}
