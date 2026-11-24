import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// A card whose own resolution found nothing follows the saved row, so a colour that another
/// surface writes later (the player, item detail, the backfill) reaches it without a new request.
/// A card already coloured is never recoloured.
@Suite("Editorial wash following", .timeLimit(.minutes(1)))
@MainActor
struct EditorialWashFollowingTests {
  @Test("A card left neutral takes a row another surface saves later, then stops following")
  func aNeutralCardTakesALaterRow() async throws {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)
    let subject = EditorialWashSubject.audiobookshelf(fixtures.itemID, revision: .unversioned)

    provider.request([subject])
    _ = await awaitCondition("following", until: { await fixtures.records.observerCount == 1 })
    #expect(provider.wash(for: subject) == .drainedNeutral)

    try await fixtures.records.upsert(fixtures.warmRecord(for: fixtures.itemID))

    _ = await awaitCondition("adopted", until: { provider.washes[fixtures.itemID] != nil })
    #expect(provider.washes[fixtures.itemID] == fixtures.warmWash)
    _ = await awaitCondition("stopped", until: { await fixtures.records.observerCount == 0 })
  }

  @Test("A row for other artwork or without page evidence leaves the card neutral")
  func aRowThatDoesNotAnswerLeavesTheCardNeutral() async throws {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)
    let subject = EditorialWashSubject.audiobookshelf(fixtures.itemID, revision: .unversioned)

    provider.request([subject])
    _ = await awaitCondition("following", until: { await fixtures.records.observerCount == 1 })
    try await fixtures.records.upsert(
      CoverPaletteRecord(
        itemId: fixtures.itemID, artworkKey: fixtures.canonicalKey, accentHue: 0.1,
        accentSaturation: 0.5, accentBrightness: 0.5, extractedAt: Date()))
    var other = fixtures.warmRecord(for: fixtures.itemID)
    other.artworkKey = fixtures.canonicalKey(for: ArtworkRevision("other"))
    try await fixtures.records.upsert(other)
    try await fixtures.records.upsert(fixtures.warmRecord(for: "another-item"))
    await Self.settle(provider, fixtures)

    #expect(provider.washes[fixtures.itemID] == nil)
    #expect(await fixtures.records.observerCount == 1)
  }

  @Test("A card already coloured keeps its colour when a later row lands")
  func aColouredCardIsNotRecoloured() async throws {
    let fixtures = EditorialWashTestFixtures()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)
    let subject = EditorialWashSubject.audiobookshelf(fixtures.itemID, revision: .unversioned)

    provider.request([subject])
    _ = await awaitCondition("resolved", until: { provider.washes[fixtures.itemID] != nil })
    let resolved = provider.washes[fixtures.itemID]
    #expect(resolved != fixtures.warmWash)

    try await fixtures.records.upsert(fixtures.warmRecord(for: fixtures.itemID))
    await Self.settle(provider, fixtures)

    #expect(provider.washes[fixtures.itemID] == resolved)
    #expect(await fixtures.records.observerCount == 0)
  }

  @Test("Clearing the artwork stops following what the clear discarded")
  func clearingStopsFollowing() async throws {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let service = fixtures.service()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)

    provider.request([.audiobookshelf(fixtures.itemID, revision: .unversioned)])
    _ = await awaitCondition("following", until: { await fixtures.records.observerCount == 1 })
    service.clear()

    // The provider asks again after a clear, and the repeat miss follows afresh: one observer,
    // not the old one plus a new one.
    await awaitQuiescence("refollowed") { "\(await fixtures.records.observerCount)" }
    #expect(await fixtures.records.observerCount == 1)
  }

  @Test("A covered shell publishes a late row only once it is uncovered")
  func aCoveredShellWaitsToPublish() async throws {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let service = fixtures.service()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)

    provider.request([.audiobookshelf(fixtures.itemID, revision: .unversioned)])
    _ = await awaitCondition("following", until: { await fixtures.records.observerCount == 1 })
    service.setCovered(true)
    try await fixtures.records.upsert(fixtures.warmRecord(for: fixtures.itemID))
    await Self.settle(provider, fixtures)
    #expect(provider.washes[fixtures.itemID] == nil)

    service.setCovered(false)
    _ = await awaitCondition("adopted", until: { provider.washes[fixtures.itemID] != nil })
    #expect(provider.washes[fixtures.itemID] == fixtures.warmWash)
  }

  /// Waits until neither the card's wash nor its following changes, so an assertion that nothing
  /// was adopted runs after a late row has had every chance to land.
  private static func settle(
    _ provider: HomeWashProvider, _ fixtures: EditorialWashTestFixtures
  ) async {
    await awaitQuiescence("settled") {
      let observers = await fixtures.records.observerCount
      return "\(String(describing: provider.washes[fixtures.itemID]))|\(observers)"
    }
  }
}
