import ABSApi
import DesignSystem
import Foundation
import Persistence
import SyncEngine

nonisolated protocol CoverPaletteRecordStoring: Sendable {
  func fetch(itemId: String) async throws -> CoverPaletteRecord?
  func fetch(itemIds: [String]) async throws -> [CoverPaletteRecord]
  func upsert(_ record: CoverPaletteRecord) async throws
  /// The row now, then after every write to it.
  func observe(itemId: String) -> AsyncStream<CoverPaletteRecord?>
  /// The rows present for these items now, then after every write that changes them.
  func observe(itemIds: [String]) -> AsyncStream<[CoverPaletteRecord]>
  func removeAll() async throws
}

extension CoverPaletteRecordStore: CoverPaletteRecordStoring {}

/// Cache-only cover bytes: a miss is `nil`, never a transfer.
nonisolated protocol CoverPaletteByteReading: Sendable {
  func data(for key: ArtworkKey) async -> Data?
}

nonisolated protocol CoverPaletteArtworkJoining: Sendable {
  func awaitArrival(for key: ArtworkKey) async
}

/// The production bridge to the artwork operation the displayed cover uses. The cover client stays
/// cache-only for palette work; the pipeline is the only path that may wait for a cold visible cover.
struct CoverPaletteArtworkPipelineJoiner: CoverPaletteArtworkJoining {
  let pipeline: ArtworkImagePipeline
  let client: any ArtworkServing

  func awaitArrival(for key: ArtworkKey) async {
    _ = await pipeline.image(for: key, priority: .visible, client: client)
  }
}

private struct CoverPaletteClientReader: CoverPaletteByteReading {
  let client: any ArtworkServing

  func data(for key: ArtworkKey) async -> Data? {
    await client.data(for: key)
  }
}

/// The cover a palette answers for: account scope, item and revision, which is what the saved row
/// is checked against (`CoverPaletteWriter.recordIdentity`). A revision change or a source in a
/// different scope is a different identity, so it misses rather than serving another cover's colour.
nonisolated struct CoverPaletteIdentity: Hashable, Sendable {
  let accountScope: ArtworkAccountScope
  let itemID: String
  /// The saved row this identity reads and writes. It is `itemID` unless the cover is an image
  /// shared across items (an RSS episode's own art), where one row serves every item showing it.
  /// Memory, pinning and source-change logic follow `itemID`; only the database uses this.
  let rowID: String
  let revision: ArtworkRevision
  /// Set by a caller whose item hasn't loaded (source and revision are placeholders; `.unversioned`
  /// can't signal it, being also the final revision of an undated item). Rows are keyed by
  /// `rowID`, so a provisional identity is answered from any current row and never fetches,
  /// extracts or writes.
  let isProvisional: Bool

  init(
    accountScope: ArtworkAccountScope, itemID: String, revision: ArtworkRevision,
    rowID: String? = nil, isProvisional: Bool = false
  ) {
    self.accountScope = accountScope
    self.itemID = itemID
    self.rowID = rowID ?? itemID
    self.revision = revision
    self.isProvisional = isProvisional
  }

  init(_ key: ArtworkKey, isProvisional: Bool = false) {
    self.init(
      accountScope: key.accountScope, itemID: key.itemID, revision: key.revision,
      isProvisional: isProvisional)
  }

  /// An identity whose row is `rowID`, not the item's. The caller decides the image is shared.
  init(_ key: ArtworkKey, rowID: String, isProvisional: Bool = false) {
    self.init(
      accountScope: key.accountScope, itemID: key.itemID, revision: key.revision, rowID: rowID,
      isProvisional: isProvisional)
  }

  /// The identity for drawing `key`. An RSS image other than `showSource` is an episode's own art
  /// and reads and writes that image's row; anything else reads and writes the item's.
  init(drawing key: ArtworkKey, showSource: ArtworkSource?, isProvisional: Bool = false) {
    if case .rss(let source) = key.source, key.source != showSource {
      self.init(key, rowID: Self.episodeArtworkRowID(for: source), isProvisional: isProvisional)
    } else {
      self.init(key, isProvisional: isProvisional)
    }
  }

  /// The row id for one RSS episode image, shared by every episode and surface drawing it.
  static func episodeArtworkRowID(for source: RSSArtworkSource) -> String {
    let feedID =
      source.feedIdentity.hasPrefix("rss:")
      ? String(source.feedIdentity.dropFirst("rss:".count)) : source.feedIdentity
    return "rss-art:\(feedID)|\(source.normalizedArtworkURL)"
  }

  var recordKey: String {
    CoverPaletteWriter.recordIdentity(accountScope: accountScope, itemID: itemID, revision: revision)
  }

  /// Whether `record` is the answer for this identity. A provisional identity takes any row for
  /// its row id written by the current extraction.
  func isAnswered(by record: CoverPaletteRecord?) -> Bool {
    guard isProvisional else { return CoverPaletteWriter.answers(record, for: recordKey) }
    guard let record, record.itemId == rowID, record.carriesPageEvidence else { return false }
    return record.artworkKey.hasSuffix("|\(CoverPaletteWriter.extractionStamp)")
  }
}

/// One surface's ask for one cover's palette.
struct CoverPaletteRequest: Sendable {
  let identity: CoverPaletteIdentity
  /// Where the pixels come from. Only a visible request waits on `awaitArrival`.
  let bytes: CoverPaletteService.CoverBytes
  var requestClass: CoverPaletteWriter.RequestClass = .visible
  /// Parked while the shell is covered. Home's cards are; the surface doing the covering, the
  /// player or item detail, never is.
  var isCoverable = false
  /// A background writer's request (`CoverPaletteService.save`): not followed, and kept in memory
  /// only when a surface wants the same identity.
  var isSaveOnly = false
}

/// Told about palettes the service resolved for identities a request left unanswered, and about
/// clears. Notices wait while the shell is covered.
@MainActor
protocol CoverPaletteServiceObserver: AnyObject {
  func paletteServiceDidAnswer(_ palettes: [CoverPaletteIdentity: CoverPalette])
  func paletteServiceDidClear()
}

extension CoverPaletteService {
  /// The displayed artwork key for a player or detail surface. Extraction reads the palette source
  /// derived from it (`CoverPaletteSource`), not necessarily these bytes. Built here so the call
  /// sites cannot drift onto different keys and miss each other's fetch.
  static func artworkKey(
    itemID: String,
    coverClient: any ArtworkServing,
    source: ArtworkSource? = nil,
    displaySize: CGFloat,
    displayScale: CGFloat,
    role: CoverImageView.Role,
    revision: ArtworkRevision
  ) -> ArtworkKey {
    CoverImageView.artworkKey(
      itemID: itemID, client: coverClient, source: source, displaySize: displaySize,
      displayScale: displayScale, role: role, revision: revision)
  }

  /// The off-main derivation entry point, injectable so tests can substitute a counting fake
  /// without touching Core Image. Production calls `CoverPaletteExtractor.shared.samples(from:)`.
  nonisolated struct Extraction: Sendable {
    var samples: @Sendable (Data) async -> CoverPaletteSamples?

    static let production = Extraction(samples: { data in
      await CoverPaletteExtractor.shared.samples(from: data)
    })
  }

  /// How the shell's service reads cover bytes for a card that hands it only the key it displays.
  nonisolated struct Artwork: Sendable {
    let reader: any CoverPaletteByteReading
    let joiner: any CoverPaletteArtworkJoining

    init(reader: any CoverPaletteByteReading, joiner: any CoverPaletteArtworkJoining) {
      self.reader = reader
      self.joiner = joiner
    }

    init(coverClient: any ArtworkServing, pipeline: ArtworkImagePipeline = .shared) {
      self.init(
        reader: CoverPaletteClientReader(client: coverClient),
        joiner: CoverPaletteArtworkPipelineJoiner(pipeline: pipeline, client: coverClient))
    }

    /// Bytes for a surface displaying `displayed`, by `CoverPaletteWriter`'s rules: the cached
    /// palette source, and a wait on the displayed cover's own fetch only when that cover can
    /// stand in for the card. Only a visible derivation ever waits. Main-actor because the card key
    /// is sized from the current trait collection (`CoverPaletteSource.cardKey`).
    @MainActor
    func bytes(displayed: ArtworkKey) -> CoverBytes {
      let reader = reader
      let joiner = joiner
      let cached: @Sendable () async -> Data? = {
        await CoverPaletteWriter.cachedSourceBytes(displayed: displayed) { await reader.data(for: $0) }
      }
      guard CoverPaletteWriter.mayJoinDisplayFetch(displayed, requestClass: .visible) else {
        return CoverBytes(cached: cached, awaitArrival: {})
      }
      return CoverBytes(cached: cached, awaitArrival: { await joiner.awaitArrival(for: displayed) })
    }
  }

  /// Source pixels in two steps. `CoverImageClient.data(for:)` is cache-only (palette work never
  /// opens its own transfer or spends one of the six cover permits), so a single read loses the
  /// race with a download in flight and leaves the page neutral for the session after a cold
  /// launch. `awaitArrival` joins the display fetch already running for the key.
  nonisolated struct CoverBytes: Sendable {
    /// The cached compressed cover bytes, or `nil` while they are still in flight.
    var cached: @Sendable () async -> Data?
    /// Resolves once the artwork operation for this key has finished, whatever its outcome.
    var awaitArrival: @Sendable () async -> Void

    /// Production wiring. `ArtworkImagePipeline` coalesces by `ArtworkKey`, so when the on-screen
    /// cover is already fetching this key this joins that operation and adds no transfer of its
    /// own. `CoverImageClient` caches the response on the way past, so the second read hits.
    static func artwork(
      key: ArtworkKey,
      coverClient: any ArtworkServing,
      pipeline: ArtworkImagePipeline = .shared
    ) -> Self {
      Self(
        cached: { await coverClient.data(for: key) },
        awaitArrival: { _ = await pipeline.image(for: key, priority: .visible, client: coverClient) })
    }

    /// Bytes for a surface displaying `displayed`, by `CoverPaletteWriter`'s rules for a visible
    /// request: the cached palette source, and a wait on the displayed cover's own fetch only when
    /// that cover can stand in for the card. Main-actor for the same reason as `Artwork.bytes`.
    @MainActor
    static func paletteSource(
      displayed: ArtworkKey,
      coverClient: any ArtworkServing,
      pipeline: ArtworkImagePipeline = .shared
    ) -> Self {
      let cached: @Sendable () async -> Data? = {
        await CoverPaletteWriter.cachedSourceBytes(displayed: displayed) {
          await coverClient.data(for: $0)
        }
      }
      guard CoverPaletteWriter.mayJoinDisplayFetch(displayed, requestClass: .visible) else {
        return Self(cached: cached, awaitArrival: {})
      }
      return Self(
        cached: cached,
        awaitArrival: {
          _ = await pipeline.image(for: displayed, priority: .visible, client: coverClient)
        })
    }
  }
}
