import Foundation
import Observation
import WatchPlayback
import WatchProtocol

private enum RegressionError: Error {
  case failed
}

private actor CatalogueHarness {
  struct Call: Sendable {
    let id: Int
    let libraryID: String
    let page: Int
  }

  private var nextID = 0
  private var calls: [Call] = []
  private var waiters: [Int: CheckedContinuation<WatchLibraryPage, Error>] = [:]

  func load(libraryID: String, page: Int, limit: Int) async throws -> WatchLibraryPage {
    nextID += 1
    let id = nextID
    calls.append(Call(id: id, libraryID: libraryID, page: page))
    return try await withCheckedThrowingContinuation { continuation in
      waiters[id] = continuation
    }
  }

  func callsSnapshot() -> [Call] { calls }

  func finish(_ id: Int, with page: WatchLibraryPage) {
    guard let waiter = waiters.removeValue(forKey: id) else { preconditionFailure("unknown call") }
    waiter.resume(returning: page)
  }

  func fail(_ id: Int) {
    guard let waiter = waiters.removeValue(forKey: id) else { preconditionFailure("unknown call") }
    waiter.resume(throwing: RegressionError.failed)
  }
}

@main
struct PaginationRegression {
  static func main() async {
    facadePublishesOnlyChangedProperties()
    await logoutClearsCataloguePaging()
    await doubleTapLoadsOneLibraryPage()
    await reloadDiscardsOldSameLibraryResult()
    await selectionRoundTripDiscardsOldResult()
    await staleFailureDoesNotChangeCurrentUI()
    print("watch pagination regressions passed")
  }

  @MainActor
  private static func makeModel(
    catalogue: CatalogueHarness? = nil
  ) -> WatchLibraryModel {
    WatchLibraryModel(
      companion: WatchCompanionStore(), protectedStore: hostProtectedStore(),
      catalogueLoader: catalogue.map { harness in
        { @Sendable libraryID, page, limit in try await harness.load(libraryID: libraryID, page: page, limit: limit) }
      })
  }

  private static func waitForCall(_ condition: @escaping @Sendable () async -> Bool) async {
    await hostAwait("the pagination request", until: condition)
  }

  private static func catalogueItem(_ id: String, libraryID: String) -> WatchLibraryItem {
    WatchLibraryItem(
      id: id, libraryID: libraryID, kind: .audiobook, title: id, author: nil,
      selection: .audiobookshelf(itemID: id, episodeID: nil), durationSeconds: nil, episodeCount: nil)
  }

  private static func page(
    _ item: WatchLibraryItem, libraryID: String, page: Int
  ) -> WatchLibraryPage {
    WatchLibraryPage(items: [item], total: page == 0 ? 80 : 1, limit: 40, page: page)
  }

  @MainActor
  private static func facadePublishesOnlyChangedProperties() {
    let model = makeModel()
    let items = ObservationProbe()
    let selection = ObservationProbe()
    let labels = ObservationProbe()
    let downloads = ObservationProbe()
    withObservationTracking {
      _ = model.items
    } onChange: {
      items.changed()
    }
    withObservationTracking {
      _ = model.currentSelection
    } onChange: {
      selection.changed()
    }
    withObservationTracking {
      _ = model.downloadLabels
    } onChange: {
      labels.changed()
    }
    withObservationTracking {
      _ = model.downloads
    } onChange: {
      downloads.changed()
    }
    let item = catalogueItem("observed", libraryID: "library")
    model.catalogue.items = [item]
    precondition(items.count == 1)
    precondition(selection.count == 0 && labels.count == 0 && downloads.count == 0)
    withObservationTracking {
      _ = model.items
    } onChange: {
      items.changed()
    }
    model.catalogue.hasMore = true
    model.catalogue.items = [item]
    precondition(items.count == 1, "unchanged catalogue projection notified observers")
    // The playback phase is the only writer of the selection; republishing it unchanged must not
    // notify. The playback regressions cover a change being published.
    model.publishPlayback()
    precondition(selection.count == 0, "unchanged playback projection notified observers")
    model.downloadsController.downloadLabels = ["id": "observed"]
    precondition(labels.count == 1 && downloads.count == 0)
    withObservationTracking {
      _ = model.downloadLabels
    } onChange: {
      labels.changed()
    }
    model.downloadsController.downloadLabels = ["id": "observed"]
    model.downloadsController.downloads = []
    precondition(labels.count == 1 && downloads.count == 0, "unchanged download projection notified observers")
    precondition(items.count == 1 && selection.count == 0)
  }

  @MainActor
  private static func logoutClearsCataloguePaging() async {
    let harness = CatalogueHarness()
    let model = makeModel(catalogue: harness)
    let load = Task { await model.selectLibrary("library") }
    await waitForCall { await harness.callsSnapshot().count == 1 }
    let call = await harness.callsSnapshot()[0]
    await harness.finish(
      call.id, with: page(catalogueItem("page-0", libraryID: "library"), libraryID: "library", page: 0))
    await load.value
    precondition(model.hasMore && !model.items.isEmpty)
    await model.logout()
    precondition(!model.hasMore && model.items.isEmpty, "logout retained catalogue paging state")
  }

  private static func doubleTapLoadsOneLibraryPage() async {
    let harness = CatalogueHarness()
    let model = await makeModel(catalogue: harness)
    let first = Task { await model.selectLibrary("library") }
    await waitForCall { await harness.callsSnapshot().count == 1 }
    let second = Task { await model.loadMore() }
    await Task.yield()
    let requestCount = await harness.callsSnapshot().count
    precondition(requestCount == 1, "double tap issued two page requests")
    let calls = await harness.callsSnapshot()
    let call = calls[0]
    await harness.finish(
      call.id, with: page(catalogueItem("page-0", libraryID: "library"), libraryID: "library", page: 0))
    await first.value
    await second.value
    let loadedIDs = await model.items.map(\.id)
    let loadedPages = (await harness.callsSnapshot()).map(\.page)
    precondition(loadedIDs == ["page-0"])
    precondition(loadedPages == [0])
    let next = Task { await model.loadMore() }
    await waitForCall { await harness.callsSnapshot().count == 2 }
    let nextCalls = await harness.callsSnapshot()
    let nextCall = nextCalls[1]
    precondition(nextCall.page == 1, "pagination skipped or repeated a page")
    await harness.finish(
      nextCall.id, with: page(catalogueItem("page-1", libraryID: "library"), libraryID: "library", page: 1))
    await next.value
  }

  private static func reloadDiscardsOldSameLibraryResult() async {
    let harness = CatalogueHarness()
    let model = await makeModel(catalogue: harness)
    let old = Task { await model.selectLibrary("library") }
    await waitForCall { await harness.callsSnapshot().count == 1 }
    let reload = Task { await model.selectLibrary("library") }
    await waitForCall { await harness.callsSnapshot().count == 2 }
    let calls = await harness.callsSnapshot()
    await harness.finish(
      calls[1].id, with: page(catalogueItem("fresh", libraryID: "library"), libraryID: "library", page: 0))
    await reload.value
    await harness.finish(
      calls[0].id, with: page(catalogueItem("old", libraryID: "library"), libraryID: "library", page: 0))
    await old.value
    let loadedIDs = await model.items.map(\.id)
    precondition(loadedIDs == ["fresh"])
  }

  private static func selectionRoundTripDiscardsOldResult() async {
    let harness = CatalogueHarness()
    let model = await makeModel(catalogue: harness)
    let firstA = Task { await model.selectLibrary("A") }
    await waitForCall { await harness.callsSnapshot().count == 1 }
    let b = Task { await model.selectLibrary("B") }
    await waitForCall { await harness.callsSnapshot().count == 2 }
    let secondA = Task { await model.selectLibrary("A") }
    await waitForCall { await harness.callsSnapshot().count == 3 }
    let calls = await harness.callsSnapshot()
    await harness.finish(calls[2].id, with: page(catalogueItem("new-A", libraryID: "A"), libraryID: "A", page: 0))
    await secondA.value
    await harness.finish(calls[0].id, with: page(catalogueItem("old-A", libraryID: "A"), libraryID: "A", page: 0))
    await harness.finish(calls[1].id, with: page(catalogueItem("old-B", libraryID: "B"), libraryID: "B", page: 0))
    await firstA.value
    await b.value
    let selectedLibrary = await model.selectedLibrary
    let loadedIDs = await model.items.map(\.id)
    precondition(selectedLibrary == "A")
    precondition(loadedIDs == ["new-A"])
  }

  private static func staleFailureDoesNotChangeCurrentUI() async {
    let harness = CatalogueHarness()
    let model = await makeModel(catalogue: harness)
    let old = Task { await model.selectLibrary("A") }
    await waitForCall { await harness.callsSnapshot().count == 1 }
    let current = Task { await model.selectLibrary("B") }
    await waitForCall { await harness.callsSnapshot().count == 2 }
    let calls = await harness.callsSnapshot()
    await harness.finish(calls[1].id, with: page(catalogueItem("current", libraryID: "B"), libraryID: "B", page: 0))
    await current.value
    await harness.fail(calls[0].id)
    await old.value
    let loadedIDs = await model.items.map(\.id)
    let message = await model.message
    precondition(loadedIDs == ["current"])
    precondition(message == nil, "stale failure changed the current UI")
  }
}

private final class ObservationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  var count: Int { lock.withLock { value } }
  func changed() { lock.withLock { value += 1 } }
}
