import Foundation

/// A read-only, UI-facing projection of the account's playback bookmark: what was last played.
/// Like `HomeItem`/`ItemSummary`, screens observe it rather than raw GRDB records
/// (ARCHITECTURE.md §2).
///
/// Not derived from `mediaProgress`: server pulls write that as much as playback does and
/// `localSequence` advances on any progress write, so it cannot say which item this device last
/// loaded. The bookmark is stored once per account, with position and finished flag joined from
/// `mediaProgress` so the row is not rewritten as playback advances.
public struct PlaybackBookmark: Sendable, Equatable {
  public let serverItemId: String
  /// The server episode id for a podcast bookmark, or `nil` for an item-level audiobook bookmark.
  public let episodeID: String?
  /// The episode's display title for a podcast bookmark.
  public let episodeTitle: String?
  /// The parent show's display title for a podcast bookmark.
  public let showTitle: String?
  public let title: String
  public let author: String?
  public let durationSeconds: Double?
  /// The saved position joined from the item's (or episode's) `mediaProgress` row, or `0` when
  /// there is none yet.
  public let positionSeconds: Double
  /// The joined `mediaProgress.isFinished`, or `false` when there is no progress row. A finished
  /// item keeps its bookmark, unlike Home's continue-listening row, which excludes it: the bookmark
  /// remains the retained metadata and position, but `PlaybackModel` never presents a finished
  /// bookmark as now playing.
  public let isFinished: Bool

  public init(
    serverItemId: String,
    episodeID: String? = nil,
    episodeTitle: String? = nil,
    showTitle: String? = nil,
    title: String,
    author: String?,
    durationSeconds: Double?,
    positionSeconds: Double,
    isFinished: Bool
  ) {
    self.serverItemId = serverItemId
    self.episodeID = episodeID
    self.episodeTitle = episodeTitle
    self.showTitle = showTitle
    self.title = title
    self.author = author
    self.durationSeconds = durationSeconds
    self.positionSeconds = positionSeconds
    self.isFinished = isFinished
  }
}
