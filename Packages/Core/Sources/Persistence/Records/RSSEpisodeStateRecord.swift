import Foundation
import GRDB

/// Local playback state for one RSS episode. Keyed by the episode row itself; there is one
/// writer and no outbox, so the row carries only position, finish, this device's Continue
/// Listening dismissal, and the monotonic sequence.
public struct RSSEpisodeStateRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "rssEpisodeState"

  public var episodeId: Int64
  public var position: Double
  public var finished: Bool
  /// This device's dismissal of the episode from Continue Listening. Any later progress write
  /// clears it, mirroring the account-owned `mediaProgress.hideFromContinueListening`: resuming an
  /// episode is how you undo having dismissed it.
  public var hideFromContinueListening: Bool
  public var localSequence: Int64
  public var updatedAt: Date

  public init(
    episodeId: Int64,
    position: Double,
    finished: Bool,
    hideFromContinueListening: Bool = false,
    localSequence: Int64,
    updatedAt: Date
  ) {
    self.episodeId = episodeId
    self.position = position
    self.finished = finished
    self.hideFromContinueListening = hideFromContinueListening
    self.localSequence = localSequence
    self.updatedAt = updatedAt
  }
}
