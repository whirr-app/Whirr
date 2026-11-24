import GRDB

/// The universal local Up Next row. An ABS row carries `itemId` and optionally
/// `podcastEpisodeId`; an RSS row carries only `rssEpisodeId`. The v47 table constraint keeps
/// those source shapes mutually exclusive. An audiobook row may also carry one chapter (v96).
public struct ListeningQueueEntryRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "listeningQueueEntry"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64?
  public var podcastEpisodeId: Int64?
  public var rssEpisodeId: Int64?
  public var position: Int
  public var chapterStart: Double?
  public var chapterEnd: Double?
  public var chapterTitle: String?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64? = nil,
    podcastEpisodeId: Int64? = nil,
    rssEpisodeId: Int64? = nil,
    position: Int,
    chapterStart: Double? = nil,
    chapterEnd: Double? = nil,
    chapterTitle: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.rssEpisodeId = rssEpisodeId
    self.position = position
    self.chapterStart = chapterStart
    self.chapterEnd = chapterEnd
    self.chapterTitle = chapterTitle
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id
    container["accountId"] = accountId
    container["itemId"] = itemId
    container["podcastEpisodeId"] = podcastEpisodeId
    container["position"] = position
    // Written even when nil: `update` writes only the keys encoded here, so a chapter row
    // replaced by the whole book would otherwise keep its old chapter.
    container["chapterStart"] = chapterStart
    container["chapterEnd"] = chapterEnd
    container["chapterTitle"] = chapterTitle
    // Legacy migration fixtures can still encode a pre-split RSS row explicitly.
    if let rssEpisodeId { container["rssEpisodeId"] = rssEpisodeId }
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
