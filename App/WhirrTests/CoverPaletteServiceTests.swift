import ABSApi
import DesignSystem
import Foundation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// The one palette owner's lifecycle: memory, the row, cached bytes, the display fetch, extraction
/// and the row write, shared per identity. Covers following unanswered requests, covered-shell
/// parking, provisional identities and clearing.
@Suite("Cover palette service", .timeLimit(.minutes(1)))
@MainActor
struct CoverPaletteServiceTests {
  // MARK: Bytes and extraction

  /// A cold launch reads the cache once, before the cover download finishes. Without a retry, the
  /// page stayed on the neutral fallback however long the artwork was on screen.
  @Test("A cold cover derives once the artwork the display is fetching arrives")
  func aColdCoverDerivesOnceItsArtworkArrives() async {
    let fixture = ServiceFixture(warm: false)

    let resolved = await fixture.service.request([fixture.request()])

    #expect(fixture.bytes.arrivalWaits == 1)
    #expect(resolved[fixture.identity] == ServiceFixture.palette)
    #expect(fixture.service.palette(for: fixture.identity) == ServiceFixture.palette)
  }

  @Test("A background request reads cached bytes only and never waits for the display fetch")
  func aBackgroundRequestNeverWaitsForTheDisplayFetch() async {
    let fixture = ServiceFixture(warm: false)

    let resolved = await fixture.service.request([fixture.request(.background)])

    #expect(resolved.isEmpty)
    #expect(fixture.bytes.arrivalWaits == 0)
    #expect(await fixture.extractions.value == 0)
  }

  @Test("A warm cover derives at once, without waiting on the artwork")
  func aWarmCoverDerivesWithoutWaiting() async {
    let fixture = ServiceFixture()

    _ = await fixture.service.request([fixture.request()])

    #expect(fixture.bytes.arrivalWaits == 0)
    #expect(fixture.service.palette(for: fixture.identity) != nil)
  }

  @Test("A cover that never arrives leaves no palette rather than retrying")
  func anUnreachableCoverLeavesNoPalette() async {
    let fixture = ServiceFixture()
    let never = CoverPaletteService.CoverBytes(cached: { nil }, awaitArrival: {})

    _ = await fixture.service.request([CoverPaletteRequest(identity: fixture.identity, bytes: never)])

    #expect(fixture.service.palette(for: fixture.identity) == nil)
  }

  @Test("Two surfaces asking for one identity, together or in turn, share one extraction")
  func oneDerivationPerIdentity() async {
    let fixture = ServiceFixture(warm: false)

    async let first = fixture.service.request([fixture.request()])
    async let second = fixture.service.request([fixture.request()])
    let (a, b) = await (first, second)
    _ = await fixture.service.request([fixture.request()])

    #expect(a[fixture.identity] != nil)
    #expect(b[fixture.identity] != nil)
    #expect(await fixture.extractions.value == 1)
  }

  /// A replaced cover is a new revision. Memory is keyed by identity, so the old colour is a miss.
  @Test("A new revision misses the cache and derives its own colour")
  func aRevisionChangeMissesTheCache() async {
    let fixture = ServiceFixture()
    _ = await fixture.service.request([fixture.request()])
    let replaced = fixture.identity(revision: "revision-2")

    #expect(fixture.service.palette(for: replaced) == nil)
    _ = await fixture.service.request([fixture.request(for: replaced)])

    #expect(fixture.service.palette(for: replaced) != nil)
    #expect(await fixture.extractions.value == 2)
  }

  /// "No work on the main actor" cannot be asserted directly without a timing race. This checks the
  /// structure instead: the production seam is `CoverPaletteExtractor`'s actor-isolated method,
  /// reachable from the service's public API end to end.
  @Test("The production extraction seam is CoverPaletteExtractor's actor-isolated method")
  func theProductionSeamIsTheExtractorsOwnMethod() async {
    let service = CoverPaletteService(extraction: .production)
    let data = ImageTestFixtures.knownGoodCoverData
    let identity = ServiceFixture.defaultIdentity

    _ = await service.request([
      CoverPaletteRequest(
        identity: identity,
        bytes: CoverPaletteService.CoverBytes(cached: { data }, awaitArrival: {}))
    ])

    #expect(service.palette(for: identity) != nil)
  }

  // MARK: Rows

  /// A row with page evidence is a complete answer: the artwork is never read, and k-means never
  /// runs.
  @Test("A matching row answers without touching the artwork")
  func aMatchingRowAnswersWithoutTouchingTheArtwork() async {
    let fixture = ServiceFixture()
    await fixture.records.seed(fixture.row())

    _ = await fixture.service.request([fixture.request()])

    #expect(await fixture.records.fetchCount == 1)
    #expect(fixture.bytes.cachedReads == 0)
    #expect(await fixture.extractions.value == 0)
    #expect(fixture.service.palette(for: fixture.identity) == ServiceFixture.palette)
  }

  /// A grey cover legitimately has no accent, and its page comes from the average the row carries.
  @Test("A row with no accent but with page evidence is an answer")
  func aNilAccentRowIsAnAnswer() async {
    let fixture = ServiceFixture()
    await fixture.records.seed(fixture.row(withoutAccent: true))

    _ = await fixture.service.request([fixture.request()])

    #expect(await fixture.extractions.value == 0)
    #expect(fixture.service.palette(for: fixture.identity)?.rawAccentHSB == nil)
    #expect(fixture.service.palette(for: fixture.identity)?.ambientAppearance.dark.mode == .dark)
  }

  /// A row without the evidence columns cannot answer the cluster-weight test, so a page built
  /// from it would differ from the one extraction builds for the same cover.
  @Test("A row without page evidence falls through to extraction and is backfilled")
  func aRowWithoutPageEvidenceIsBackfilled() async {
    let fixture = ServiceFixture()
    let accent = ServiceFixture.palette.rawAccentHSB
    await fixture.records.seed(
      CoverPaletteRecord(
        itemId: fixture.identity.itemID, artworkKey: fixture.identity.recordKey,
        accentHue: accent?.hue, accentSaturation: accent?.saturation,
        accentBrightness: accent?.brightness, extractedAt: Date()))

    _ = await fixture.service.request([fixture.request()])

    #expect(await fixture.extractions.value == 1)
    #expect(await fixture.records.upserted.last?.carriesPageEvidence == true)
  }

  @Test("A row for another revision falls through to extraction")
  func aStaleRowFallsThrough() async {
    let fixture = ServiceFixture()
    await fixture.records.seed(fixture.row(for: fixture.identity(revision: "older")))

    _ = await fixture.service.request([fixture.request()])

    #expect(await fixture.extractions.value == 1)
  }

  @Test("Extraction saves the row every surface answers from")
  func extractionWritesTheRow() async {
    let fixture = ServiceFixture()

    _ = await fixture.service.request([fixture.request()])

    let upserted = await fixture.records.upserted
    let accent = fixture.service.palette(for: fixture.identity)?.rawAccentHSB
    #expect(upserted.count == 1)
    #expect(upserted.first?.artworkKey == fixture.identity.recordKey)
    #expect(upserted.first?.accentHue == accent?.hue)
    #expect(upserted.first?.accentSaturation == accent?.saturation)
    #expect(upserted.first?.accentBrightness == accent?.brightness)
  }

  @Test("A failed row write keeps the palette")
  func aFailedWriteKeepsThePalette() async {
    let service = CoverPaletteService(
      extraction: ServiceFixture.fakeExtraction, recordStore: FailingRecordStore())
    let identity = ServiceFixture.defaultIdentity

    _ = await service.request([
      CoverPaletteRequest(
        identity: identity,
        bytes: CoverPaletteService.CoverBytes(cached: { Data([0x01]) }, awaitArrival: {}))
    ])

    #expect(service.palette(for: identity) != nil)
  }

  @Test("Cached palettes come from memory and one batch read of the rows, never from bytes")
  func cachedPalettesReadRowsInOneBatch() async {
    let fixture = ServiceFixture()
    let other = fixture.identity(itemID: "item-2")
    let missing = fixture.identity(itemID: "item-3")
    await fixture.records.seed(fixture.row())
    await fixture.records.seed(fixture.row(for: other))

    let cached = await fixture.service.cachedPalettes([fixture.identity, other, missing])

    #expect(Set(cached.keys) == [fixture.identity, other])
    #expect(await fixture.records.fetchCount == 0)
    #expect(fixture.bytes.cachedReads == 0)
    #expect(fixture.service.palette(for: other) != nil)
  }

  // MARK: Following

  /// A surface whose own derivation gave up never reads the row again, so a purple card can sit
  /// above a white play button.
  @Test("A row another writer saves after a request gave up still answers it")
  func aLateRowReachesAnUnansweredIdentity() async throws {
    let fixture = ServiceFixture()
    let never = CoverPaletteService.CoverBytes(cached: { nil }, awaitArrival: {})
    _ = await fixture.service.request([CoverPaletteRequest(identity: fixture.identity, bytes: never)])
    _ = await awaitCondition("following", until: { await fixture.records.batchObserverCount == 1 })

    try await fixture.records.upsert(fixture.row())

    _ = await awaitCondition(
      "adopted", until: { fixture.service.palette(for: fixture.identity) != nil })
    #expect(fixture.service.palette(for: fixture.identity) == ServiceFixture.palette)
    _ = await awaitCondition("stopped", until: { await fixture.records.batchObserverCount == 0 })
  }

  /// The observation is table-wide and item IDs are not account-scoped, so a row for the same item
  /// in another scope is not an answer.
  @Test("Following ignores rows for other artwork, other scopes or without page evidence")
  func followingIgnoresRowsThatDoNotAnswer() async throws {
    let fixture = ServiceFixture()
    let never = CoverPaletteService.CoverBytes(cached: { nil }, awaitArrival: {})
    _ = await fixture.service.request([CoverPaletteRequest(identity: fixture.identity, bytes: never)])
    _ = await awaitCondition("following", until: { await fixture.records.batchObserverCount == 1 })

    try await fixture.records.upsert(fixture.row(for: fixture.identity(revision: "older")))
    try await fixture.records.upsert(fixture.row(for: fixture.identity(scope: "other-scope")))
    try await fixture.records.upsert(
      CoverPaletteRecord(
        itemId: fixture.identity.itemID, artworkKey: fixture.identity.recordKey, accentHue: 0.1,
        accentSaturation: 0.5, accentBrightness: 0.5, extractedAt: Date()))
    await awaitQuiescence("settled") {
      "\(String(describing: fixture.service.palette(for: fixture.identity)))"
    }

    #expect(fixture.service.palette(for: fixture.identity) == nil)
    #expect(await fixture.records.batchObserverCount == 1)
  }

  @Test("Waiting for a palette ends when the caller is cancelled")
  func waitingForAPaletteEndsOnCancellation() async {
    let fixture = ServiceFixture()
    let waiting = Task { await fixture.service.waitForPalette(fixture.identity) }
    _ = await awaitCondition("following", until: { await fixture.records.batchObserverCount == 1 })

    waiting.cancel()
    await waiting.value

    #expect(fixture.service.palette(for: fixture.identity) == nil)
  }

  @Test("Observers hear a late answer, held while the shell is covered")
  func observersHearALateAnswerOnceUncovered() async throws {
    let fixture = ServiceFixture(warm: false)
    let observer = RecordingObserver()
    fixture.service.addObserver(observer)
    _ = await fixture.service.request([fixture.request(.background)])
    _ = await awaitCondition("following", until: { await fixture.records.batchObserverCount == 1 })

    fixture.service.setCovered(true)
    try await fixture.records.upsert(fixture.row())
    _ = await awaitCondition(
      "adopted", until: { fixture.service.palette(for: fixture.identity) != nil })
    // A covering player reads memory and colours at once; Home's notice waits for the cover.
    #expect(observer.answers.isEmpty)

    fixture.service.setCovered(false)
    #expect(observer.answers == [[fixture.identity: ServiceFixture.palette]])
  }

  @Test("An answer another request derives reaches observers of the identity left unanswered")
  func anotherRequestsAnswerReachesObservers() async {
    let fixture = ServiceFixture(warm: false)
    let observer = RecordingObserver()
    fixture.service.addObserver(observer)
    _ = await fixture.service.request([fixture.request(.background)])

    _ = await fixture.service.request([fixture.request()])

    #expect(observer.answers == [[fixture.identity: ServiceFixture.palette]])
  }

  // MARK: Provisional identities

  /// A player asks before its item has loaded, so its source and revision are placeholders. The
  /// row is keyed by item: a write would replace the resolved one.
  @Test("A provisional identity shows any current row for its item and never fetches or writes")
  func aProvisionalIdentityShowsTheRowAndNeverWrites() async {
    let fixture = ServiceFixture()
    let row = fixture.row()
    await fixture.records.seed(row)
    let provisional = fixture.identity(scope: "placeholder", revision: nil, isProvisional: true)

    let resolved = await fixture.service.request([fixture.request(for: provisional)])

    #expect(resolved[provisional] == ServiceFixture.palette)
    #expect(fixture.bytes.cachedReads == 0)
    #expect(await fixture.extractions.value == 0)
    #expect(await fixture.records.upserted.isEmpty)
    #expect(await fixture.records.record(for: fixture.identity.itemID) == row)
  }

  @Test("A provisional identity with no row reads no bytes, and takes a row saved later")
  func aProvisionalIdentityWaitsForARow() async throws {
    let fixture = ServiceFixture()
    let provisional = fixture.identity(revision: nil, isProvisional: true)

    let resolved = await fixture.service.request([fixture.request(for: provisional)])
    #expect(resolved.isEmpty)
    #expect(fixture.bytes.cachedReads == 0)
    #expect(fixture.bytes.arrivalWaits == 0)

    _ = await awaitCondition("following", until: { await fixture.records.batchObserverCount == 1 })
    try await fixture.records.upsert(fixture.row())
    _ = await awaitCondition(
      "adopted", until: { fixture.service.palette(for: provisional) != nil })
    #expect(fixture.service.palette(for: provisional) == ServiceFixture.palette)
  }

  /// `.unversioned` is also the final revision of an item the server never dated. Only the
  /// caller's flag makes an identity provisional.
  @Test("An unversioned identity the caller has not marked provisional derives and saves")
  func anUnversionedIdentityIsNotProvisional() async {
    let fixture = ServiceFixture()
    let unversioned = fixture.identity(revision: nil)

    _ = await fixture.service.request([fixture.request(for: unversioned)])

    #expect(fixture.service.palette(for: unversioned) != nil)
    #expect(await fixture.records.upserted.count == 1)
  }

  // MARK: Covered shell

  @Test("A covered shell starts no coverable work until the cover lifts")
  func aCoveredShellParksCoverableWork() async {
    let fixture = ServiceFixture(gated: true)
    fixture.service.setCovered(true)

    let home = Task { await fixture.service.request([fixture.request(.background, coverable: true)]) }
    await fixture.service.waitForSubscriberCount(fixture.identity, minimum: 1)
    await awaitQuiescence("parked") { "\(await fixture.extractions.value)" }
    #expect(await fixture.extractions.value == 0)
    #expect(fixture.bytes.cachedReads == 0)

    fixture.service.setCovered(false)
    await fixture.gate!.waitUntilStarted()
    await fixture.gate!.release()

    #expect(await home.value[fixture.identity] != nil)
    #expect(await fixture.extractions.value == 1)
  }

  /// An extraction already inside Core Image when the shell is covered finishes, but its result
  /// is neither shown nor saved until the cover lifts.
  @Test("An extraction underway when the shell is covered publishes only once it lifts")
  func anExtractionUnderwayPublishesOnceUncovered() async {
    let fixture = ServiceFixture(gated: true)
    let home = Task { await fixture.service.request([fixture.request(.background, coverable: true)]) }
    await fixture.gate!.waitUntilStarted()

    fixture.service.setCovered(true)
    await fixture.gate!.release()
    await fixture.gate!.waitUntilCompleted()
    await awaitQuiescence("held") { "\(await fixture.records.upserted.count)" }
    #expect(fixture.service.palette(for: fixture.identity) == nil)
    #expect(await fixture.records.upserted.isEmpty)

    fixture.service.setCovered(false)
    #expect(await home.value[fixture.identity] != nil)
    #expect(await fixture.records.upserted.count == 1)
    #expect(await fixture.extractions.value == 1)
  }

  @Test("The surface doing the covering is never parked")
  func theCoveringSurfaceIsNeverParked() async {
    let fixture = ServiceFixture()
    fixture.service.setCovered(true)

    let resolved = await fixture.service.request([fixture.request()])

    #expect(resolved[fixture.identity] != nil)
    #expect(await fixture.extractions.value == 1)
  }

  /// The player opened over the Home card it came from asks for the same cover. It colours at once
  /// rather than waiting behind the parked card, and both share the one extraction.
  @Test("A visible surface takes over parked work for its own cover")
  func aVisibleSurfaceTakesOverParkedWork() async {
    let fixture = ServiceFixture()
    fixture.service.setCovered(true)
    let home = Task { await fixture.service.request([fixture.request(.background, coverable: true)]) }
    await fixture.service.waitForSubscriberCount(fixture.identity, minimum: 1)

    let player = await fixture.service.request([fixture.request()])

    #expect(player[fixture.identity] != nil)
    #expect(await home.value[fixture.identity] != nil)
    #expect(await fixture.extractions.value == 1)
    #expect(await fixture.records.upserted.count == 1)
  }

  /// Parked work reads memory and the row again when it resumes: another writer may have saved
  /// the answer while it waited.
  @Test("Parked work takes a row saved while it waited rather than extracting")
  func parkedWorkReadsTheRowAgainAfterResuming() async throws {
    let fixture = ServiceFixture()
    fixture.service.setCovered(true)
    let home = Task { await fixture.service.request([fixture.request(.background, coverable: true)]) }
    await fixture.service.waitForSubscriberCount(fixture.identity, minimum: 1)

    try await fixture.records.upsert(fixture.row())
    fixture.service.setCovered(false)

    #expect(await home.value[fixture.identity] == ServiceFixture.palette)
    #expect(await fixture.extractions.value == 0)
    #expect(await fixture.records.upserted.count == 1)
  }

  @Test("A covered visible card answers from its row or stays neutral, starting no work")
  func aCoveredVisibleCardStartsNoWork() async {
    let fixture = ServiceFixture(warm: false)
    let saved = fixture.identity(itemID: "saved")
    await fixture.records.seed(fixture.row(for: saved))
    fixture.service.setCovered(true)

    let resolved = await fixture.service.request([
      fixture.request(for: saved, coverable: true), fixture.request(coverable: true),
    ])

    #expect(Set(resolved.keys) == [saved])
    #expect(await fixture.extractions.value == 0)
    #expect(fixture.bytes.arrivalWaits == 0)
  }

  // MARK: Callers leaving

  @Test("Coverable work ends when its last caller leaves")
  func coverableWorkEndsWithItsLastCaller() async {
    let fixture = ServiceFixture()
    fixture.service.setCovered(true)
    let home = Task { await fixture.service.request([fixture.request(.background, coverable: true)]) }
    await fixture.service.waitForSubscriberCount(fixture.identity, minimum: 1)

    home.cancel()
    _ = await home.value
    fixture.service.setCovered(false)
    await awaitQuiescence("ended") { "\(await fixture.extractions.value)" }

    #expect(await fixture.extractions.value == 0)
    #expect(await fixture.records.upserted.isEmpty)
  }

  /// The mini-player's task is cancelled when the expanded player covers it. Abandoning its
  /// derivation then would leave both players neutral.
  @Test("A visible surface's work outlives the caller that started it")
  func aVisibleSurfacesWorkOutlivesItsCaller() async {
    let arrival = ArrivalGate()
    let fixture = ServiceFixture(warm: false, arrival: arrival)
    let mini = Task { await fixture.service.request([fixture.request()]) }
    await arrival.waitUntilJoined()

    mini.cancel()
    await arrival.release()

    _ = await awaitCondition(
      "derived", until: { fixture.service.palette(for: fixture.identity) != nil })
    #expect(await fixture.records.upserted.count == 1)
  }

  @Test("A source change cancels the item's work under the old source")
  func aSourceChangeCancelsTheItemsWork() async {
    let arrival = ArrivalGate()
    let fixture = ServiceFixture(warm: false, arrival: arrival)
    let player = Task { await fixture.service.request([fixture.request()]) }
    await arrival.waitUntilJoined()

    fixture.service.sourceChanged(for: fixture.identity.itemID)
    await arrival.release()

    #expect(await player.value.isEmpty)
    #expect(await fixture.extractions.value == 0)
    #expect(await fixture.records.upserted.isEmpty)
  }

  // MARK: Clearing

  @Test("A clear drops every palette, stops following and discards work from before it")
  func aClearDropsEverythingAndDiscardsLateWork() async {
    let fixture = ServiceFixture(gated: true)
    let observer = RecordingObserver()
    fixture.service.addObserver(observer)
    let never = CoverPaletteService.CoverBytes(cached: { nil }, awaitArrival: {})
    _ = await fixture.service.request([
      CoverPaletteRequest(identity: fixture.identity(itemID: "unanswered"), bytes: never)
    ])
    _ = await awaitCondition("following", until: { await fixture.records.batchObserverCount == 1 })
    let player = Task { await fixture.service.request([fixture.request()]) }
    await fixture.gate!.waitUntilStarted()

    fixture.service.clear()
    await fixture.gate!.release()
    await fixture.gate!.waitUntilCompleted()
    _ = await player.value

    #expect(fixture.service.palette(for: fixture.identity) == nil)
    #expect(await fixture.records.upserted.isEmpty)
    #expect(observer.clears == 1)
    _ = await awaitCondition("stopped", until: { await fixture.records.batchObserverCount == 0 })
  }

  @Test("After a clear, a cover whose row is gone derives again")
  func aClearAllowsRederivation() async {
    let fixture = ServiceFixture()
    await fixture.records.seed(fixture.row())
    _ = await fixture.service.request([fixture.request()])

    fixture.service.clear()
    await fixture.records.removeAll()
    _ = await fixture.service.request([fixture.request()])

    #expect(await fixture.extractions.value == 1)
    #expect(fixture.service.palette(for: fixture.identity) != nil)
  }

  /// The artwork clear removes cover bytes, then rows, then memory. A derivation that read its
  /// bytes before the clear must not write a row after it, or the cleared cover keeps its colour.
  @Test("An artwork clear while a background save reads its cover leaves no row behind")
  func anArtworkClearDuringASaveWritesNothing() async {
    let records = FakeCoverPaletteRecordStoring()
    let bytes = SaveBytes(itemIDsOnDisk: ["item-1"], holdingReads: true)
    let service = Self.savingService(records: records, bytes: bytes)

    let save = Task { await service.save(Self.cardKey("item-1")) }
    await bytes.waitUntilReadStarted()
    await service.clearCachedArtwork()
    await bytes.releaseReads()
    await save.value

    #expect(await records.upserted.isEmpty)
    #expect(service.palette(for: CoverPaletteIdentity(Self.cardKey("item-1"))) == nil)
  }

  // MARK: Background writers

  /// The backfill offers every library item. Following each one it could not answer would observe
  /// the whole library, and keeping each answer would evict the palettes on screen.
  @Test("A background save writes the row, and neither follows nor fills memory")
  func aBackgroundSaveOnlyWritesTheRow() async {
    let records = FakeCoverPaletteRecordStoring()
    let service = Self.savingService(
      records: records, bytes: SaveBytes(itemIDsOnDisk: ["item-1"], holdingReads: false))

    await service.save(Self.cardKey("item-1"))
    await service.save(Self.cardKey("no-bytes"))
    await Task.yield()

    let row = await records.record(for: "item-1")
    #expect(CoverPaletteWriter.answers(row, for: CoverPaletteWriter.recordIdentity(for: Self.cardKey("item-1"))))
    #expect(service.palette(for: CoverPaletteIdentity(Self.cardKey("item-1"))) == nil)
    #expect(await records.batchObserverCount == 0)
    #expect(await service.unsaved([CoverPaletteIdentity(Self.cardKey("item-1"))]).isEmpty)
  }

  @Test("A background save answers a surface already following the cover")
  func aBackgroundSaveAnswersAFollowingSurface() async {
    let records = FakeCoverPaletteRecordStoring()
    let service = Self.savingService(
      records: records, bytes: SaveBytes(itemIDsOnDisk: ["item-1"], holdingReads: false))
    let identity = CoverPaletteIdentity(Self.cardKey("item-1"))
    let never = CoverPaletteService.CoverBytes(cached: { nil }, awaitArrival: {})
    _ = await service.request([CoverPaletteRequest(identity: identity, bytes: never)])

    await service.save(Self.cardKey("item-1"))

    #expect(service.palette(for: identity) != nil)
  }

  private static func cardKey(_ itemID: String) -> ArtworkKey {
    ArtworkKey(
      accountScope: ArtworkAccountScope("scope"), itemID: itemID,
      variant: .homeCard(pixelWidth: CoverPaletteSource.cardPixelWidth),
      revision: ArtworkRevision("revision-1"))
  }

  private static func savingService(
    records: FakeCoverPaletteRecordStoring, bytes: SaveBytes
  ) -> CoverPaletteService {
    CoverPaletteService(
      accountScope: ArtworkAccountScope("scope"),
      artwork: .init(reader: bytes, joiner: NoArrival()),
      extraction: ServiceFixture.fakeExtraction, recordStore: records)
  }

  // MARK: Memory bound

  @Test("The cache evicts the least recently used palette at its bound")
  func theCacheEvictsTheLeastRecentlyUsed() async {
    let fixture = ServiceFixture(cacheLimit: 2)
    let (a, b, c) = (
      fixture.identity(itemID: "a"), fixture.identity(itemID: "b"), fixture.identity(itemID: "c")
    )
    _ = await fixture.service.request([fixture.request(for: a)])
    _ = await fixture.service.request([fixture.request(for: b)])
    _ = fixture.service.palette(for: a)
    _ = await fixture.service.request([fixture.request(for: c)])

    #expect(fixture.service.palette(for: a) != nil)
    #expect(fixture.service.palette(for: b) == nil)
    #expect(fixture.service.palette(for: c) != nil)
  }

  @Test("The pinned palette survives the bound, and the pin moves with its identity")
  func thePinnedPaletteSurvivesTheBound() async {
    let fixture = ServiceFixture(cacheLimit: 2)
    let playing = fixture.identity(itemID: "playing")
    let replaced = fixture.identity(itemID: "playing", revision: "revision-2")
    _ = await fixture.service.request([fixture.request(for: playing)])
    fixture.service.pin(playing)
    _ = await fixture.service.request([fixture.request(for: replaced)])
    fixture.service.pin(replaced)

    for other in ["a", "b", "c"] {
      _ = await fixture.service.request([fixture.request(for: fixture.identity(itemID: other))])
    }

    #expect(fixture.service.palette(for: replaced) != nil)
    #expect(fixture.service.palette(for: playing) == nil)
  }

  // MARK: Row identity

  @Test("Two images of one show hold two rows, and returning to the first extracts nothing")
  func twoImagesOfOneItemHoldTwoRows() async {
    let fixture = ServiceFixture()
    let first = fixture.identity(scope: "image-a", rowID: "rss-art:1|a")
    let second = fixture.identity(scope: "image-b", rowID: "rss-art:1|b")

    _ = await fixture.service.request([fixture.request(for: first)])
    _ = await fixture.service.request([fixture.request(for: second)])
    _ = await fixture.service.request([fixture.request(for: first)])

    #expect(await fixture.extractions.value == 2)
    #expect(await fixture.records.storedIDs == ["rss-art:1|a", "rss-art:1|b"])
    #expect(await fixture.records.record(for: "rss-art:1|a")?.artworkKey == first.recordKey)
    #expect(await fixture.records.record(for: "rss-art:1|b")?.artworkKey == second.recordKey)
    #expect(await fixture.service.unsaved([first, second]).isEmpty)
  }

  @Test("Following an identity watches its own row, so a late row for its image answers it")
  func followingWatchesTheIdentitysRow() async throws {
    let fixture = ServiceFixture()
    let image = fixture.identity(scope: "image-b", rowID: "rss-art:1|b")
    let never = CoverPaletteService.CoverBytes(cached: { nil }, awaitArrival: {})
    _ = await fixture.service.request([CoverPaletteRequest(identity: image, bytes: never)])
    _ = await awaitCondition("following", until: { await fixture.records.batchObserverCount == 1 })

    try await fixture.records.upsert(fixture.row(for: image))

    _ = await awaitCondition("adopted", until: { fixture.service.palette(for: image) != nil })
    #expect(fixture.service.palette(for: image) == ServiceFixture.palette)
  }

  @Test("A provisional identity is answered from its own row, not another row of the item")
  func aProvisionalIdentityReadsItsOwnRow() async {
    let fixture = ServiceFixture()
    await fixture.records.seed(fixture.row())
    let provisional = fixture.identity(
      scope: "placeholder", revision: nil, rowID: "rss-art:1|b", isProvisional: true)

    let beforeItsRow = await fixture.service.request([fixture.request(for: provisional)])
    #expect(beforeItsRow.isEmpty)

    await fixture.records.seed(
      fixture.row(for: fixture.identity(scope: "image-b", rowID: "rss-art:1|b")))
    let afterItsRow = await fixture.service.request([fixture.request(for: provisional)])
    #expect(afterItsRow[provisional] == ServiceFixture.palette)
    #expect(await fixture.extractions.value == 0)
  }

  @Test("An identity with no row id of its own reads and writes the row named for its item")
  func theDefaultRowIDIsTheItemID() async {
    let fixture = ServiceFixture()
    #expect(fixture.identity.rowID == fixture.identity.itemID)

    _ = await fixture.service.request([fixture.request()])

    #expect(await fixture.records.storedIDs == [fixture.identity.itemID])
    #expect(await fixture.records.upserted.first?.itemId == fixture.identity.itemID)
  }

  @Test("Memory still follows the item while the row follows the image")
  func memoryFollowsTheItem() async {
    let fixture = ServiceFixture()
    let first = fixture.identity(scope: "image-a", rowID: "rss-art:1|a")
    let second = fixture.identity(scope: "image-b", rowID: "rss-art:1|b")
    fixture.service.pin(itemID: first.itemID)

    fixture.service.show(first)
    _ = await fixture.service.request([fixture.request(for: first)])
    fixture.service.show(second)
    _ = await fixture.service.request([fixture.request(for: second)])

    #expect(first.itemID == second.itemID)
    #expect(fixture.service.palette(forItem: first.itemID) == ServiceFixture.palette)
    #expect(fixture.service.palette(for: first) != nil)
    #expect(fixture.service.palette(for: second) != nil)
  }

  @Test("Drawing an episode's own image uses that image's row; the show's art keeps the item's")
  func drawingIdentityPicksTheRow() throws {
    let show = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:42", artworkURL: URL(string: "https://img.test/show.jpg")!))
    let episode = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:42", artworkURL: URL(string: "https://img.test/ep.jpg")!))
    func key(_ source: ArtworkSource) -> ArtworkKey {
      ArtworkKey(
        source: source, itemID: "rss:42/guid", variant: .homeCard(pixelWidth: 420),
        revision: .unversioned)
    }

    let drawingEpisode = CoverPaletteIdentity(
      drawing: key(.rss(episode)), showSource: .rss(show))
    #expect(drawingEpisode.rowID == CoverPaletteIdentity.episodeArtworkRowID(for: episode))
    #expect(drawingEpisode.itemID == "rss:42/guid")
    #expect(
      CoverPaletteIdentity(drawing: key(.rss(show)), showSource: .rss(show)).rowID == "rss:42/guid")
    let abs = ArtworkSource.audiobookshelf(ArtworkAccountScope("scope"))
    #expect(CoverPaletteIdentity(drawing: key(abs), showSource: nil).rowID == "rss:42/guid")
  }

  @Test("An episode image's row id names the feed number and the normalized URL")
  func episodeArtworkRowID() throws {
    let source = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:42", artworkURL: URL(string: "https://img.test/ep.jpg")!))

    #expect(
      CoverPaletteIdentity.episodeArtworkRowID(for: source)
        == "rss-art:42|\(source.normalizedArtworkURL)")
    let key = ArtworkKey(
      source: .rss(source), itemID: "rss:42/guid", variant: .homeCard(pixelWidth: 420),
      revision: .unversioned)
    let identity = CoverPaletteIdentity(
      key, rowID: CoverPaletteIdentity.episodeArtworkRowID(for: source))
    #expect(identity.itemID == "rss:42/guid")
    #expect(identity.rowID.hasPrefix("rss-art:42|"))
    #expect(CoverPaletteIdentity(key).rowID == "rss:42/guid")
  }

  // MARK: Identity

  @Test("A Home card with no source of its own files its cover under the account's identity")
  func aCardWithoutASourceUsesTheAccountScope() {
    let identity = ServiceFixture.defaultIdentity
    let service = CoverPaletteService(accountScope: identity.accountScope)
    #expect(
      service.cardIdentity(itemID: identity.itemID, revision: identity.revision, source: nil)
        == identity)
  }

  @Test("RSS and server identities for the same item are different rows")
  func rssAndServerIdentitiesDiffer() throws {
    let rss = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:1", artworkURL: URL(string: "https://img.test/show.jpg")!,
        feedURL: URL(string: "https://feed.test/show.xml")!))
    let rssKey = ArtworkKey(
      source: .rss(rss), itemID: "same", variant: .homeCard(pixelWidth: 420), revision: .unversioned)
    let serverKey = ArtworkKey(
      accountScope: ArtworkAccountScope("scope"), itemID: "same",
      variant: .homeCard(pixelWidth: 420), revision: .unversioned)

    #expect(CoverPaletteIdentity(rssKey).recordKey != CoverPaletteIdentity(serverKey).recordKey)
  }
}

// MARK: - Fixtures

@MainActor
private final class ServiceFixture {
  nonisolated static let samples = CoverPaletteSamples(
    average: CoverRGBA(red: 0.2, green: 0.3, blue: 0.4),
    dominant: [CoverRGBA(red: 0.9, green: 0.2, blue: 0.2)])
  static let palette = CoverAmbientPalette.palette(from: samples)
  nonisolated static let fakeExtraction = CoverPaletteService.Extraction(samples: { _ in samples })
  static let defaultIdentity = CoverPaletteIdentity(
    accountScope: ArtworkAccountScope("scope"), itemID: "item-1",
    revision: ArtworkRevision("revision-1"))

  let identity = ServiceFixture.defaultIdentity
  let records = FakeCoverPaletteRecordStoring()
  let extractions = EditorialWashTestCallCounter()
  let gate: EditorialWashTestExtractionGate?
  let bytes: TestCoverBytes
  let service: CoverPaletteService

  init(warm: Bool = true, gated: Bool = false, cacheLimit: Int = 256, arrival: ArrivalGate? = nil) {
    let gate = gated ? EditorialWashTestExtractionGate() : nil
    let counter = extractions
    self.gate = gate
    bytes = TestCoverBytes(isWarm: warm, arrival: arrival)
    service = CoverPaletteService(
      extraction: CoverPaletteService.Extraction(samples: { _ in
        await counter.increment()
        if let gate {
          await gate.enter()
          await gate.waitForRelease()
          await gate.markCompleted()
        }
        return Self.samples
      }),
      admission: CoverDecodeAdmission(maximumConcurrent: 1),
      recordStore: records, cacheLimit: cacheLimit)
  }

  /// `revision: nil` is `.unversioned`.
  func identity(
    itemID: String = "item-1", scope: String = "scope", revision: String? = "revision-1",
    rowID: String? = nil, isProvisional: Bool = false
  ) -> CoverPaletteIdentity {
    CoverPaletteIdentity(
      accountScope: ArtworkAccountScope(scope), itemID: itemID,
      revision: revision.map { ArtworkRevision($0) } ?? .unversioned, rowID: rowID,
      isProvisional: isProvisional)
  }

  func request(
    _ requestClass: CoverPaletteWriter.RequestClass = .visible, coverable: Bool = false
  ) -> CoverPaletteRequest {
    request(for: identity, requestClass, coverable: coverable)
  }

  func request(
    for identity: CoverPaletteIdentity,
    _ requestClass: CoverPaletteWriter.RequestClass = .visible, coverable: Bool = false
  ) -> CoverPaletteRequest {
    CoverPaletteRequest(
      identity: identity, bytes: bytes.source, requestClass: requestClass, isCoverable: coverable)
  }

  /// A row as extraction writes one: the accent plus the page evidence a warm read needs.
  func row(
    for identity: CoverPaletteIdentity? = nil, withoutAccent: Bool = false
  ) -> CoverPaletteRecord {
    let identity = identity ?? self.identity
    let accent = withoutAccent ? nil : Self.palette.rawAccentHSB
    let evidence = Self.palette.ambientAppearance.evidence
    return CoverPaletteRecord(
      itemId: identity.rowID, artworkKey: identity.recordKey,
      accentHue: accent?.hue, accentSaturation: accent?.saturation,
      accentBrightness: accent?.brightness, clusterWeight: evidence.clusterWeight,
      clusterRed: evidence.cluster?.red, clusterGreen: evidence.cluster?.green,
      clusterBlue: evidence.cluster?.blue, averageRed: evidence.average.red,
      averageGreen: evidence.average.green, averageBlue: evidence.average.blue,
      extractedAt: Date())
  }
}

/// Stands in for the cache-only cover client: `nil` until the fetched artwork lands, which
/// `awaitArrival` models. An `ArrivalGate` holds that arrival until a test releases it.
private nonisolated final class TestCoverBytes: @unchecked Sendable {
  private nonisolated struct State {
    var isWarm: Bool
    var cachedReads = 0
    var arrivalWaits = 0
  }

  private let state: Locked<State>
  private let arrival: ArrivalGate?

  init(isWarm: Bool, arrival: ArrivalGate?) {
    state = Locked(State(isWarm: isWarm))
    self.arrival = arrival
  }

  var cachedReads: Int { state.value.cachedReads }
  var arrivalWaits: Int { state.value.arrivalWaits }

  var source: CoverPaletteService.CoverBytes {
    CoverPaletteService.CoverBytes(
      cached: { [self] in
        state.withValue { state in
          state.cachedReads += 1
          return state.isWarm ? Data([0x01, 0x02, 0x03]) : nil
        }
      },
      awaitArrival: { [self] in
        state.withValue { $0.arrivalWaits += 1 }
        await arrival?.join()
        state.withValue { $0.isWarm = true }
      })
  }
}

/// Holds a display fetch open until released, whatever the joiner's cancellation state, as the
/// shared artwork operation does.
private actor ArrivalGate {
  private var joined = false
  private var released = false
  private var joinWaiter: CheckedContinuation<Void, Never>?
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func join() async {
    joined = true
    joinWaiter?.resume()
    joinWaiter = nil
    if released { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilJoined() async {
    if joined { return }
    await withCheckedContinuation { joinWaiter = $0 }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

@MainActor
private final class RecordingObserver: CoverPaletteServiceObserver {
  private(set) var answers: [[CoverPaletteIdentity: CoverPalette]] = []
  private(set) var clears = 0

  func paletteServiceDidAnswer(_ palettes: [CoverPaletteIdentity: CoverPalette]) {
    answers.append(palettes)
  }

  func paletteServiceDidClear() { clears += 1 }
}

private actor FailingRecordStore: CoverPaletteRecordStoring {
  struct Failure: Error {}

  func fetch(itemId: String) async throws -> CoverPaletteRecord? { nil }
  func fetch(itemIds: [String]) async throws -> [CoverPaletteRecord] { [] }
  func upsert(_ record: CoverPaletteRecord) async throws { throw Failure() }
  func removeAll() async throws { throw Failure() }
  nonisolated func observe(itemId: String) -> AsyncStream<CoverPaletteRecord?> {
    AsyncStream { $0.finish() }
  }
  nonisolated func observe(itemIds: [String]) -> AsyncStream<[CoverPaletteRecord]> {
    AsyncStream { $0.finish() }
  }
}

/// Cache-only cover bytes for a background save: present for the items on disk, optionally held at
/// the read until a test releases it.
private actor SaveBytes: CoverPaletteByteReading {
  private let itemIDsOnDisk: Set<String>
  private var holdingReads: Bool
  private var readStarted: CheckedContinuation<Void, Never>?
  private var hasStartedRead = false
  private var held: [CheckedContinuation<Void, Never>] = []

  init(itemIDsOnDisk: Set<String>, holdingReads: Bool) {
    self.itemIDsOnDisk = itemIDsOnDisk
    self.holdingReads = holdingReads
  }

  func data(for key: ArtworkKey) async -> Data? {
    guard itemIDsOnDisk.contains(key.itemID) else { return nil }
    hasStartedRead = true
    readStarted?.resume()
    readStarted = nil
    if holdingReads {
      await withCheckedContinuation { held.append($0) }
    }
    return Data([1])
  }

  func waitUntilReadStarted() async {
    guard hasStartedRead == false else { return }
    await withCheckedContinuation { readStarted = $0 }
  }

  func releaseReads() {
    holdingReads = false
    let waiting = held
    held.removeAll()
    for waiter in waiting { waiter.resume() }
  }
}

private struct NoArrival: CoverPaletteArtworkJoining {
  func awaitArrival(for key: ArtworkKey) async {}
}
