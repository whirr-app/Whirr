import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// The row lifecycle of a locally played title: a row is open only while audio plays, so a pause
/// leaves nothing that blocks upload.
struct WatchLocalProgressLifecycleTests {
  @Test func pauseClosesTheRowAndRequestsUpload() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    try await lifecycle.record(position: 14, listened: 4)
    #expect(try await lifecycle.pause(at: 15, listened: 1) == .upload)
    #expect(await lifecycle.openRowID == nil)
    let rows = await store.allSessions()
    #expect(rows.count == 1)
    #expect(rows.first?.currentPosition == 15)
    #expect(rows.first?.timeListening == 5)
  }

  @Test func resumeAfterPauseOpensANewRowFromTheCurrentPosition() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    _ = try await lifecycle.pause(at: 20, listened: 10)
    let first = await store.allSessions().map(\.id)
    try await lifecycle.play(at: 20)
    let opened = try #require(await lifecycle.openRowID)
    #expect(!first.contains(opened))
    #expect(await store.session(id: opened)?.startPosition == 20)
  }

  @Test func playWhileARowIsOpenKeepsThatRow() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    try await lifecycle.play(at: 12)
    #expect(await store.allSessions().count == 1)
  }

  @Test func aStartPastTheDurationClampsToTheDuration() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 250)
    let opened = try #require(await lifecycle.openRowID)
    #expect(await store.session(id: opened)?.startPosition == 100)
  }

  @Test func pauseWithoutListeningDiscardsTheEmptyRow() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    #expect(try await lifecycle.pause(at: 10, listened: 0) == .none)
    #expect(await store.allSessions().isEmpty)
  }

  @Test func secondPauseDoesNothing() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    _ = try await lifecycle.pause(at: 20, listened: 10)
    #expect(try await lifecycle.pause(at: 20, listened: 0) == .none)
    #expect(await store.allSessions().count == 1)
  }

  @Test func ticksWithoutAnOpenRowAreIgnored() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.record(position: 30, listened: 2)
    #expect(await store.allSessions().isEmpty)
  }

  @Test func seekWhilePausedIsRecordedAsAListenAndUploaded() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try await lifecycle.seek(to: 50) == .upload)
    #expect(await lifecycle.openRowID == nil)
    let row = try #require(await store.allSessions().first)
    #expect(row.currentPosition == 50)
    #expect(row.lastListenedAt != nil)
    // The row has no listening time; the seek alone makes it worth uploading.
    let batch = try await store.pendingUploadBatch()
    #expect(batch.map(\.id) == [row.id.uuidString.lowercased()])
    #expect(batch.first?.currentTime == 50)
  }

  @Test func seekWhilePlayingUpdatesTheOpenRow() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    #expect(try await lifecycle.seek(to: 50) == .none)
    let row = try #require(await store.allSessions().first)
    #expect(row.id == (await lifecycle.openRowID))
    #expect(row.currentPosition == 50)
    #expect(row.lastListenedAt != nil)
  }

  @Test func finishWhilePausedStillMarksTheTitleFinished() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try await lifecycle.stop(at: 100, listened: 0, finished: true) == .upload)
    #expect(await store.allSessions().first?.isFinished == true)
  }

  /// A skip onto the end finishes the title from before the end. The upload carries only a
  /// position, so the finished row must say the end.
  @Test func aFinishIsRecordedAtTheEndOfTheTitle() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 40)
    #expect(try await lifecycle.stop(at: 70, listened: 30, finished: true) == .upload)
    let row = try #require(await store.allSessions().first)
    #expect(row.isFinished)
    #expect(row.currentPosition == 100)
  }

  @Test func stopClosesTheOpenRow() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    #expect(try await lifecycle.stop(at: 30, listened: 20, finished: false) == .upload)
    #expect(await lifecycle.openRowID == nil)
    #expect(await store.allSessions().first?.currentPosition == 30)
  }

  /// A long listen splits its row so the server sees progress during it. The reopened row
  /// starts where the closed one ended and records that position as the last shared one, not the
  /// position observed when the title was loaded.
  @Test func aCheckpointClosesTheRowAndReopensAtItsPosition() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    let first = try #require(await lifecycle.openRowID)
    #expect(try await lifecycle.checkpoint(at: 70, listened: 60) == .upload)
    let reopened = try #require(await lifecycle.openRowID)
    #expect(reopened != first)
    #expect(await store.session(id: first)?.currentPosition == 70)
    #expect(await store.session(id: first)?.timeListening == 60)
    let row = try #require(await store.session(id: reopened))
    #expect(row.startPosition == 70)
    #expect(row.lastKnownSharedPosition == 70)
  }

  @Test func aCheckpointWhilePausedDoesNothing() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try await lifecycle.checkpoint(at: 70, listened: 0) == .none)
    #expect(await lifecycle.openRowID == nil)
    #expect(await store.allSessions().isEmpty)
  }

  /// Audio longer than its manifest (an injected advert, D42) keeps recording past the
  /// declared end once the engine reports the grown duration, and later rows carry it.
  @Test func aGrownDurationReachesTheOpenRowAndLaterOnes() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 90)
    let first = try #require(await lifecycle.openRowID)
    try await lifecycle.grow(to: 130)
    try await lifecycle.record(position: 120, listened: 30)
    #expect(await store.session(id: first)?.currentPosition == 120)
    #expect(await store.session(id: first)?.duration == 130)
    #expect(try await lifecycle.pause(at: 121, listened: 1) == .upload)
    try await lifecycle.play(at: 125)
    let second = try #require(await lifecycle.openRowID)
    #expect(await store.session(id: second)?.duration == 130)
    #expect(await store.session(id: second)?.startPosition == 125)
  }

  /// A shorter report never shrinks what was already seen.
  @Test func aDurationNeverShrinks() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    try await lifecycle.grow(to: 80)
    #expect(await store.allSessions().first?.duration == 100)
  }

  /// A tick the store refuses must not drop its listening: it joins the next write.
  @Test func aRejectedTickKeepsItsListeningForTheNextWrite() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await lifecycle.play(at: 10)
    await #expect(throws: WatchOfflineProgressStoreError.invalidPosition) {
      try await lifecycle.record(position: 500, listened: 3)
    }
    try await lifecycle.record(position: 20, listened: 2)
    #expect(await store.allSessions().first?.timeListening == 5)
  }

  @Test func aTickThatCannotBePersistedKeepsItsListeningWithoutCountingItTwice() async throws {
    let (store, lifecycle, root) = try await fixture()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
      try? FileManager.default.removeItem(at: root)
    }
    try await lifecycle.play(at: 10)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    await #expect(throws: WatchOfflineProgressStoreError.storageFailure) {
      try await lifecycle.record(position: 20, listened: 3)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    #expect(await store.allSessions().first?.timeListening == 0)
    #expect(try await lifecycle.pause(at: 25, listened: 2) == .upload)
    #expect(await store.allSessions().first?.timeListening == 5)
  }

  private func fixture() async throws -> (WatchOfflineProgressStore, WatchLocalProgressLifecycle, URL) {
    let root = try temporaryDirectory()
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
    let lifecycle = WatchLocalProgressLifecycle(
      store: store, selection: .audiobookshelf(itemID: "book", episodeID: nil), duration: 100,
      sharedPosition: 5, sharedObservedAt: Date(timeIntervalSince1970: 1))
    return (store, lifecycle, root)
  }
}
