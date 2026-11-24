import Foundation

/// The SQL for the download and playback narrowings, shared by Library, Search and Home alongside
/// `ItemCategoryPredicate`'s media-category SQL.
///
/// Every function returns the literal `"1"` when inactive (not an always-true `EXISTS`), so an
/// unfiltered query is byte-identical to one built without these predicates. Composed from fixed
/// case values, never caller input, so no argument binding is needed, and `ValueObservation` can
/// infer `download`/`mediaProgress` into the tracked region from the SQL.
///
/// Three download scopes, not interchangeable:
/// - `itemDownloadedOnly`: item-level rows only (`podcastEpisodeId IS NULL`), as Search result
///   rows and item download badges mean (mirrors `DownloadStore.itemPresence`); every requested
///   medium must be complete.
/// - `episodeDownloadedOnly`: one episode's own rows. Search's episode results.
/// - `libraryEntryDownloadedOnly`: every row under the library entry, item- and episode-level.
///   The Library's Downloaded dimension, so a podcast show appears as the way into its completed
///   episodes; podcast downloads are episode-keyed, so the item-only scope would return no shows.
///
/// The item scopes count item media only (`DownloadMediaKind.itemMediaSQL`): a supplement PDF
/// never makes a book "downloaded". Episode rows are always audio.
///
/// "Complete" (identical in all three) is the SQL form of `DownloadStore.status(rows:)`/
/// `ItemDownloadPresence.completed`: at least one live (non-`deleting`) row, none not `completed`.
enum ItemFilterPredicate {

  static func itemDownloadedOnly(_ active: Bool) -> String {
    guard active else { return "1" }
    return """
      EXISTS (
        SELECT 1 FROM download
        WHERE download.itemId = item.id AND download.podcastEpisodeId IS NULL
          AND \(DownloadMediaKind.itemMediaSQL())
          AND download.state != 'deleting'
      )
      AND NOT EXISTS (
        SELECT 1 FROM download
        WHERE download.itemId = item.id AND download.podcastEpisodeId IS NULL
          AND \(DownloadMediaKind.itemMediaSQL())
          AND download.state NOT IN ('completed', 'deleting')
      )
      """
  }

  /// Keyed by the episode's own row id rather than the item-level `podcastEpisodeId IS NULL` scope,
  /// so an item-level download never makes its episodes count as downloaded, nor the reverse.
  static func episodeDownloadedOnly(_ active: Bool) -> String {
    guard active else { return "1" }
    return """
      EXISTS (
        SELECT 1 FROM download
        WHERE download.podcastEpisodeId = episode.id
          AND download.mediaKind = 'audio'
          AND download.state != 'deleting'
      )
      AND NOT EXISTS (
        SELECT 1 FROM download
        WHERE download.podcastEpisodeId = episode.id
          AND download.mediaKind = 'audio'
          AND download.state NOT IN ('completed', 'deleting')
      )
      """
  }

  /// Home's scope. No `download.accountId` clause: `download.itemId` already resolves to one
  /// global `item` row id, and omitting it keeps this predicate free of bind arguments.
  static func libraryEntryDownloadedOnly(_ active: Bool) -> String {
    guard active else { return "1" }
    return """
      EXISTS (
        SELECT 1 FROM download
        WHERE download.itemId = item.id
          AND \(DownloadMediaKind.itemMediaSQL())
          AND download.state != 'deleting'
      )
      AND NOT EXISTS (
        SELECT 1 FROM download
        WHERE download.itemId = item.id
          AND \(DownloadMediaKind.itemMediaSQL())
          AND download.state NOT IN ('completed', 'deleting')
      )
      """
  }

  /// The three engaged cases partition an item's playback state (`PlaybackFilter`), and a podcast
  /// show is excluded from all of them.
  ///
  /// Podcast progress is written per episode, so at this item scope a show carries no progress row
  /// and would pass `unfinished` however much was heard. (The schema permits an item-level row on
  /// a show since `podcastEpisodeId` is nullable, but progress is not written that way.) Library
  /// and Search both call this, so the two surfaces mean the same thing by the same funnel row.
  static func itemPlayback(_ playback: PlaybackFilter) -> String {
    guard playback != .any else { return "1" }
    return "item.mediaKind != 'podcast' AND (\(itemPlaybackStateSQL(playback)))"
  }

  private static func itemPlaybackStateSQL(_ playback: PlaybackFilter) -> String {
    switch playback {
    case .any:
      return "1"
    case .unfinished:
      return "NOT EXISTS (\(itemProgressSelectSQL))"
    case .inProgress:
      return "EXISTS (\(itemProgressSelectSQL) AND mediaProgress.isFinished = 0)"
    case .finished:
      return "EXISTS (\(itemFinishedSelectSQL))"
    }
  }

  /// Episode progress is keyed by `podcastEpisodeId` and is independent of the parent item's:
  /// a finished item does not finish its episodes (`PersistenceBoundaries.swift`), nor the reverse.
  /// This scope can answer a podcast playback question, so it has no media-kind exclusion.
  static func episodePlayback(_ playback: PlaybackFilter) -> String {
    switch playback {
    case .any:
      return "1"
    case .unfinished:
      return "NOT EXISTS (\(episodeProgressSelectSQL))"
    case .inProgress:
      return "EXISTS (\(episodeProgressSelectSQL) AND mediaProgress.isFinished = 0)"
    case .finished:
      return "EXISTS (\(episodeFinishedSelectSQL))"
    }
  }

  /// "This item has been started at all": the one subquery `unfinished` and `inProgress` share so
  /// they cannot overlap. `unfinished` is its absence, `inProgress` its presence with the row
  /// unfinished; with `finished` they cover every item exactly once.
  ///
  /// The rule (finished, or an audio position, or an ebook position) is the SQL twin of
  /// `MediaProgressActionPolicy.playbackStatus` and the badge projection in
  /// `DefaultLibraryReading.observeItemPlaybackStatuses`, so a filter and a badge saying "in
  /// progress" select the same rows. Account and soft-delete scoping come from the enclosing query.
  ///
  /// `COALESCE` is for readability: `currentTime` and `isFinished` are `NOT NULL`, only
  /// `ebookProgress` is nullable, and `WHERE` already rejects `0 OR 0 OR NULL`, the "never started"
  /// classification wanted.
  private static let itemProgressSelectSQL = """

      SELECT 1 FROM mediaProgress
      WHERE mediaProgress.itemId = item.id AND mediaProgress.podcastEpisodeId IS NULL
        AND (
          mediaProgress.isFinished = 1
          OR mediaProgress.currentTime > 0
          OR COALESCE(mediaProgress.ebookProgress, 0) > 0
        )
    """

  /// The episode counterpart, without the ebook term: `ebookProgress` exists on every
  /// `mediaProgress` row including episode-keyed ones, but a podcast episode has no ebook edition
  /// to be part-way through. Do not add the term.
  private static let episodeProgressSelectSQL = """

      SELECT 1 FROM mediaProgress
      WHERE mediaProgress.podcastEpisodeId = episode.id
        AND (mediaProgress.isFinished = 1 OR mediaProgress.currentTime > 0)
    """

  private static let itemFinishedSelectSQL = """

      SELECT 1 FROM mediaProgress
      WHERE mediaProgress.itemId = item.id AND mediaProgress.podcastEpisodeId IS NULL
        AND mediaProgress.isFinished = 1
    """

  private static let episodeFinishedSelectSQL = """

      SELECT 1 FROM mediaProgress
      WHERE mediaProgress.podcastEpisodeId = episode.id AND mediaProgress.isFinished = 1
    """
}
