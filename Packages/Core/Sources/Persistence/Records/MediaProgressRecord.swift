import Foundation
import GRDB

/// Which side produced a progress value. Compared against `originKey` when resolving conflicts
/// `local` rows carry the account's persisted client UUID as their origin key, `server` rows
/// always carry the fixed sentinel `"server"`.
public enum ProgressOrigin: String, Codable, Sendable, DatabaseValueConvertible {
  case local
  case server

  /// Fixed origin-key sentinel for server-pulled progress rows. Local rows
  /// use the account's persisted `clientUUID` instead.
  public static let serverOriginKey = "server"
}

/// One progress row per item, or per podcast episode (`podcastEpisodeId` non-nil), never both
/// for the same identity. Two partial unique indices enforce this.
public struct MediaProgressRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "mediaProgress"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64
  public var podcastEpisodeId: Int64?
  public var currentTime: Double
  /// The app-owned serialized `ReaderCore.ReadingPosition`. Persistence stores the bounded JSON
  /// text without importing ReaderCore; the reader layer owns encoding/decoding the value type.
  public var readingPositionJSON: String?
  /// The server-compatible whole-book fraction. Unlike `ebookLocation`, this is also written by
  /// the local reader and therefore shares the row with local position state.
  public var ebookProgress: Double?
  /// A server-pulled CFI retained verbatim for diagnostics/future consumption. Local ebook
  /// position writes never modify this field.
  public var ebookLocation: String?
  public var isFinished: Bool
  /// Server-owned shelf visibility. A local audio position mutation clears it because listening
  /// again makes the item resumable; it never changes the independent completion state.
  public var hideFromContinueListening: Bool
  public var serverUpdatedAt: Date?
  /// When this device last used the item: a local wall-clock stamp written by every local
  /// position write and by an applied server observation. Display-only recency (the Home
  /// carousels): `serverUpdatedAt` moves only when a server observation wins a merge, and
  /// `localSequence` is a per-row edit counter, so neither answers "what did I play last".
  /// Never a conflict-resolution input.
  public var lastActivityAt: Date?
  public var localSequence: Int64
  public var origin: ProgressOrigin
  public var originKey: String
  /// The server progress row id this device last observed for the identity (v71). Written only
  /// from pulls, and cleared when this device's own reset is acknowledged; a local write never
  /// sets it. Its loss on a later complete snapshot is evidence of a server-side reset.
  public var serverProgressId: String?
  /// The server `lastUpdate` of that row when it was observed (v71). Written and cleared with
  /// `serverProgressId`, never from a local clock.
  public var serverProgressUpdatedAt: Date?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    currentTime: Double,
    isFinished: Bool,
    hideFromContinueListening: Bool = false,
    serverUpdatedAt: Date? = nil,
    localSequence: Int64,
    origin: ProgressOrigin,
    originKey: String,
    readingPositionJSON: String? = nil,
    ebookProgress: Double? = nil,
    ebookLocation: String? = nil,
    lastActivityAt: Date? = nil,
    serverProgressId: String? = nil,
    serverProgressUpdatedAt: Date? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.currentTime = currentTime
    self.readingPositionJSON = readingPositionJSON
    self.ebookProgress = ebookProgress
    self.ebookLocation = ebookLocation
    self.isFinished = isFinished
    self.hideFromContinueListening = hideFromContinueListening
    self.serverUpdatedAt = serverUpdatedAt
    self.lastActivityAt = lastActivityAt
    self.localSequence = localSequence
    self.origin = origin
    self.originKey = originKey
    self.serverProgressId = serverProgressId
    self.serverProgressUpdatedAt = serverProgressUpdatedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
