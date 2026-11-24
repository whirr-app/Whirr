import ABSApi
import DesignSystem
import Foundation
import Persistence
import Testing

@testable import Whirr

/// What the players and item detail read from `CoverPaletteService`: the palette for the identity
/// an item's surfaces last asked for, the player's pin, and the first-frame path before a
/// navigation. The lifecycle itself is `CoverPaletteServiceTests`.
@MainActor
struct CoverPaletteSurfaceTests {
  private nonisolated static let sampleData = Data([0x01, 0x02, 0x03])

  private nonisolated static let samples = CoverPaletteSamples(
    average: CoverRGBA(red: 0.2, green: 0.3, blue: 0.4),
    dominant: [CoverRGBA(red: 0.9, green: 0.2, blue: 0.2)])

  private static var palette: CoverPalette { CoverAmbientPalette.palette(from: samples) }

  /// The scale at which a home card is the palette source on this device, so a cached card is the
  /// cover every surface extracts from.
  private static var cardScale: CGFloat {
    CGFloat(CoverPaletteSource.cardPixelWidth) / HomeView.cardCoverSize
  }

  @Test("An item shows the identity its surfaces last asked for")
  func anItemShowsTheIdentityLastAskedFor() async {
    let counter = EditorialWashTestCallCounter()
    let service = CoverPaletteService(
      extraction: .init(samples: { _ in
        await counter.increment()
        return Self.samples
      }))
    let first = CoverPaletteIdentity(
      accountScope: ArtworkAccountScope("scope"), itemID: "item-1",
      revision: ArtworkRevision("revision-1"))
    let replaced = CoverPaletteIdentity(
      accountScope: ArtworkAccountScope("scope"), itemID: "item-1",
      revision: ArtworkRevision("revision-2"))
    let warm = CoverPaletteService.CoverBytes(cached: { Self.sampleData }, awaitArrival: {})
    let never = CoverPaletteService.CoverBytes(cached: { nil }, awaitArrival: {})

    await service.show(first, bytes: warm)
    #expect(service.palette(forItem: "item-1") == Self.palette)

    await service.show(replaced, bytes: never)
    #expect(service.palette(forItem: "item-1") == nil)
    await service.show(first, bytes: warm)
    #expect(service.palette(forItem: "item-1") == Self.palette)
    #expect(await counter.value == 1)
  }

  /// The expanded player rebuilds its item model as it opens, so its own identity is provisional
  /// for its first frames. Reading by identity alone, it would open neutral beside the coloured
  /// mini-player it covers.
  @Test("A provisional surface reads the colour its item's other surface resolved")
  func aProvisionalSurfaceReadsTheResolvedColour() async {
    let service = CoverPaletteService(extraction: .init(samples: { _ in Self.samples }))
    let resolved = CoverPaletteIdentity(
      accountScope: ArtworkAccountScope("scope"), itemID: "item-1",
      revision: ArtworkRevision("revision-1"))
    let provisional = CoverPaletteIdentity(
      accountScope: ArtworkAccountScope("scope"), itemID: "item-1", revision: .unversioned,
      isProvisional: true)
    let warm = CoverPaletteService.CoverBytes(cached: { Self.sampleData }, awaitArrival: {})

    await service.show(resolved, bytes: warm)

    #expect(service.palette(for: provisional) == nil)
    #expect(service.palette(forItem: "item-1") == Self.palette)
  }

  @Test("Pinning the player's item pins whichever identity it asks for next")
  func retainingPinsTheItemsCurrentIdentity() async {
    let service = CoverPaletteService(extraction: .init(samples: { _ in Self.samples }), cacheLimit: 2)
    let warm = CoverPaletteService.CoverBytes(cached: { Self.sampleData }, awaitArrival: {})
    func identity(_ itemID: String, _ revision: String = "r1") -> CoverPaletteIdentity {
      CoverPaletteIdentity(
        accountScope: ArtworkAccountScope("scope"), itemID: itemID,
        revision: ArtworkRevision(revision))
    }

    service.pin(itemID: "player")
    await service.show(identity("player"), bytes: warm)
    await service.show(identity("player", "r2"), bytes: warm)
    for other in ["a", "b", "c"] {
      await service.show(identity(other), bytes: warm)
    }

    #expect(service.palette(forItem: "player") != nil)
    #expect(service.palette(for: identity("player")) == nil)
  }

  @Test("A cached selected cover derives before navigation without another transfer")
  func cachedBytesFinishBeforeNavigation() async throws {
    let (client, transport, key) = try makeCoverClientAndKey(itemID: "selected")
    _ = try await client.fetch(key)
    let service = CoverPaletteService(extraction: .init(samples: { _ in Self.samples }))

    // The subject is "cached bytes derive without a second transfer", not "this machine wins a
    // 16 ms race": on a loaded host the detached derivation is legitimately not scheduled in time.
    // The tight budget is asserted where it is the subject, `cacheMissNeverDelaysNavigation`.
    await Self.prepare(service, key: key, client: client, deadline: .seconds(10))

    #expect(service.palette(forItem: "selected") != nil)
    #expect(transport.requestCount == 1)
  }

  @Test("A selected-cover cache miss navigates without starting network traffic")
  func cacheMissNeverDelaysNavigation() async throws {
    let (client, transport, key) = try makeCoverClientAndKey(itemID: "cold")
    let service = CoverPaletteService(extraction: .init(samples: { _ in Self.samples }))

    await Self.prepare(service, key: key, client: client)

    #expect(service.palette(forItem: "cold") == nil)
    #expect(transport.requestCount == 0)
  }

  /// A saved palette is the whole answer for the first frame, and needs no cover bytes: the tapped
  /// cell's variant may never have reached the byte cache. Gating on bytes painted the neutral
  /// fallback and then the accent on every first visit to a title whose colour was already known.
  @Test("A saved palette prepares before navigation without cached cover bytes")
  func savedPalettePreparesWithoutCachedBytes() async throws {
    let (client, transport, key) = try makeCoverClientAndKey(itemID: "item-1")
    let records = FakeCoverPaletteRecordStoring(Self.row(for: key))
    let counter = EditorialWashTestCallCounter()
    let service = CoverPaletteService(
      extraction: .init(samples: { _ in
        await counter.increment()
        return Self.samples
      }), recordStore: records)

    await Self.prepare(service, key: key, client: client)

    #expect(service.palette(forItem: "item-1") == Self.palette)
    #expect(await counter.value == 0)
    #expect(transport.requestCount == 0)
  }

  /// The one-frame budget keeps a Core Image pass off the navigation path. A saved row is one local
  /// read, so it is awaited rather than raced: losing that race is the flash itself.
  @Test("A saved palette is not abandoned when its read outlasts the frame budget")
  func savedPaletteReadIsNotRaced() async throws {
    let (client, _, key) = try makeCoverClientAndKey(itemID: "item-1")
    let records = SlowRecordStore(record: Self.row(for: key), delay: .milliseconds(60))
    let service = CoverPaletteService(
      extraction: .init(samples: { _ in Self.samples }), recordStore: records)

    await Self.prepare(service, key: key, client: client, deadline: .milliseconds(1))

    #expect(service.palette(forItem: "item-1") == Self.palette)
  }

  @Test("Repeated selection reuses the prepared palette")
  func repeatedSelectionDoesNotRederive() async throws {
    let (client, _, key) = try makeCoverClientAndKey(itemID: "selected")
    _ = try await client.fetch(key)
    let counter = EditorialWashTestCallCounter()
    let service = CoverPaletteService(
      extraction: .init(samples: { _ in
        await counter.increment()
        return Self.samples
      }))

    await Self.prepare(service, key: key, client: client, deadline: .seconds(10))
    await Self.prepare(service, key: key, client: client)

    #expect(await counter.value == 1)
  }

  @Test("Each surface key uses its displayed artwork role and size")
  func eachSurfaceDerivesFromItsOwnDisplayedArtworkKey() throws {
    let (client, _, _) = try makeCoverClientAndKey(itemID: "item")

    #expect(
      CoverPaletteService.artworkKey(
        itemID: "item", coverClient: client, displaySize: 140, displayScale: 3,
        role: .homeCard, revision: .unversioned
      ).variant == .homeCard(displaySize: 140, displayScale: 3))
    #expect(
      CoverPaletteService.artworkKey(
        itemID: "item", coverClient: client, displaySize: 272, displayScale: 2,
        role: .highFidelity, revision: .unversioned
      ).variant == .highFidelity(displaySize: 272, displayScale: 2))
  }

  /// The navigation path's call (`LibraryShellView+Presentation`).
  private static func prepare(
    _ service: CoverPaletteService, key: ArtworkKey, client: CoverImageClient,
    deadline: Duration = .milliseconds(16)
  ) async {
    await service.prepare(
      CoverPaletteRequest(
        identity: CoverPaletteIdentity(key),
        bytes: .paletteSource(displayed: key, coverClient: client)),
      deadline: deadline)
  }

  private static func row(for key: ArtworkKey) -> CoverPaletteRecord {
    let accent = palette.rawAccentHSB
    let evidence = palette.ambientAppearance.evidence
    return CoverPaletteRecord(
      itemId: key.itemID, artworkKey: CoverPaletteWriter.recordIdentity(for: key),
      accentHue: accent?.hue, accentSaturation: accent?.saturation,
      accentBrightness: accent?.brightness, clusterWeight: evidence.clusterWeight,
      clusterRed: evidence.cluster?.red, clusterGreen: evidence.cluster?.green,
      clusterBlue: evidence.cluster?.blue, averageRed: evidence.average.red,
      averageGreen: evidence.average.green, averageBlue: evidence.average.blue,
      extractedAt: Date())
  }

  private func makeCoverClientAndKey(
    itemID: String
  ) throws -> (CoverImageClient, FakeCoverHTTPClient, ArtworkKey) {
    let server = try ABSServerConfig(url: #require(URL(string: "https://palette.example.test")))
    let transport = FakeCoverHTTPClient(imageData: Self.sampleData)
    let client = CoverImageClient(
      server: server,
      httpClient: transport)
    let key = CoverPaletteService.artworkKey(
      itemID: itemID,
      coverClient: client,
      displaySize: HomeView.cardCoverSize,
      displayScale: Self.cardScale,
      role: .homeCard, revision: .unversioned)
    return (client, transport, key)
  }
}

/// A record store whose single-row read takes `delay`, as a busy database read does.
private actor SlowRecordStore: CoverPaletteRecordStoring {
  private let record: CoverPaletteRecord
  private let delay: Duration

  init(record: CoverPaletteRecord, delay: Duration) {
    self.record = record
    self.delay = delay
  }

  func fetch(itemId: String) async throws -> CoverPaletteRecord? {
    try await Task.sleep(for: delay)
    return itemId == record.itemId ? record : nil
  }

  func fetch(itemIds: [String]) async throws -> [CoverPaletteRecord] { [] }
  func upsert(_ record: CoverPaletteRecord) async throws {}
  func removeAll() async throws {}
  nonisolated func observe(itemId: String) -> AsyncStream<CoverPaletteRecord?> {
    AsyncStream { $0.finish() }
  }
  nonisolated func observe(itemIds: [String]) -> AsyncStream<[CoverPaletteRecord]> {
    AsyncStream { $0.finish() }
  }
}
