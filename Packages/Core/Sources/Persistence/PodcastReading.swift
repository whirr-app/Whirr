import Foundation

/// The leading rows of a show's episode list, in `PodcastReading.observeEpisodes` order.
public struct PodcastEpisodePrefix: Sendable, Equatable {
  public let episodes: [PodcastEpisodeSummary]
  /// `episodes` is the show's whole list, not only its first rows. A complete prefix may be empty.
  public let isComplete: Bool

  public init(episodes: [PodcastEpisodeSummary], isComplete: Bool) {
    self.episodes = episodes
    self.isComplete = isComplete
  }
}

/// Read side of one podcast show. Both observations resolve the server item id inside their
/// tracked fetch, so a stream started before the show is cached begins emitting when it appears.
public protocol PodcastReading: Sendable {
  /// Active episodes ordered by publication date descending, then stable episode id ascending.
  /// Episodes without a publication date sort last.
  func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]>

  /// The first `limit` episodes `observeEpisodes` would start with, read synchronously on the
  /// caller's thread. `nil` means the reader has no synchronous baseline, not that the show has no
  /// episodes.
  ///
  /// The one podcast read allowed on the main thread, for the show screen's first frame: the
  /// observation's first value lands after the navigation push, so the page slid in without
  /// episodes. The limit keeps it cheap; a long show's whole list delayed the push visibly.
  func episodePrefix(itemId: String, limit: Int) -> PodcastEpisodePrefix?

  /// The two read-only server diagnostics used to explain a stale show. Returns nil while the
  /// show itself is absent; individual fields remain nil when the expanded response omitted them.
  func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?>

  /// One episode's full projection (same shape as `observeEpisodes`, `episodeDescription`
  /// included) plus its show's title/author for the episode card header. One-shot; refreshes
  /// piggyback on `observeEpisodes`'s signal. `itemID` and `episodeID` are both part of the key,
  /// as `observeEpisodes` scopes episodes to their show. Returns nil when the episode does not
  /// exist, is soft-deleted, or belongs to a different item.
  func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext?

  /// Byte progress for this show's transfers, keyed by episode id, as a floored 2% fraction
  /// (`EpisodeDownloadProgressProjection.quantum`). Only `downloading` rows with a known total
  /// appear. Separate because `observeEpisodes` selects no byte column, so a progress write never
  /// invalidates the list and only rows drawing a ring subscribe.
  func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]>

  /// The stored full description of the show's newest `limit` episodes, in `observeEpisodes`
  /// order, skipping episodes with none. Raw feed text or HTML, compared by the episode card to
  /// find repeated paragraphs (`ShowNotesBoilerplate`). One-shot and scoped like `episode`, with
  /// no library-inclusion predicate. Empty for an unknown show.
  func recentEpisodeDescriptions(itemId: String, limit: Int) async throws -> [String]

  /// The ids of this account's visible server shows whose feed fingerprint equals the given one,
  /// ordered by id and re-emitted when a library sync adds, removes or hides one. Only a server
  /// (`DefaultPodcastReading`) reader answers; the default observes nothing, and
  /// `RoutingPodcastReading` forwards to its server reader.
  func observeServerCopyItemIDs(podcastFeedFingerprint: String) -> AsyncStream<[String]>
}

/// Lightweight readers observe no progress by default. Production readers override this.
extension PodcastReading {
  /// Fakes and lightweight readers keep the asynchronous path alone.
  public func episodePrefix(itemId: String, limit: Int) -> PodcastEpisodePrefix? {
    nil
  }

  public func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]> {
    AsyncStream { $0.finish() }
  }

  /// Readers without descriptions to compare leave the card on its single-episode fold.
  public func recentEpisodeDescriptions(itemId: String, limit: Int) async throws -> [String] {
    []
  }

  /// A reader that cannot see server items finds no server copy of any feed.
  public func observeServerCopyItemIDs(podcastFeedFingerprint: String) -> AsyncStream<[String]> {
    AsyncStream { $0.finish() }
  }
}

/// Incremental-composition default: no database and no fabricated podcast state.
public struct NoOpPodcastReading: PodcastReading, Sendable {
  public init() {}

  public func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]> {
    AsyncStream { $0.finish() }
  }

  public func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]> {
    AsyncStream { $0.finish() }
  }

  public func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?> {
    AsyncStream { $0.finish() }
  }

  public func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext? {
    nil
  }
}
