import Foundation
import GRDB

/// A durable "needsResolution" progress conflict: the server observation the zero-position guard
/// rejected, kept alongside the still-visible local `MediaProgressRecord` so `ResolutionCenter`
/// can apply it (take-server) or discard it (keep-local) without re-fetching from the server.
/// One row per item or episode identity; `MediaProgressDAO.recordConflict` refreshes rather than
/// stacks.
public struct ProgressConflictRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "progressConflict"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64
  public var podcastEpisodeId: Int64?
  public var serverCurrentTime: Double
  public var serverIsFinished: Bool
  public var serverUpdatedAt: Date?
  public var detectedAt: Date
  /// The server's ebook fraction when the ebook position is part of the conflict. `nil` for an
  /// audio-only conflict, so take-server leaves the local ebook value alone.
  public var serverEbookProgress: Double?
  /// The server's CFI alongside `serverEbookProgress`, so take-server lands on the exact location
  /// rather than only the fraction.
  public var serverEbookLocation: String?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64?,
    serverCurrentTime: Double,
    serverIsFinished: Bool,
    serverUpdatedAt: Date? = nil,
    detectedAt: Date,
    serverEbookProgress: Double? = nil,
    serverEbookLocation: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.serverCurrentTime = serverCurrentTime
    self.serverIsFinished = serverIsFinished
    self.serverUpdatedAt = serverUpdatedAt
    self.detectedAt = detectedAt
    self.serverEbookProgress = serverEbookProgress
    self.serverEbookLocation = serverEbookLocation
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
