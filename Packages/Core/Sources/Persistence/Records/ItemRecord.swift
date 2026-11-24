import Foundation
import GRDB

/// One row per library item. Identity is `(libraryId, serverItemId)`, unique at the schema level.
/// `softDeleted` and `ItemSeenRecord` implement the two-pass deletion rule: a fully successful
/// traversal soft-deletes rows it did not see; a second one hard-deletes them unless referenced
/// elsewhere. The seen stamp is not a column here; see `ItemSeenRecord` for why.
///
/// Minified metadata only (mapping detail is SyncEngine's job). `sortTitle` is stored because the
/// browse index (`library + softDeleted + sortTitle`) depends on it.
public struct ItemRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "item"

  public var id: Int64?
  public var accountId: Int64
  public var libraryId: Int64
  public var serverItemId: String
  public var mediaKind: String
  public var title: String
  public var sortTitle: String
  public var author: String?
  public var durationSeconds: Double?
  /// The item's own synopsis, as the server sent it (HTML included; stripping is a presentation
  /// concern). Expanded-only, so preserve-on-absent is the sync layer's job, as for
  /// `addedAt`/`narratorName`.
  public var itemDescription: String?
  /// Item-level `addedAt` for Home's recently-added sort. Preserve-on-absent is the sync layer's
  /// job, not this record's.
  public var addedAt: Date?
  /// One of the two minified media-kind signals `ItemMediaCategory.derive` consumes (the other is
  /// `ebookFormat`).
  public var numAudioFiles: Int?
  /// The other minified media-kind signal `ItemMediaCategory.derive` consumes.
  public var ebookFormat: String?
  /// The expanded ebook file's stable server inode. Nil means no expanded file identity is
  /// currently known; minified traversals preserve the previous value in the Persistence DAOs.
  public var ebookFileIno: String?
  /// Canonical, dotless, lowercased extension from the expanded ebook file metadata.
  public var ebookFileExt: String?
  public var seriesName: String?
  public var narratorName: String?
  public var expandedMetadataFetchedAt: Date?
  /// Authoritative expected transfer sizes from the most recent expanded book response.
  public var audioDownloadExpectedBytes: Int64?
  public var ebookDownloadExpectedBytes: Int64?
  /// Read-only podcast diagnostics from an expanded show refresh. Nil means the server did
  /// not supply the field; callers must not infer "off", "never checked", or any setting default
  /// from absence.
  public var podcastAutoDownloadEpisodes: Bool?
  public var podcastLastEpisodeCheck: Date?
  public var podcastAutoDownloadSchedule: String?
  public var podcastMaxEpisodesToKeep: Int?
  public var podcastMaxNewEpisodesToDownload: Int?
  /// Change signals captured from the minified library traversal.
  public var serverUpdatedAt: Date?
  public var podcastServerEpisodeCount: Int?
  /// Opaque identity of the server podcast's source feed. Raw feed URLs are never persisted on
  /// server item rows; a missing or malformed value is treated as unknown by projections.
  public var podcastFeedFingerprint: String?
  /// The show's declared `metadata.language`, trimmed but otherwise verbatim. Nil when untagged;
  /// minified traversals that omit the field preserve the previous value in SyncEngine.
  public var podcastLanguage: String?
  /// `true`/`false` only when the server explicitly supplied a cover signal. `nil` keeps older or
  /// trimmed payloads eligible for a probe instead of incorrectly declaring that they have no art.
  public var hasServerArtwork: Bool?
  public var softDeleted: Bool

  public init(
    id: Int64? = nil,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    mediaKind: String,
    title: String,
    sortTitle: String,
    author: String? = nil,
    durationSeconds: Double? = nil,
    itemDescription: String? = nil,
    addedAt: Date? = nil,
    numAudioFiles: Int? = nil,
    ebookFormat: String? = nil,
    ebookFileIno: String? = nil,
    ebookFileExt: String? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    audioDownloadExpectedBytes: Int64? = nil,
    ebookDownloadExpectedBytes: Int64? = nil,
    podcastAutoDownloadEpisodes: Bool? = nil,
    podcastLastEpisodeCheck: Date? = nil,
    podcastAutoDownloadSchedule: String? = nil,
    podcastMaxEpisodesToKeep: Int? = nil,
    podcastMaxNewEpisodesToDownload: Int? = nil,
    serverUpdatedAt: Date? = nil,
    podcastServerEpisodeCount: Int? = nil,
    podcastFeedFingerprint: String? = nil,
    podcastLanguage: String? = nil,
    hasServerArtwork: Bool? = nil,
    softDeleted: Bool = false
  ) {
    self.id = id
    self.accountId = accountId
    self.libraryId = libraryId
    self.serverItemId = serverItemId
    self.mediaKind = mediaKind
    self.title = title
    self.sortTitle = sortTitle
    self.author = author
    self.durationSeconds = durationSeconds
    self.itemDescription = itemDescription
    self.addedAt = addedAt
    self.numAudioFiles = numAudioFiles
    self.ebookFormat = ebookFormat
    self.ebookFileIno = ebookFileIno
    self.ebookFileExt = EbookFormatNormalizer.normalize(ebookFileExt)
    self.seriesName = seriesName
    self.narratorName = narratorName
    self.expandedMetadataFetchedAt = expandedMetadataFetchedAt
    self.audioDownloadExpectedBytes = audioDownloadExpectedBytes
    self.ebookDownloadExpectedBytes = ebookDownloadExpectedBytes
    self.podcastAutoDownloadEpisodes = podcastAutoDownloadEpisodes
    self.podcastLastEpisodeCheck = podcastLastEpisodeCheck
    self.podcastAutoDownloadSchedule = podcastAutoDownloadSchedule
    self.podcastMaxEpisodesToKeep = podcastMaxEpisodesToKeep
    self.podcastMaxNewEpisodesToDownload = podcastMaxNewEpisodesToDownload
    self.serverUpdatedAt = serverUpdatedAt
    self.podcastServerEpisodeCount = podcastServerEpisodeCount
    self.podcastFeedFingerprint = podcastFeedFingerprint
    self.podcastLanguage = podcastLanguage
    self.hasServerArtwork = hasServerArtwork
    self.softDeleted = softDeleted
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  /// Matches `EbookFileInfo` normalization without making Persistence depend on ABSApi.
  static func normalizedEbookFileExtension(_ raw: String?) -> String? {
    EbookFormatNormalizer.normalize(raw)
  }

  /// Whether a row that already carries expanded metadata is owed another fetch. The Swift twin of
  /// `ItemDAO.serverItemIdsNeedingExpandedMetadataAsync`'s predicate, for callers holding a record.
  ///
  /// A row the server never dated is not stale; treating it as stale would refetch it on every
  /// read.
  public static func expandedMetadataIsStale(
    fetchedAt: Date?, serverUpdatedAt: Date?
  ) -> Bool {
    guard let fetchedAt, let serverUpdatedAt else { return false }
    return serverUpdatedAt > fetchedAt
  }

  /// Nil for both identity columns represents a minified item that omitted `ebookFile`. An
  /// authoritative expanded refresh goes through `ExpandedMetadataBatchStore` instead, where
  /// explicit nil clears a previously-known identity.
  mutating func preserveEbookIdentity(from existing: ItemRecord) {
    guard ebookFileIno == nil, ebookFileExt == nil else { return }
    ebookFileIno = existing.ebookFileIno
    ebookFileExt = existing.ebookFileExt
  }
}
