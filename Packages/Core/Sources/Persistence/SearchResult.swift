import Foundation

/// The shared search vocabulary: the value types that local ranking, FTS5, the SyncEngine
/// fan-out and AppModel's merge/section assembly build rows and sections out of. No GRDB or wire
/// type appears here (ARCHITECTURE.md): this is a read-only, UI-facing projection, mirroring
/// `HomeItem`'s boundary rule.
public enum SearchResultKind: String, Sendable, CaseIterable {
  case book
  case podcast
  case episode
  case author
  case series
}

/// Why a row matched, as data only. `field` is the server `matchKey` (e.g. `"narrator"`) or the
/// local column name a `LIKE`/FTS hit came from. Rendering `field`/`text` into copy like
/// "Narrator: Rob Inglis" is AppModel's job (`SearchCopy`), not this type's.
public struct SearchMatchReason: Sendable, Equatable {
  public let field: String
  public let text: String?

  public init(field: String, text: String? = nil) {
    self.field = field
    self.text = text
  }
}

/// One search result row, of any kind. `entityID` is the server identity for that kind: an item
/// id for `.book`/`.podcast`/`.episode`, an author id for `.author`, a series id for `.series`.
/// `parentItemID` is only ever set for `.episode`, carrying the show it belongs to.
public struct SearchResultRow: Sendable, Equatable, Identifiable {
  /// Kind-prefixed so an entity id never collides across kinds: a book and an author both
  /// called `"abc"` produce distinct ids.
  public var id: String { "\(kind.rawValue)#\(entityID)" }
  public let kind: SearchResultKind
  public let entityID: String
  public let parentItemID: String?
  public let title: String
  public let subtitle: String?
  public let matchReason: SearchMatchReason?
  /// The derived audiobook/podcast/ebook category for item-backed rows, so a `.book` row can
  /// render the ebook glyph. `nil` when the backing item is unknown (a server hit not yet resolved
  /// locally) and for `.episode`/`.author`/`.series`; renderers use the kind's default glyph.
  public let mediaCategory: ItemMediaCategory?
  /// True when the backing item has a readable EPUB. Like `mediaCategory`, this is orthogonal to
  /// the primary media kind so mixed EPUB audiobook rows can expose both capabilities without
  /// treating PDF supplements as ebooks.
  public let hasReadableEbook: Bool
  /// The item's series as the server states it: one string carrying the sequence
  /// (`"Dungeon Crawler Carl #6"`), as the minified library route flattens `series[]`. Never
  /// parsed apart. `nil` for kinds with no series and for an item not in one.
  public let seriesName: String?
  /// Audiobook length from the minified library item response. A zero or absent value is carried
  /// as server data here; presentation decides whether it is meaningful for the resolved media
  /// category rather than turning ebook-only `0` values into visible metadata.
  public let durationSeconds: Double?
  /// Expanded audiobook narrator credit when the durable item projection has fetched it. The
  /// minified author/series listing does not include this field, so models may enrich a fresh row
  /// with the cached value for the same server item.
  public let narratorName: String?
  public let libraryID: String
  /// The backing server item's `updatedAt`, which revisions its cover. An episode row carries its
  /// show's, since an episode draws the show's cover; author and series rows carry `nil`.
  public let serverUpdatedAt: Date?

  public init(
    kind: SearchResultKind,
    entityID: String,
    parentItemID: String? = nil,
    title: String,
    subtitle: String? = nil,
    matchReason: SearchMatchReason? = nil,
    mediaCategory: ItemMediaCategory? = nil,
    hasReadableEbook: Bool = false,
    seriesName: String? = nil,
    durationSeconds: Double? = nil,
    narratorName: String? = nil,
    libraryID: String,
    serverUpdatedAt: Date? = nil
  ) {
    self.kind = kind
    self.entityID = entityID
    self.parentItemID = parentItemID
    self.title = title
    self.subtitle = subtitle
    self.matchReason = matchReason
    self.mediaCategory = mediaCategory
    self.hasReadableEbook = hasReadableEbook
    self.seriesName = seriesName
    self.durationSeconds = durationSeconds
    self.narratorName = narratorName
    self.libraryID = libraryID
    self.serverUpdatedAt = serverUpdatedAt
  }
}

/// One kind's worth of results, in display order. `hasMore` is per-section: `loadMore` pages one
/// section at a time, not the whole result set.
public struct SearchSection: Sendable, Equatable, Identifiable {
  public var id: SearchResultKind { kind }
  public let kind: SearchResultKind
  /// Kept in the order given: ranking is decided upstream (SQL for local results, the merge for
  /// the assembled list) and never re-sorted here.
  public let rows: [SearchResultRow]
  public let hasMore: Bool

  public init(kind: SearchResultKind, rows: [SearchResultRow], hasMore: Bool) {
    self.kind = kind
    self.rows = rows
    self.hasMore = hasMore
  }
}
