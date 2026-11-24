import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// The App's read of the Audiobookshelf half of Send to Watch (ADR 0021).
@MainActor
@Suite("Watch Audiobookshelf copies model", .serialized)
struct ABSWatchCopiesModelTests {
  private typealias Fixture = ABSWatchSendFixture

  // MARK: - Rows

  @Test func phoneRowsComeFirstThenTheWatchsOwnDownloads() {
    let rows = ABSWatchCopiesModel.rows(
      copies: [Self.copy(Fixture.otherBook, .delivered, at: 20), Self.copy(Fixture.book, .wanted, at: 10)],
      groups: [Self.group(Fixture.episode, revision: nil, .ready)])

    #expect(rows.map(\.key) == [Fixture.otherBook, Fixture.book, Fixture.episode])
    #expect(rows.map(\.isPhoneOrigin) == [true, true, false])
    #expect(rows.last?.state == .delivered)
    #expect(rows.last?.title == "Watch title")
  }

  @Test func aStandingPhoneRowShadowsTheWatchsGroupForTheSameTitle() {
    let rows = ABSWatchCopiesModel.rows(
      copies: [Self.copy(Fixture.book, .sending, at: 10)],
      groups: [Self.group(Fixture.book, revision: nil, .ready)])

    #expect(rows.count == 1)
    #expect(rows.first?.isPhoneOrigin == true)
  }

  /// The listener removed a Watch-origin download here: it stays hidden until the Watch drops it.
  @Test func aRemovalAwaitingAcknowledgementShadowsTheGroup() {
    let removal = Self.copy(Fixture.book, .removed, at: 10, removalGeneration: 3)

    let rows = ABSWatchCopiesModel.rows(
      copies: [removal], groups: [Self.group(Fixture.book, revision: nil, .ready)])

    #expect(rows.map(\.isPhoneOrigin) == [true])
    #expect(rows.first?.state == .removed(.phone))
  }

  /// Downloaded again on the wrist after the phone's removal was acknowledged: shown again.
  @Test func aWatchDownloadAfterAnAcknowledgedRemovalIsShown() {
    let rows = ABSWatchCopiesModel.rows(
      copies: [Self.copy(Fixture.book, .removed, at: 10)],
      groups: [Self.group(Fixture.book, revision: nil, .downloading)])

    #expect(rows.map(\.isPhoneOrigin) == [true, false])
    #expect(rows.last?.state == .sending)
  }

  @Test func aRemovedWatchGroupIsNotListed() {
    let rows = ABSWatchCopiesModel.rows(
      copies: [], groups: [Self.group(Fixture.book, revision: nil, .removed)])

    #expect(rows.isEmpty)
  }

  @Test func aPhoneRowCarriesTheWatchsReportOnlyForItsOwnRevision() {
    let copy = Self.copy(Fixture.book, .sending, at: 10, revision: 2)

    let stale = ABSWatchCopiesModel.rows(
      copies: [copy], groups: [Self.group(Fixture.book, revision: 1, .failed)])
    let current = ABSWatchCopiesModel.rows(
      copies: [copy], groups: [Self.group(Fixture.book, revision: 2, .downloading)])

    #expect(stale.first?.group == nil)
    #expect(current.first?.group?.state == .downloading)
  }

  // MARK: - The menu's gate

  @Test func theMenuAnswersOnlyForAWatchThatCanTakeAnOffer() throws {
    let fixture = try Fixture()
    let model = ABSWatchCopiesModel()
    #expect(model.watchCopy(Fixture.book) == nil, "nothing is offered while unbound")
    model.bind(store: fixture.store, resolver: fixture.resolver) {}

    for (readiness, expected) in [
      (WatchABSReadiness.unknown, PodcastEpisodeWatchCopy.notOnWatch), (.ready, .notOnWatch),
      (.needsUpdate, nil), (.setUpWatch, nil), (.notInstalled, nil),
    ] as [(WatchABSReadiness, PodcastEpisodeWatchCopy?)] {
      model.applyReadiness(readiness)
      #expect(model.watchCopy(Fixture.book) == expected, "\(readiness)")
    }
    model.unbind()
  }

  /// An inventory stamped with another account means the Watch needs setting up for
  /// this one, whatever the last status report said.
  @Test func anInventoryForAnotherAccountHidesEveryRow() throws {
    let fixture = try Fixture()
    let model = ABSWatchCopiesModel()
    model.bind(store: fixture.store, resolver: fixture.resolver) {}
    model.applyReadiness(.ready)
    model.applyInventory(Self.snapshot([Self.group(Fixture.book, revision: nil, .ready)]))
    #expect(model.visibleRows.count == 1)

    model.applyInventoryMatch(.mismatch)

    #expect(model.effectiveReadiness == .setUpWatch)
    #expect(model.visibleRows.isEmpty)
    #expect(model.watchCopy(Fixture.book) == nil)
    model.unbind()
  }

  // MARK: - Actions

  @Test func sendRecordsARequestTitledFromTheLibrary() async throws {
    let fixture = try Fixture()
    fixture.books[Fixture.book.itemId] = .fixture(
      serverItemId: Fixture.book.itemId, title: "The Book", author: "An Author",
      audioDownloadExpectedBytes: 4_000)
    let model = ABSWatchCopiesModel()
    var refreshes = 0
    model.bind(store: fixture.store, resolver: fixture.resolver) { refreshes += 1 }

    await model.send(Fixture.book)

    let copy = try #require(try await fixture.store.copy(Fixture.book))
    #expect(copy.state == .wanted)
    #expect(copy.title == "The Book")
    #expect(copy.subtitle == "An Author")
    #expect(copy.declaredBytes == 4_000)
    #expect(refreshes == 1)
    model.unbind()
  }

  /// Remove works on a download the Watch started, through a removal the offer carries.
  @Test func removingAWatchOriginDownloadRecordsARemoval() async throws {
    let fixture = try Fixture()
    let model = ABSWatchCopiesModel()
    model.bind(store: fixture.store, resolver: fixture.resolver) {}
    model.applyInventory(Self.snapshot([Self.group(Fixture.book, revision: nil, .ready)]))

    await model.remove(Fixture.book)

    let copy = try #require(try await fixture.store.copy(Fixture.book))
    #expect(copy.state == .removed)
    #expect(copy.removalGeneration != nil)
    #expect(copy.title == "Watch title")
    model.unbind()
  }

  @Test func theWatchsOwnDownloadAnswersForItsTitle() throws {
    let fixture = try Fixture()
    let model = ABSWatchCopiesModel()
    model.bind(store: fixture.store, resolver: fixture.resolver) {}

    model.applyInventory(Self.snapshot([Self.group(Fixture.book, revision: nil, .ready)]))

    #expect(model.copyState(Fixture.book) == .delivered)
    #expect(model.watchCopy(Fixture.book) == .onWatch)
    model.unbind()
    #expect(model.copyState(Fixture.book) == nil)
  }

  // MARK: - Builders

  private static func copy(
    _ key: ABSWatchCopyKey, _ state: RSSWatchCopyState, at seconds: TimeInterval, revision: Int64 = 1,
    removalGeneration: Int64? = nil
  ) -> ABSWatchCopy {
    ABSWatchCopy(
      accountId: 1, key: key, title: "Title of \(key.itemId)", revision: revision, state: state,
      removedBy: state == .removed ? .phone : nil, removalGeneration: removalGeneration,
      requestedAt: Fixture.date(seconds), updatedAt: Fixture.date(seconds))
  }

  private static func group(
    _ key: ABSWatchCopyKey, revision: Int64?, _ state: ABSWatchGroup.State
  ) -> ABSWatchGroup {
    ABSWatchGroup(
      itemID: key.itemId, episodeID: key.episodeId, revision: revision, state: state, progress: nil,
      trackCount: 1, completedTracks: state == .ready ? 1 : 0, committedBytes: nil, declineReason: nil,
      failureReason: nil, title: "Watch title", subtitle: nil)
  }

  private static func snapshot(_ groups: [ABSWatchGroup]) -> ABSWatchInventoryRecord.Snapshot {
    ABSWatchInventoryRecord.Snapshot(
      watchInstallID: Fixture.install, accountIdentityHash: "account", groups: groups)
  }
}
