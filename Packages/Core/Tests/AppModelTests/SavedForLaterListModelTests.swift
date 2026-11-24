import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1))) struct SavedForLaterListModelTests {
  @MainActor
  @Test("a missing saved source is empty without opening an observation")
  func nilSourceIsImmediatelyEmpty() {
    let model = SavedForLaterListModel(savedShelf: nil, filter: .all)

    #expect(model.state == .empty)
    #expect(model.entries.isEmpty)
  }

  @MainActor
  @Test("saved emissions publish entries and loaded or empty state")
  func emissionsPublishEntriesAndState() async {
    let reading = FakeSavedShelfReading()
    let model = SavedForLaterListModel(savedShelf: reading, filter: .all)
    await waitUntil { reading.savedCalls.isEmpty == false }

    let entry = Self.entry(id: "book-1")
    reading.pushSaved([entry])
    await waitUntil { model.entries == [entry] }

    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("an empty emission after content leaves the destination empty")
  func finalRemovalPublishesEmptyState() async {
    let reading = FakeSavedShelfReading()
    let model = SavedForLaterListModel(savedShelf: reading, filter: .all)
    await waitUntil { reading.savedCalls.isEmpty == false }

    reading.pushSaved([Self.entry(id: "book-1")])
    await waitUntil { model.state == .loaded }

    reading.pushSaved([])
    await waitUntil { model.state == .empty }

    #expect(model.entries.isEmpty)
  }

  @MainActor
  @Test("the selected category and an unbounded limit reach persistence")
  func forwardsFilterAndUnboundedLimit() async {
    let reading = FakeSavedShelfReading()
    _ = SavedForLaterListModel(savedShelf: reading, filter: .podcasts)

    await waitUntil { reading.savedCalls.isEmpty == false }

    #expect(reading.savedCalls == [.init(filter: .podcast, limit: nil)])
  }

  @MainActor
  @Test("changing the filter re-subscribes with the new category")
  func filterChangeResubscribes() async {
    let reading = FakeSavedShelfReading()
    let model = SavedForLaterListModel(savedShelf: reading, filter: .all)
    await waitUntil { reading.savedCalls.count == 1 }

    model.filter = .podcasts
    await waitUntil { reading.savedCalls.count == 2 }

    #expect(
      reading.savedCalls == [.init(filter: nil, limit: nil), .init(filter: .podcast, limit: nil)])
  }

  @MainActor
  @Test("re-selecting the current filter does not re-subscribe")
  func repeatedFilterSelectionIsIgnored() async {
    let reading = FakeSavedShelfReading()
    let model = SavedForLaterListModel(savedShelf: reading, filter: .all)
    await waitUntil { reading.savedCalls.count == 1 }

    model.filter = .all
    model.filter = .all

    #expect(reading.savedCalls.count == 1)
  }

  /// The regression this guards: tearing the entries down at the moment of the tap would flash the
  /// "Nothing Saved Yet" placeholder over a shelf that is about to be repopulated.
  @MainActor
  @Test("the previous filter's entries survive until the new stream first emits")
  func filterChangeKeepsEntriesUntilFirstEmission() async {
    let reading = FakeSavedShelfReading()
    let model = SavedForLaterListModel(savedShelf: reading, filter: .all)
    await waitUntil { reading.savedCalls.count == 1 }

    let book = Self.entry(id: "book-1")
    reading.pushSaved([book])
    await waitUntil { model.entries == [book] }

    model.filter = .podcasts
    await waitUntil { reading.savedCalls.count == 2 }

    #expect(model.entries == [book])
    #expect(model.state == .loaded)

    let episode = Self.entry(id: "episode-1")
    reading.pushSaved([episode])
    await waitUntil { model.entries == [episode] }

    #expect(model.state == .loaded)
  }

  @MainActor
  @Test("an emission from the retired filter's stream is ignored")
  func staleSubscriptionEmissionsAreDropped() async {
    let reading = FakeSavedShelfReading()
    let model = SavedForLaterListModel(savedShelf: reading, filter: .all)
    await waitUntil { reading.savedCalls.count == 1 }

    model.filter = .podcasts
    await waitUntil { reading.savedCalls.count == 2 }

    let episode = Self.entry(id: "episode-1")
    reading.pushSaved([episode], at: 1)
    await waitUntil { model.entries == [episode] }

    reading.pushSaved([Self.entry(id: "stale-book")], at: 0)
    await Task.yield()
    await Task.yield()

    #expect(model.entries == [episode])
  }

  /// A source-less composition has no observation to swap, so the filter is inert rather than a
  /// route back into `loading`.
  @MainActor
  @Test("a missing saved source stays empty across a filter change")
  func nilSourceStaysEmptyAcrossFilterChange() async {
    let model = SavedForLaterListModel(savedShelf: nil, filter: .all)

    model.filter = .ebooks

    #expect(model.state == .empty)
    #expect(model.entries.isEmpty)
    #expect(model.filter == .ebooks)
  }

  private static func entry(id: String) -> SavedShelfItem {
    SavedShelfItem(
      identity: .item(itemID: id), savedAt: Date(timeIntervalSince1970: 1_800_000_000),
      subjectTitle: id, contextTitle: nil, category: .audiobook,
      itemSummary: ItemSummary(
        serverItemId: id, mediaKind: "book", title: id, author: nil, durationSeconds: nil,
        category: .audiobook),
      episode: nil, isUnavailable: false)
  }
}
