import Foundation

/// A read-only, UI-facing projection of one item for the Home screen's sections
/// (screens observe DB projections, never raw GRDB records; see ARCHITECTURE.md). Unlike
/// `ItemSummary`, `HomeReading`'s projections are account-scoped and cross-library, so this
/// carries no `libraryId`.
public struct HomeItem: Sendable, Equatable, Identifiable {
  public var id: String { serverItemId }
  public let serverItemId: String
  /// The selected server episode identity for a podcast Continue Listening row. `nil` for
  /// audiobook/eBook continuation and for the item-level Recently Added/Downloaded projections.
  public let episodeID: String?
  /// The selected episode title paired with `episodeID`; the item-level `title` remains the
  /// parent show's title so existing item-card call sites keep their established meaning.
  public let episodeTitle: String?
  public let title: String
  public let author: String?
  public let category: ItemMediaCategory
  /// True when the persisted document is a readable EPUB, including for mixed audiobook rows.
  public let hasReadableEbook: Bool
  public let durationSeconds: Double?
  /// The item-level `mediaProgress.currentTime`, or `0` when the item has no progress row.
  public let progressSeconds: Double
  /// The item-level `mediaProgress.ebookProgress`, or `0` when the item has no ebook progress.
  public let ebookProgress: Double
  /// The item-level `mediaProgress.isFinished`, or `false` when the item has no progress row.
  public let isFinished: Bool
  public let addedAt: Date?
  public let seriesName: String?
  public let narratorName: String?
  public let expandedMetadataFetchedAt: Date?
  /// Whether `DownloadStore.itemStatus` rolls this item up to `.completed`. Read, never re-derived.
  public let isDownloaded: Bool
  /// Whether the item's audio rows are all locally completed. This is additive detail for the
  /// Downloaded projection; callers that do not project per-format rows retain `false`.
  public let audioDownloaded: Bool
  /// Whether the item's ebook rows are all locally completed. This is additive detail for the
  /// Downloaded projection; callers that do not project per-format rows retain `false`.
  public let ebookDownloaded: Bool
  /// Whether the item's supplement PDFs are all locally completed. Projected by the Downloaded
  /// shelf only, for its "Audiobook + PDF" copy; never part of `isDownloaded`.
  public let supplementDownloaded: Bool
  /// The artwork URL declared by a device-owned RSS feed. `nil` for projections whose source does
  /// not provide feed artwork or when the feed has no declared artwork.
  public let artworkURL: URL?
  /// The device-owned RSS feed URL used as the artwork's credential-admission origin. `nil` for
  /// projections that do not carry a feed artwork source.
  public let artworkFeedURL: URL?
  /// The most recent local or server progress activity used to order continuation rows. `nil`
  /// when the source does not project a progress activity timestamp.
  public let progressRecency: Date?
  /// The item's server `updatedAt`, the revision of its ABS cover (see `ItemSummary`).
  public let serverUpdatedAt: Date?

  public var itemSummary: ItemSummary {
    ItemSummary(
      serverItemId: serverItemId,
      mediaKind: category == .podcast ? "podcast" : "book",
      title: title,
      author: author,
      durationSeconds: durationSeconds,
      progressSeconds: progressSeconds,
      category: category,
      hasReadableEbook: hasReadableEbook,
      addedAt: addedAt,
      seriesName: seriesName,
      narratorName: narratorName,
      expandedMetadataFetchedAt: expandedMetadataFetchedAt,
      artworkURL: artworkURL,
      artworkFeedURL: artworkFeedURL,
      serverUpdatedAt: serverUpdatedAt)
  }

  public init(
    serverItemId: String,
    title: String,
    author: String?,
    category: ItemMediaCategory,
    hasReadableEbook: Bool = false,
    durationSeconds: Double?,
    progressSeconds: Double,
    ebookProgress: Double = 0,
    isFinished: Bool,
    addedAt: Date?,
    isDownloaded: Bool,
    audioDownloaded: Bool = false,
    ebookDownloaded: Bool = false,
    supplementDownloaded: Bool = false,
    artworkURL: URL? = nil,
    artworkFeedURL: URL? = nil,
    progressRecency: Date? = nil,
    serverUpdatedAt: Date? = nil
  ) {
    self.init(
      serverItemId: serverItemId,
      title: title,
      author: author,
      category: category,
      hasReadableEbook: hasReadableEbook,
      durationSeconds: durationSeconds,
      progressSeconds: progressSeconds,
      ebookProgress: ebookProgress,
      isFinished: isFinished,
      addedAt: addedAt,
      isDownloaded: isDownloaded,
      seriesName: nil,
      narratorName: nil,
      expandedMetadataFetchedAt: nil,
      episodeID: nil,
      episodeTitle: nil,
      audioDownloaded: audioDownloaded,
      ebookDownloaded: ebookDownloaded,
      supplementDownloaded: supplementDownloaded,
      artworkURL: artworkURL,
      artworkFeedURL: artworkFeedURL,
      progressRecency: progressRecency,
      serverUpdatedAt: serverUpdatedAt)
  }

  public init(
    serverItemId: String,
    title: String,
    author: String?,
    category: ItemMediaCategory,
    hasReadableEbook: Bool = false,
    durationSeconds: Double?,
    progressSeconds: Double,
    ebookProgress: Double = 0,
    isFinished: Bool,
    addedAt: Date?,
    isDownloaded: Bool,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    episodeID: String?,
    episodeTitle: String?,
    audioDownloaded: Bool = false,
    ebookDownloaded: Bool = false,
    supplementDownloaded: Bool = false,
    artworkURL: URL? = nil,
    artworkFeedURL: URL? = nil,
    progressRecency: Date? = nil,
    serverUpdatedAt: Date? = nil
  ) {
    self.serverItemId = serverItemId
    self.episodeID = episodeID
    self.episodeTitle = episodeTitle
    self.title = title
    self.author = author
    self.category = category
    self.hasReadableEbook = hasReadableEbook
    self.durationSeconds = durationSeconds
    self.progressSeconds = progressSeconds
    self.ebookProgress = ebookProgress
    self.isFinished = isFinished
    self.addedAt = addedAt
    self.seriesName = seriesName
    self.narratorName = narratorName
    self.expandedMetadataFetchedAt = expandedMetadataFetchedAt
    self.isDownloaded = isDownloaded
    self.audioDownloaded = audioDownloaded
    self.ebookDownloaded = ebookDownloaded
    self.supplementDownloaded = supplementDownloaded
    self.artworkURL = artworkURL
    self.artworkFeedURL = artworkFeedURL
    self.progressRecency = progressRecency
    self.serverUpdatedAt = serverUpdatedAt
  }
}
