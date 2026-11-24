import ABSApi
import Foundation
import Testing

@testable import Persistence
@testable import SyncEngine

/// Another device's reset deletes the server row this device last observed. These journeys drive
/// the real item pull and check that loss of that row identity applies the reset, while a zero
/// written to the same row still raises a conflict (ADR 0011).
@Suite struct CrossDeviceResetJourneyTests {
  /// When this device's pull last applied row X.
  static let observedAt = Date(timeIntervalSince1970: 1_699_500_000)
  static let rowXStartedAt = Date(timeIntervalSince1970: 1_699_000_000)
  /// A row created after the observation above: the shape of another device's reset and restore.
  static let recreatedAt = Date(timeIntervalSince1970: 1_699_600_000)
  static let recreatedUpdatedAt = Date(timeIntervalSince1970: 1_699_600_100)

  // MARK: - Evidence applies the reset

  @Test(
    "an absent row this device observed resets it, whatever any clock says",
    arguments: [0.0, 7_200, -7_200])
  func absentObservedRowAppliesTheReset(clockSkew: TimeInterval) async throws {
    let h = try await Harness(
      pageLimit: 2, clockStart: Date(timeIntervalSince1970: 1_700_000_000 + clockSkew))
    let itemRowId = try await Self.seedObserved(h)

    await Self.refresh(h, progress: [])

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 0)
    #expect(progress.isFinished == false)
    #expect(progress.serverProgressId == nil)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  @Test func recreatedRowAppliesTheReset() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-y", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.recreatedAt)
      ])

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 0)
    #expect(progress.serverProgressId == "row-y")
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  /// An acknowledged ebook or finish write stamps `serverUpdatedAt` from this device's clock. The
  /// recreated-row comparison must still use the observed row's own server `lastUpdate`.
  @Test func aDeviceClockStampOnTheRowDoesNotHideARecreatedRow() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)
    try await h.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE mediaProgress SET serverUpdatedAt = ? WHERE itemId = ?",
        arguments: [Date(timeIntervalSince1970: 1_800_000_000), itemRowId])
    }

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-y", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.recreatedAt)
      ])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 0)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  // MARK: - No evidence still conflicts

  @Test func zeroOnTheSameRowRaisesAConflict() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-x", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.rowXStartedAt)
      ])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)
    #expect(try h.fetchConflict(itemRowId: itemRowId) != nil)
  }

  /// A `lastUpdate` override cannot manufacture evidence: the row id is unchanged.
  @Test(
    "a zero on the same row never resets, whatever its lastUpdate",
    arguments: [
      Date(timeIntervalSince1970: 1_600_000_000), Date(timeIntervalSince1970: 1_800_000_000),
    ])
  func zeroOnTheSameRowNeverResets(lastUpdate: Date) async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)

    await Self.refresh(
      h,
      progress: [
        Self.row(id: "row-x", currentTime: 0, lastUpdate: lastUpdate, startedAt: Self.rowXStartedAt)
      ])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)
  }

  @Test func incompleteSnapshotInfersNothingFromAbsence() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)

    await Self.refresh(h, progress: ["not a progress row"])

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 1_200)
    #expect(progress.serverProgressId == "row-x")
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  @Test func failedAndBackedOffFetchesInferNothingFromAbsence() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)

    h.enqueueLibraries([(id: "lib1", name: "Books", mediaType: "book")])
    h.enqueueTransportFailure()
    h.enqueuePage(items: [(id: "item-1", title: "Book", author: nil)], total: 1, limit: 2, page: 0)
    await h.engine.refresh()
    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)

    // Inside the progress backoff window `/api/me` is not requested at all.
    h.enqueueLibraries([(id: "lib1", name: "Books", mediaType: "book")])
    h.enqueuePage(items: [(id: "item-1", title: "Book", author: nil)], total: 1, limit: 2, page: 0)
    await h.engine.refresh()

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  @Test func absenceWithoutAnObservedRowKeepsLocal() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h, serverProgressId: nil)

    await Self.refresh(h, progress: [])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  /// The server can return duplicate rows. The observed row is still present, so the newer zero
  /// that wins the tie-break is an ordinary suspicious zero.
  @Test func observedRowAmongDuplicatesIsNotEvidence() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-x", currentTime: 1_200, lastUpdate: Self.observedAt, startedAt: Self.rowXStartedAt),
        Self.row(
          id: "row-z", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.recreatedAt),
      ])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)
    #expect(try h.fetchConflict(itemRowId: itemRowId) != nil)
  }

  /// A forward-dated observation cannot be beaten by a row created before it, so a genuinely
  /// recreated row that fails the time condition fails safe.
  @Test func recreatedRowOlderThanTheObservationIsNotEvidence() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(
      h, serverUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000))

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-y", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.recreatedAt)
      ])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)
  }

  /// `/api/me` is account-wide, but an excluded library's rows are outside the catalogue and
  /// receive nothing from it, including a reset.
  @Test func absenceNeverResetsARowInAnExcludedLibrary() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)
    let other = try #require(try await h.seedLibrary(serverLibraryId: "lib2").id)
    try await h.seedItem(libraryRowId: other, serverItemId: "item-2", generation: 1)
    try await h.setLibraryIncluded(false, serverLibraryId: "lib1")

    h.enqueueLibraries([
      (id: "lib1", name: "Books", mediaType: "book"), (id: "lib2", name: "More", mediaType: "book"),
    ])
    h.enqueueRawProgress([])
    h.enqueuePage(items: [(id: "item-2", title: "Other", author: nil)], total: 1, limit: 2, page: 0)
    await h.engine.refresh()

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_200)
  }

  // MARK: - Unsent local work outranks evidence

  @Test func unsentLocalProgressOutranksAReset() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h)
    try await ItemProgressIntentStore(database: h.database).setProgressAsync(
      itemID: "item-1", currentTime: 1_300, isFinished: false, originKey: "this-device")

    await Self.refresh(h, progress: [])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 1_300)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  // MARK: - Ebook

  @Test func ebookResetOfAnAbsentRowZeroesTheEbook() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h, currentTime: 0, ebookProgress: 0.4)

    await Self.refresh(h, progress: [])

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.ebookProgress == 0)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  /// An audio reset on a mixed-format item recreates the row with the server's ebook position.
  @Test func audioResetKeepsTheRestoredEbookPosition() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h, ebookProgress: 0.3)

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-y", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.recreatedAt, ebookProgress: 0.4)
      ])

    let progress = try #require(try h.fetchProgress(itemRowId: itemRowId))
    #expect(progress.currentTime == 0)
    #expect(progress.ebookProgress == 0.4)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  @Test func ebookZeroOnTheSameRowRaisesAConflictCarryingTheServerValue() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h, currentTime: 0, ebookProgress: 0.4)

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-x", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.rowXStartedAt, ebookProgress: 0, ebookLocation: "epubcfi(/6/2!/4/2/1:0)")
      ])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.ebookProgress == 0.4)
    let conflict = try #require(try h.fetchConflict(itemRowId: itemRowId))
    #expect(conflict.serverEbookProgress == 0)
    #expect(conflict.serverEbookLocation == "epubcfi(/6/2!/4/2/1:0)")
  }

  // MARK: - Conflicts left by earlier resets

  @Test func aConflictWhoseServerRowHasMovedOnIsSweptByTheFirstPull() async throws {
    let h = try await Harness(pageLimit: 2)
    let itemRowId = try await Self.seedObserved(h, serverProgressId: nil)
    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-x", currentTime: 0, lastUpdate: Self.recreatedUpdatedAt,
          startedAt: Self.rowXStartedAt)
      ])
    #expect(try h.fetchConflict(itemRowId: itemRowId) != nil)

    await Self.refresh(
      h,
      progress: [
        Self.row(
          id: "row-x", currentTime: 900,
          lastUpdate: Self.recreatedUpdatedAt.addingTimeInterval(60),
          startedAt: Self.rowXStartedAt)
      ])

    #expect(try h.fetchProgress(itemRowId: itemRowId)?.currentTime == 900)
    #expect(try h.fetchConflict(itemRowId: itemRowId) == nil)
  }

  // MARK: - Fixtures

  @discardableResult
  private static func seedObserved(
    _ h: Harness,
    currentTime: Double = 1_200,
    ebookProgress: Double? = nil,
    serverUpdatedAt: Date = observedAt,
    serverProgressId: String? = "row-x"
  ) async throws -> Int64 {
    let libraryRowId = try #require(try await h.seedLibrary(serverLibraryId: "lib1").id)
    let item = try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "item-1", generation: 1)
    let itemRowId = try #require(item.id)
    try await h.seedObservedProgress(
      itemRowId: itemRowId, currentTime: currentTime, ebookProgress: ebookProgress,
      serverUpdatedAt: serverUpdatedAt, serverProgressId: serverProgressId)
    return itemRowId
  }

  private static func refresh(_ h: Harness, progress: [Any]) async {
    h.enqueueLibraries([(id: "lib1", name: "Books", mediaType: "book")])
    h.enqueueRawProgress(progress)
    h.enqueuePage(items: [(id: "item-1", title: "Book", author: nil)], total: 1, limit: 2, page: 0)
    await h.engine.refresh()
  }

  private static func row(
    id: String, currentTime: Double, lastUpdate: Date, startedAt: Date,
    ebookProgress: Double? = nil, ebookLocation: String? = nil
  ) -> [String: Any] {
    var row: [String: Any] = [
      "id": id,
      "libraryItemId": "item-1",
      "currentTime": currentTime,
      "isFinished": false,
      "lastUpdate": Int64(lastUpdate.timeIntervalSince1970 * 1_000),
      "startedAt": Int64(startedAt.timeIntervalSince1970 * 1_000),
    ]
    if let ebookProgress { row["ebookProgress"] = ebookProgress }
    if let ebookLocation { row["ebookLocation"] = ebookLocation }
    return row
  }
}
