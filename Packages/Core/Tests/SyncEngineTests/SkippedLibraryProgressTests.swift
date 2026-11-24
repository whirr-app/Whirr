import ABSApi
import Foundation
import Testing

@testable import Persistence
@testable import SyncEngine

/// Item-keyed `/api/me` progress is applied inside the page walk, resolved against each page's
/// saved items, so a library the walk declines would have its progress fetched then discarded.
/// `applyProgressToExistingRows` resolves the same snapshot against rows that already exist.
/// Failure backoff is the only decline today, so these tests drive it.
@Suite struct SkippedLibraryProgressTests {

  @Test("a library gated by failure backoff still applies server progress to its existing rows")
  func backedOffLibraryStillAppliesServerProgress() async throws {
    let h = try await Harness(pageLimit: 2, randomUnit: 1.0)
    let libraryRowId = try #require(try await h.seedLibrary(serverLibraryId: "lib1").id)
    let seeded = try await h.seedItem(
      libraryRowId: libraryRowId, serverItemId: "seeded-item", generation: 1)
    let itemRowId = try #require(seeded.id)

    try await Self.driveIntoBackoff(h)
    let itemRequestsBeforeRetry = Self.itemListRequestCount(h)

    // Inside the backoff window: the library list and `/api/me` still happen, the page walk does
    // not.
    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueProgress([(libraryItemId: "seeded-item", currentTime: 321, isFinished: false)])

    await h.engine.refresh()

    #expect(Self.itemListRequestCount(h) == itemRequestsBeforeRetry, "the traversal stayed gated")
    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 321)
  }

  /// The skipped path must share the pull policy rather than reimplementing it: an unacknowledged
  /// local write is protected here exactly as it is on the page path.
  @Test func backedOffLibraryProgressRespectsUnacknowledgedLocalWrites() async throws {
    let h = try await Harness(pageLimit: 2, randomUnit: 1.0)
    let libraryRowId = try #require(try await h.seedLibrary(serverLibraryId: "lib1").id)
    let seeded = try await h.seedItem(
      libraryRowId: libraryRowId, serverItemId: "seeded-item", generation: 1)
    let itemRowId = try #require(seeded.id)
    try await h.seedUnacknowledgedLocalPosition(itemRowId: itemRowId, currentTime: 900)

    try await Self.driveIntoBackoff(h)

    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueProgress([(libraryItemId: "seeded-item", currentTime: 5, isFinished: false)])

    await h.engine.refresh()

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 900, "the unsent local position survives the pull")
  }

  /// A soft-deleted row is one pass-one deletion inference has already marked missing. Only a
  /// traversal may revive it, because only a traversal carries the evidence that it is back.
  @Test func softDeletedRowsAreNotRevivedByProgressAlone() async throws {
    let h = try await Harness(pageLimit: 2, randomUnit: 1.0)
    let libraryRowId = try #require(try await h.seedLibrary(serverLibraryId: "lib1").id)
    let seeded = try await h.softDeleteItem(
      try await h.seedItem(
        libraryRowId: libraryRowId, serverItemId: "tombstoned", generation: 1))
    let itemRowId = try #require(seeded.id)

    try await Self.driveIntoBackoff(h)

    h.clock.advance(by: BackoffPolicy.baseDelay - 0.001)
    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueProgress([(libraryItemId: "tombstoned", currentTime: 42, isFinished: false)])

    await h.engine.refresh()

    #expect(try h.fetchProgress(itemRowId: itemRowId) == nil)
    let row = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "tombstoned"))
    #expect(row.softDeleted == true)
  }

  /// The row ids reach this path from a snapshot taken before `/api/me` and before every traversed
  /// library's page walk, so a selection change can land in between. Committed selection is
  /// re-read at apply time; passing an excluded library's row id directly is the tightest way to
  /// prove it.
  @Test func excludedLibraryReceivesNoProgressEvenWhenItsRowIDIsPassedIn() async throws {
    let h = try await Harness(pageLimit: 2, randomUnit: 1.0)
    let libraryRowId = try #require(try await h.seedLibrary(serverLibraryId: "lib1").id)
    let seeded = try await h.seedItem(
      libraryRowId: libraryRowId, serverItemId: "seeded-item", generation: 1)
    let itemRowId = try #require(seeded.id)
    try await h.setLibraryIncluded(false, serverLibraryId: "lib1")

    await h.engine.applyProgressToExistingRows(
      accountId: h.accountId, libraryRowIds: [libraryRowId],
      progress: ProgressByIdentity(rows: [Self.progress(itemID: "seeded-item", currentTime: 77)]))

    #expect(try h.fetchProgress(itemRowId: itemRowId) == nil)
  }

  /// Partitioning the loop must not disturb the ordinary path, where progress still arrives with
  /// the page that saved the item.
  @Test func traversedLibraryStillAppliesProgressThroughThePageWalk() async throws {
    let h = try await Harness(pageLimit: 2, randomUnit: 1.0)
    let libraryRowId = try #require(try await h.seedLibrary(serverLibraryId: "lib1").id)

    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueProgress([(libraryItemId: "walked", currentTime: 250, isFinished: false)])
    h.enqueuePage(
      items: [(id: "walked", title: "Walked", author: nil)], total: 1, limit: 2, page: 0)

    await h.engine.refresh()

    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "walked"))
    let itemRowId = try #require(item.id)
    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 250)
  }

  /// One incomplete traversal, which schedules the library's failure backoff.
  private static func driveIntoBackoff(_ h: Harness) async throws {
    h.enqueueLibraries([(id: "lib1", name: "Seeded", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [(id: "a", title: "A", author: nil), (id: "b", title: "B", author: nil)], total: 6,
      limit: 2, page: 0)
    // The reported total moves and the run then ends short: `.incomplete`, never `.abort`.
    h.enqueuePage(items: [(id: "c", title: "C", author: nil)], total: 8, limit: 2, page: 1)
    await h.engine.refresh()
  }

  private static func itemListRequestCount(_ h: Harness) -> Int {
    h.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/items" }.count
  }

  private static func progress(itemID: String, currentTime: Double) -> MediaProgress {
    MediaProgress(
      libraryItemID: itemID, episodeID: nil, mediaItemID: nil, mediaItemType: nil, duration: nil,
      progress: nil, currentTime: currentTime, isFinished: false, hideFromContinueListening: false,
      ebookLocation: nil, ebookProgress: nil, lastUpdate: nil, startedAt: nil, finishedAt: nil)
  }
}
