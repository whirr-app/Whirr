import ABSApi
import DesignSystem
import Foundation
import Persistence
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// For one cover, every palette surface must end with the same saved row, whichever asks first
/// and whether or not the cover is on disk. Each is driven as its view drives it, through the key
/// it draws, so a surface keyed on a cover that cannot stand in for the card is caught (how the
/// player stayed neutral while Home was coloured).
///
/// The lifecycle half pins following, revisions, covered-shell parking, clearing, provisional
/// identities and admission order. Remove a `withKnownIssue` wrapper with its fix: an unexpected
/// pass fails the suite.
@Suite("Cover palette contract", .timeLimit(.minutes(1)))
@MainActor
struct CoverPaletteContractTests {
  @Test("Whichever surface writes first, every other surface adopts its row without extracting")
  func everySurfaceAdoptsTheFirstWritersRow() async throws {
    for writer in Surface.allCases {
      let harness = ContractHarness()
      await harness.artwork.putOnDisk(harness.cardKey)

      try await harness.ask(writer)
      let row = try #require(await harness.records.record(for: harness.itemID), "\(writer)")
      #expect(CoverPaletteWriter.answers(row, for: harness.identity), "\(writer)")
      let extractionsAfterWriter = await harness.extractions.value

      for reader in Surface.allCases where reader != writer {
        try await harness.ask(reader)
      }

      #expect(await harness.extractions.value == extractionsAfterWriter, "\(writer)")
      #expect(await harness.records.upserted.count == 1, "\(writer)")
      #expect(harness.palette != nil, "\(writer)")
      #expect(harness.homeWash == harness.wash(from: row), "\(writer)")
    }
  }

  /// Every drawn cover is on disk, each a different picture, so a surface that read its own cover
  /// rather than the card would save a different colour.
  @Test("Every surface extracts the same row when each of its covers differs")
  func everySurfaceExtractsTheSameRow() async throws {
    var rows: [Surface: CoverPaletteRecord] = [:]
    for surface in Surface.allCases {
      let harness = ContractHarness()
      for key in harness.drawnKeys { await harness.artwork.putOnDisk(key) }
      try await harness.ask(surface)
      rows[surface] = await harness.records.record(for: harness.itemID)
    }

    let reference = try #require(rows[.home])
    for surface in Surface.allCases {
      let row = try #require(rows[surface], "\(surface)")
      #expect(row.artworkKey == reference.artworkKey, "\(surface)")
      #expect(row.accentHue == reference.accentHue, "\(surface)")
      #expect(row.accentSaturation == reference.accentSaturation, "\(surface)")
      #expect(row.averageRed == reference.averageRed, "\(surface)")
      #expect(row.averageBlue == reference.averageBlue, "\(surface)")
    }
  }

  /// End to end: nothing on disk, so the mini-player, which can only read the card, stays neutral,
  /// and so does a Home card resolved in bulk. The expanded player joins the fetch of the cover it
  /// draws, and both other surfaces take the row it writes.
  @Test("A cold cover colours both players and Home from the expanded player's own fetch")
  func aColdCoverColoursEverySurfaceFromThePlayersFetch() async throws {
    let harness = ContractHarness()

    try await harness.ask(.miniPlayer)
    #expect(harness.palette == nil)
    let follower = Task { await harness.followAsMiniPlayer() }
    harness.requestHomeCard(intent: .bulk)
    // One service follows the row for the players and Home alike.
    _ = await awaitCondition(
      "following", until: { await harness.records.batchObserverCount >= 1 })
    #expect(harness.homeWash == nil)

    try await harness.ask(.expandedPlayer)
    await follower.value

    #expect(await harness.artwork.fetched == [harness.expandedKey])
    #expect(harness.palette != nil)
    let row = try #require(await harness.records.record(for: harness.itemID))
    _ = await awaitCondition("home adopted", until: { harness.homeWash != nil })
    #expect(harness.homeWash == harness.wash(from: row))
  }

  @Test("Palette work fetches only the cover its surface draws, and only for a visible surface")
  func paletteWorkFetchesOnlyTheDrawnCover() async throws {
    for surface in Surface.allCases {
      let harness = ContractHarness()
      try await harness.ask(surface)
      let expected: Set<ArtworkKey> =
        switch surface {
        case .home: [harness.cardKey]
        case .expandedPlayer: [harness.expandedKey]
        case .itemDetail: [harness.detailKey]
        case .miniPlayer, .backfill: []
        }
      #expect(await harness.artwork.fetched == expected, "\(surface)")
    }
  }

  // MARK: - Lifecycle

  /// Item detail's own fetch fails, as it does offline or on a server error, and another writer
  /// saves the row afterwards. Detail must still pick that row up, or a page for an item that is
  /// not playing stays neutral.
  @Test("Item detail takes a row saved after it opened, for an item that is not playing")
  func itemDetailFollowsALateRow() async throws {
    let harness = ContractHarness()
    await harness.artwork.fail(harness.detailKey)
    try await harness.ask(.itemDetail)
    #expect(harness.palette == nil)

    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.ask(.backfill)
    #expect(await harness.records.record(for: harness.itemID) != nil)

    _ = await awaitCondition("detail adopted", until: { harness.palette != nil })
    #expect(harness.palette != nil)
  }

  /// A replaced cover arrives as a new revision with a different picture. Home re-derives under
  /// the new identity, and so must the players and detail. Their cache must not be keyed by item
  /// alone, or it returns the old colour without looking.
  @Test("A replaced cover recolours the players and item detail, not only Home")
  func aReplacedCoverRecoloursThePlayersAndDetail() async throws {
    let harness = ContractHarness()
    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.ask(.expandedPlayer)
    let original = try #require(harness.palette)

    harness.revision = ArtworkRevision("rev-2")
    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.ask(.expandedPlayer)
    try await harness.ask(.itemDetail)

    let row = await harness.records.record(for: harness.itemID)
    #expect(CoverPaletteWriter.answers(row, for: harness.identity))
    #expect(harness.palette != original)
  }

  /// A sheet or the player covering Home parks Home's cold work. The covering surface is itself a
  /// palette surface and must never be parked behind it.
  @Test("A covered shell parks Home's work but not the player's or item detail's")
  func aCoveredShellParksOnlyHome() async throws {
    for surface in [Surface.expandedPlayer, .itemDetail] {
      let harness = ContractHarness()
      harness.cover(true)
      harness.requestHomeCard(intent: .visible)
      try await harness.ask(surface)

      #expect(harness.palette != nil, "\(surface)")
      let drawn = surface == .expandedPlayer ? harness.expandedKey : harness.detailKey
      // Home may take the row the covering surface just saved, since a cheap read is allowed
      // while covered. It must not fetch its own card.
      #expect(await harness.artwork.fetched == [drawn], "\(surface)")

      harness.cover(false)
      _ = await awaitCondition("home coloured", until: { harness.homeWash != nil })
      let row = try #require(await harness.records.record(for: harness.itemID), "\(surface)")
      #expect(harness.homeWash == harness.wash(from: row), "\(surface)")
      #expect(await harness.artwork.fetched == [drawn], "\(surface)")
      #expect(await harness.extractions.value == 1, "\(surface)")
    }
  }

  /// Home asked for the card in bulk and was covered before its work ran. The player opened over
  /// it asks for the same cover: it must colour at once rather than wait behind the parked work.
  /// Home must take the player's row rather than extract again when the cover lifts.
  @Test("A player opened over Home's parked work colours at once, and Home adopts its row")
  func aVisibleRequestTakesOverParkedHomeWork() async throws {
    let harness = ContractHarness()
    await harness.artwork.putOnDisk(harness.cardKey)
    harness.cover(true)
    harness.requestHomeCard(intent: .bulk)
    try await harness.ask(.expandedPlayer)
    #expect(harness.palette != nil)

    harness.cover(false)
    _ = await awaitCondition("home coloured", until: { harness.homeWash != nil })
    let row = try #require(await harness.records.record(for: harness.itemID))
    #expect(harness.homeWash == harness.wash(from: row))
    #expect(await harness.extractions.value == 1)
    #expect(await harness.records.upserted.count == 1)
  }

  @Test("One clear empties every surface, and nothing it removed comes back")
  func oneClearEmptiesEverySurface() async throws {
    let harness = ContractHarness()
    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.ask(.home)
    try await harness.ask(.expandedPlayer)
    #expect(harness.palette != nil)
    #expect(harness.homeWash != nil)

    await harness.artwork.goOffline()
    await harness.clearArtwork()

    #expect(harness.palette == nil)
    #expect(await harness.records.storedIDs.isEmpty)
    _ = await awaitCondition("home neutral", until: { harness.homeWash == nil })
    try await harness.ask(.expandedPlayer)
    try await harness.ask(.home)
    #expect(harness.palette == nil)
    #expect(harness.homeWash == nil)
  }

  /// Both players ask before their item has loaded, under `.unversioned`. The row is keyed by item,
  /// so a write under that identity would replace the one Home saved. Home's follow would stop
  /// answering, and the player would extract again and write back once the item loads.
  @Test("A player asking before its item loads never overwrites the row Home saved")
  func aProvisionalIdentityNeverOverwritesAResolvedRow() async throws {
    let harness = ContractHarness()
    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.ask(.home)
    let resolvedIdentity = harness.identity
    _ = try #require(await harness.records.record(for: harness.itemID))
    let extractionsAfterHome = await harness.extractions.value

    harness.revision = .unversioned
    harness.isItemLoaded = false
    try await harness.ask(.expandedPlayer)

    // Shown from Home's row until the item loads, and never saved over it.
    #expect(harness.palette != nil)
    let row = await harness.records.record(for: harness.itemID)
    #expect(CoverPaletteWriter.answers(row, for: resolvedIdentity))
    #expect(await harness.extractions.value == extractionsAfterHome)
    #expect(await harness.records.upserted.count == 1)
  }

  /// A followed show's feed source reaches the player after its first frame, which drew the
  /// account's own server as a placeholder. Home already saved the row under the feed's identity.
  @Test("A followed show's source landing late on the player adopts Home's row without extracting")
  func aLateSourceAdoptsHomesRowWithoutExtracting() async throws {
    let harness = ContractHarness()
    let feed = ArtworkSource.rss(
      try #require(
        RSSArtworkSource(
          feedIdentity: "rss:contract", artworkURL: URL(string: "https://img.contract.test/show.jpg")!,
          feedURL: URL(string: "https://feed.contract.test/show.xml")!)))
    harness.source = feed
    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.ask(.home)
    let feedIdentity = harness.identity
    _ = try #require(await harness.records.record(for: harness.itemID))
    let extractionsAfterHome = await harness.extractions.value

    harness.source = nil
    harness.isItemLoaded = false
    try await harness.ask(.expandedPlayer)
    #expect(harness.palette != nil)
    harness.sourceChanged(to: feed)
    harness.isItemLoaded = true
    try await harness.ask(.expandedPlayer)

    #expect(harness.palette != nil)
    #expect(await harness.extractions.value == extractionsAfterHome)
    #expect(await harness.records.upserted.count == 1)
    let row = await harness.records.record(for: harness.itemID)
    #expect(CoverPaletteWriter.answers(row, for: feedIdentity))
  }

  /// The artwork clear removes rows before it empties memory. A surface that asks in between reads
  /// a row the clear is about to remove, and must not keep it once the clear completes.
  @Test("A surface that asks while a clear is removing rows keeps none of them")
  func aClearInProgressIsNotUndoneByARequest() async throws {
    let harness = ContractHarness()
    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.ask(.backfill)
    await harness.artwork.goOffline()
    await harness.records.holdNextRemoval()
    let clear = Task { await harness.clearArtwork() }
    await harness.records.waitUntilRemovalStarted()

    try await harness.ask(.miniPlayer)
    harness.requestHomeCard(intent: .visible)
    _ = await awaitCondition(
      "home asked",
      until: {
        if harness.homeWash != nil { return true }
        return await harness.records.batchObserverCount > 0
      })
    await harness.records.releaseRemoval()
    await clear.value

    _ = await awaitCondition("home neutral", until: { harness.homeWash == nil })
    #expect(harness.palette == nil)
    #expect(harness.homeWash == nil)
    #expect(await harness.records.storedIDs.isEmpty)
  }

  /// The playing item is pinned against eviction. After its cover is replaced the pin must hold
  /// the new colour, not the old one, through browsing that fills the cache.
  @Test("The playing cover keeps its current colour through cache pressure after a revision change")
  func thePlayingCoverSurvivesEvictionAfterARevisionChange() async throws {
    let harness = ContractHarness(cacheLimit: 2)
    await harness.artwork.putOnDisk(harness.cardKey)
    harness.retainAsPlayer()
    try await harness.ask(.miniPlayer)
    let original = try #require(harness.palette)

    harness.revision = ArtworkRevision("rev-2")
    await harness.artwork.putOnDisk(harness.cardKey)
    harness.retainAsPlayer()
    try await harness.ask(.miniPlayer)
    for other in ["other-1", "other-2", "other-3"] {
      await harness.playOther(other)
    }

    let current = try #require(harness.palette)
    #expect(current != original)
  }

  @Test("A visible writer goes ahead of a background writer already waiting to extract")
  func aVisibleWriterGoesAheadOfAWaitingBackgroundOne() async throws {
    let harness = ContractHarness()
    await harness.artwork.putOnDisk(harness.cardKey)
    try await harness.admission.acquire(priority: .visible)

    let backfill = Task { try await harness.ask(.backfill) }
    _ = await awaitCondition(
      "backfill waiting", until: { await harness.admission.queuedCount >= 1 })
    let player = Task { await harness.playOther("other-1") }
    _ = await awaitCondition("player waiting", until: { await harness.admission.queuedCount >= 2 })
    await harness.admission.release(priority: .visible)
    try await backfill.value
    await player.value

    #expect(await harness.records.upserted.map(\.itemId) == ["other-1", harness.itemID])
  }
}

private enum Surface: CaseIterable, CustomStringConvertible {
  case home, miniPlayer, expandedPlayer, itemDetail, backfill

  var description: String {
    switch self {
    case .home: "home"
    case .miniPlayer: "mini-player"
    case .expandedPlayer: "expanded player"
    case .itemDetail: "item detail"
    case .backfill: "backfill"
    }
  }
}

/// One item's surfaces wired as production wires them: one record store, one display pipeline,
/// one decode admission, and one palette service shared by both players, item detail and Home's
/// provider. `revision` and `source` are what the item's surfaces currently know. A test changes
/// them to replay a cover being replaced or a source landing late.
@MainActor
private final class ContractHarness {
  let itemID = "contract-item"
  let scale: CGFloat = 3
  var revision = ArtworkRevision("rev-1")
  /// `nil` is the account's own server: the placeholder a player draws until a followed show's
  /// feed source reaches it.
  var source: ArtworkSource?
  /// Whether the players' item has loaded. Until it has, they ask under a provisional identity.
  var isItemLoaded = true
  let artwork = ContractArtwork(scope: ArtworkAccountScope("https://contract.example.test"))
  let records = FakeCoverPaletteRecordStoring()
  let extractions = EditorialWashTestCallCounter()
  let admission = CoverDecodeAdmission(maximumConcurrent: 1)
  let pipeline = ArtworkImagePipeline(
    cache: PreparedArtworkCache(totalCostLimit: 10_000_000, countLimit: 20))
  let service: CoverPaletteService
  let homeProvider: HomeWashProvider

  init(cacheLimit: Int = 24) {
    let counter = extractions
    let samples: @Sendable (Data) async -> CoverPaletteSamples? = { data in
      await counter.increment()
      return await CoverPaletteExtractor.shared.samples(from: data)
    }
    service = CoverPaletteService(
      accountScope: artwork.scope,
      artwork: .init(
        reader: ContractBytes(client: artwork),
        joiner: CoverPaletteArtworkPipelineJoiner(pipeline: pipeline, client: artwork)),
      extraction: .init(samples: samples), admission: admission, recordStore: records,
      cacheLimit: cacheLimit)
    homeProvider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize,
      displayScale: CGFloat(CoverPaletteSource.cardPixelWidth) / HomeView.cardCoverSize)
  }

  var identity: String { CoverPaletteWriter.recordIdentity(for: cardKey) }

  var miniPlayerKey: ArtworkKey { miniPlayerKey(for: itemID) }

  func miniPlayerKey(for itemID: String) -> ArtworkKey {
    CoverPaletteService.artworkKey(
      itemID: itemID, coverClient: artwork, source: source,
      displaySize: PlayerMetric.miniPlayerCoverSize, displayScale: scale,
      role: .libraryThumbnail, revision: revision)
  }

  var expandedKey: ArtworkKey {
    ExpandedPlayerView.paletteArtworkKey(
      itemID: itemID, coverClient: artwork, source: source, displayScale: scale,
      revision: revision)
  }

  var detailKey: ArtworkKey {
    CoverPaletteService.artworkKey(
      itemID: itemID, coverClient: artwork, source: source,
      displaySize: ItemDetailView.coverDisplaySize, displayScale: scale, role: .highFidelity,
      revision: revision)
  }

  var cardKey: ArtworkKey { cardKey(for: itemID) }

  func cardKey(for itemID: String) -> ArtworkKey {
    CoverPaletteSource.cardKey(for: miniPlayerKey(for: itemID))
  }

  var drawnKeys: [ArtworkKey] { [cardKey, miniPlayerKey, expandedKey, detailKey] }

  /// What the players and item detail paint for the item.
  var palette: CoverPalette? { service.palette(forItem: itemID) }

  /// What Home's card paints for the item.
  var homeWash: CoverWash? { homeProvider.washes[itemID] }

  func ask(_ surface: Surface) async throws {
    switch surface {
    case .home:
      requestHomeCard(intent: .visible)
      _ = await awaitCondition(
        "home resolved",
        until: {
          if self.homeProvider.washes[self.itemID] != nil { return true }
          return await self.records.batchObserverCount > 0
        })
    case .miniPlayer: await derive(itemID: itemID, displayed: miniPlayerKey)
    case .expandedPlayer: await derive(itemID: itemID, displayed: expandedKey)
    case .itemDetail: await derive(itemID: itemID, displayed: detailKey)
    case .backfill: await service.save(cardKey)
    }
  }

  func requestHomeCard(intent: HomeWashProvider.RequestIntent) {
    homeProvider.request(
      [EditorialWashSubject(itemID: itemID, artworkSource: source, artworkRevision: revision)],
      intent: intent)
  }

  /// What the mini-player's palette task does once its own derivation comes back empty.
  func followAsMiniPlayer() async {
    await service.waitForPalette(CoverPaletteIdentity(miniPlayerKey))
  }

  /// What the mini-player does for the item it is playing, so its colour outlives browsing.
  func retainAsPlayer() { service.pin(itemID: itemID) }

  /// What the shell does when a followed show's artwork source changes under the player.
  func sourceChanged(to source: ArtworkSource?) {
    self.source = source
    service.sourceChanged(for: itemID)
  }

  /// The shell covering Home with a sheet or the player, or lifting that cover.
  func cover(_ covered: Bool) { service.setCovered(covered) }

  /// The artwork clear as composition runs it (`AppEnvironment+ArtworkComposition`): cover bytes,
  /// then the service, which removes the rows before the in-memory palettes.
  func clearArtwork() async {
    await artwork.removeAll()
    await service.clearCachedArtwork()
  }

  /// The mini-player for another item, whose cover is on disk: it fills the shared cache.
  func playOther(_ otherID: String) async {
    await artwork.putOnDisk(cardKey(for: otherID))
    await derive(itemID: otherID, displayed: miniPlayerKey(for: otherID))
  }

  func wash(from row: CoverPaletteRecord) -> CoverWash {
    CoverWash.from(
      hue: row.accentHue, saturation: row.accentSaturation, brightness: row.accentBrightness)
  }

  private func derive(itemID: String, displayed key: ArtworkKey) async {
    await service.show(
      CoverPaletteIdentity(key, isProvisional: isItemLoaded == false),
      bytes: .paletteSource(displayed: key, coverClient: artwork, pipeline: pipeline))
  }
}

private struct ContractBytes: CoverPaletteByteReading {
  let client: ContractArtwork

  func data(for key: ArtworkKey) async -> Data? { await client.data(for: key) }
}

/// A cover client whose fetch leaves the bytes on disk, as `CoverImageClient` does, and which
/// records every transfer. Each variant is a different picture, so the colour a row carries tells
/// which cover it was read from, and a replaced cover (any revision but the first) is a different
/// picture again.
private actor ContractArtwork: ArtworkServing {
  nonisolated let scope: ArtworkAccountScope
  nonisolated var defaultSource: ArtworkSource? { .audiobookshelf(scope) }
  private var onDisk: [ArtworkKey: Data] = [:]
  private var failing: Set<ArtworkKey> = []
  private var isOffline = false
  private(set) var fetched: Set<ArtworkKey> = []

  init(scope: ArtworkAccountScope) {
    self.scope = scope
  }

  func putOnDisk(_ key: ArtworkKey) { onDisk[key] = Self.image(for: key) }

  /// Every transfer of `key` fails, as one does on a server error.
  func fail(_ key: ArtworkKey) { failing.insert(key) }

  /// Every transfer fails from now on.
  func goOffline() { isOffline = true }

  func removeAll() { onDisk.removeAll() }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    fetched.insert(key)
    if isOffline || failing.contains(key) { throw URLError(.notConnectedToInternet) }
    let image = Self.image(for: key)
    onDisk[key] = image
    return CoverImageResult(data: image, contentType: "image/png")
  }

  func data(for key: ArtworkKey) async -> Data? { onDisk[key] }

  func needsRefresh(_ key: ArtworkKey) async -> Bool { false }

  private static func image(for key: ArtworkKey) -> Data {
    let replaced = key.revision != ArtworkRevision("rev-1")
    let fill: UIColor =
      switch key.variant {
      case .homeCard:
        replaced
          ? UIColor(red: 0.1, green: 0.55, blue: 0.6, alpha: 1)
          : UIColor(red: 0.45, green: 0.2, blue: 0.75, alpha: 1)
      case .libraryThumbnail: UIColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
      case .highFidelity, .detailFit:
        replaced
          ? UIColor(red: 0.15, green: 0.3, blue: 0.7, alpha: 1)
          : UIColor(red: 0.8, green: 0.35, blue: 0.15, alpha: 1)
      @unknown default: UIColor.gray
      }
    let size = CGSize(width: 96, height: 96)
    return UIGraphicsImageRenderer(size: size).pngData { context in
      fill.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor(red: 0.95, green: 0.85, blue: 0.3, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 64, width: 96, height: 32))
    }
  }
}
