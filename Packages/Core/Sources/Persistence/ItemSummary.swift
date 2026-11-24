import Foundation

/// A read-only, UI-facing projection of one item row, observed by `LibraryBrowseModel`,
/// `ItemDetailModel` and `SearchModel` (ARCHITECTURE.md: screens observe DB projections, never
/// raw GRDB records). Identified by the server item id, matching
/// `NavigationModel.Route.itemDetail`. The internal Int64 row id never crosses this boundary.
/// Item ids are globally unique on the server (`GET /api/items/{id}` takes no library scope).
public struct ItemSummary: Sendable, Equatable, Identifiable {
  public var id: String { serverItemId }
  public let serverItemId: String
  public let mediaKind: String
  public let title: String
  public let author: String?
  public let durationSeconds: Double?
  /// Item-level persisted audio position, or `0` when the projection has no progress row.
  public let progressSeconds: Double
  /// The derived audiobook/podcast/ebook category (`ItemMediaCategory.derive`). Defaults to a
  /// safe fallback; Home projections populate it from real signals.
  public let category: ItemMediaCategory
  /// True when the persisted document is an EPUB Whirr can read. This is independent of
  /// `category`: mixed EPUB items remain `.audiobook` while carrying this capability; PDF
  /// sidecars do not.
  public let hasReadableEbook: Bool
  /// Item-level `addedAt`, for Home's recently-added sort.
  public let addedAt: Date?
  public let seriesName: String?
  public let narratorName: String?
  public let expandedMetadataFetchedAt: Date?
  /// The item's own synopsis, still carrying whatever HTML the feed supplied. The show header
  /// strips it through `PodcastShowPresentation.synopsis`.
  public let itemDescription: String?
  /// Authoritative expected transfer bytes from the expanded item response. These are not the
  /// bytes currently stored on this device.
  public let audioDownloadExpectedBytes: Int64?
  public let ebookDownloadExpectedBytes: Int64?
  /// Opaque SHA-256 identity of a podcast source feed. Nil for books, unknown server metadata,
  /// and malformed persisted fingerprints.
  public let podcastFeedFingerprint: String?
  /// Device-owned RSS show artwork declaration and its credential-admission origin. ABS
  /// projections leave both nil; directory search results use a separate presentation type.
  public let artworkURL: URL?
  public let artworkFeedURL: URL?
  /// The item's server `updatedAt`: the revision of its ABS cover. A rescan that sees a replaced
  /// cover file moves it. Nil for RSS and for seeds built before the stored row is read.
  public let serverUpdatedAt: Date?

  public init(
    serverItemId: String,
    mediaKind: String,
    title: String,
    author: String?,
    durationSeconds: Double?,
    progressSeconds: Double = 0,
    category: ItemMediaCategory = .audiobook,
    hasReadableEbook: Bool = false,
    addedAt: Date? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    itemDescription: String? = nil,
    audioDownloadExpectedBytes: Int64? = nil,
    ebookDownloadExpectedBytes: Int64? = nil,
    podcastFeedFingerprint: String? = nil,
    artworkURL: URL? = nil,
    artworkFeedURL: URL? = nil,
    serverUpdatedAt: Date? = nil
  ) {
    self.serverItemId = serverItemId
    self.mediaKind = mediaKind
    self.title = title
    self.author = author
    self.durationSeconds = durationSeconds
    self.progressSeconds = progressSeconds
    self.category = category
    self.hasReadableEbook = hasReadableEbook
    self.addedAt = addedAt
    self.seriesName = seriesName
    self.narratorName = narratorName
    self.expandedMetadataFetchedAt = expandedMetadataFetchedAt
    self.itemDescription = itemDescription
    self.audioDownloadExpectedBytes = audioDownloadExpectedBytes
    self.ebookDownloadExpectedBytes = ebookDownloadExpectedBytes
    self.podcastFeedFingerprint = podcastFeedFingerprint
    self.artworkURL = artworkURL
    self.artworkFeedURL = artworkFeedURL
    self.serverUpdatedAt = serverUpdatedAt
  }
}

/// The library-scoped sync status `LibraryBrowseModel` needs to tell "still syncing",
/// "stale/offline" and error states from a normal loaded list. Derived from `syncRun` rows for
/// the library, since `SyncRunRecord`/`SyncRunState` are Persistence-internal.
public struct LibrarySyncStatus: Sendable, Equatable {
  public let isRunning: Bool
  /// True when the most recently started run for this library finished `.incomplete` or
  /// `.unstablePagination` rather than `.completed`, whether or not a later attempt is running.
  public let lastRunIncomplete: Bool
  /// The most recent `.completed` run's completion time, if any has ever completed.
  public let lastCompletedAt: Date?

  public init(isRunning: Bool, lastRunIncomplete: Bool, lastCompletedAt: Date?) {
    self.isRunning = isRunning
    self.lastRunIncomplete = lastRunIncomplete
    self.lastCompletedAt = lastCompletedAt
  }
}
