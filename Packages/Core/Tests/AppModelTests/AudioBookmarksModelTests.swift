import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The model mirrors the observed list and turns intent outcomes into renderable state.
@MainActor
@Suite struct AudioBookmarksModelTests {
  private static let item = "item_book"

  @Test func theListFollowsTheObservation() async {
    let intents = FakeAudioBookmarkIntents()
    let model = AudioBookmarksModel(itemID: Self.item, intents: intents)
    let bookmarks = [
      AudioBookmark(serverItemID: Self.item, time: 5, title: "Five", createdAt: nil),
      AudioBookmark(serverItemID: Self.item, time: 9.25, title: "Elsewhere", createdAt: nil),
    ]

    intents.emit(bookmarks)
    _ = await awaitCondition("the model shows the emitted list") { model.bookmarks == bookmarks }
  }

  @Test func addingMapsEachOutcome() async {
    let intents = FakeAudioBookmarkIntents()
    let model = AudioBookmarksModel(itemID: Self.item, intents: intents)
    let saved = AudioBookmark(serverItemID: Self.item, time: 12, title: "Ch. 2", createdAt: nil)

    intents.addResult = .success(.created(saved))
    #expect(await model.addBookmark(at: 12.7, title: "Ch. 2") == .added(saved))
    #expect(intents.addCalls.last?.time == 12.7)
    #expect(model.actionErrorMessage == nil)

    intents.addResult = .success(.tooCloseToExisting(saved))
    #expect(await model.addBookmark(at: 12.2, title: "Again") == .alreadyBookmarked(saved))

    intents.addResult = .failure(AudioBookmarkIntentError.notAuthenticated)
    #expect(await model.addBookmark(at: 30, title: "t") == .failed)
    #expect(model.actionErrorMessage == AudioBookmarkCopy.saveFailed)
  }

  @Test func renameAndDeleteSendTheExactTimeAndReportFailures() async {
    let intents = FakeAudioBookmarkIntents()
    let model = AudioBookmarksModel(itemID: Self.item, intents: intents)
    let bookmark = AudioBookmark(
      serverItemID: Self.item, time: 0.30000000000000004, title: "Old", createdAt: nil)

    await model.rename(bookmark, to: "New")
    await model.delete(bookmark)
    #expect(intents.renameCalls.map(\.time) == [0.30000000000000004])
    #expect(intents.renameCalls.map(\.title) == ["New"])
    #expect(intents.deleteCalls == [0.30000000000000004])
    #expect(model.actionErrorMessage == nil)

    intents.renameError = AudioBookmarkStoreError.emptyTitle
    await model.rename(bookmark, to: " ")
    #expect(model.actionErrorMessage == AudioBookmarkCopy.emptyTitle)

    intents.deleteError = AudioBookmarkIntentError.notAuthenticated
    await model.delete(bookmark)
    #expect(model.actionErrorMessage == AudioBookmarkCopy.deleteFailed)
  }
}

@MainActor
private final class FakeAudioBookmarkIntents: AudioBookmarkIntents {
  var addResult: Result<AudioBookmarkCreation, any Error> = .failure(
    AudioBookmarkIntentError.notAuthenticated)
  var renameError: (any Error)?
  var deleteError: (any Error)?
  private(set) var addCalls: [(time: Double, title: String)] = []
  private(set) var renameCalls: [(time: Double, title: String)] = []
  private(set) var deleteCalls: [Double] = []

  private let stream: AsyncStream<[AudioBookmark]>
  private let continuation: AsyncStream<[AudioBookmark]>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream(of: [AudioBookmark].self)
  }

  func emit(_ bookmarks: [AudioBookmark]) {
    continuation.yield(bookmarks)
  }

  nonisolated func observeBookmarks(itemID: String) -> AsyncStream<[AudioBookmark]> {
    stream
  }

  func addBookmark(itemID: String, at time: Double, title: String) async throws
    -> AudioBookmarkCreation
  {
    addCalls.append((time, title))
    return try addResult.get()
  }

  func renameBookmark(itemID: String, time: Double, to title: String) async throws {
    if let renameError { throw renameError }
    renameCalls.append((time, title))
  }

  func deleteBookmark(itemID: String, time: Double) async throws {
    if let deleteError { throw deleteError }
    deleteCalls.append(time)
  }
}
