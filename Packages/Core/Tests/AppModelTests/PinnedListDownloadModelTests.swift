import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Pinned-list download model.
@MainActor
@Suite struct PinnedListDownloadModelTests {

  @Test(arguments: [
    (nil as PinnedListDownloadSummary?, false, PinnedListDownloadModel.State.off),
    (summary(total: 3, completed: 1), true, .downloading(done: 1, total: 3)),
    (summary(total: 3, completed: 3), true, .downloaded),
    (summary(total: 0, completed: 0), true, .downloaded),
    (summary(total: 3, completed: 1, waiting: 2), true, .waitingForWiFi),
    (summary(total: 3, completed: 1, waiting: 1), true, .downloading(done: 1, total: 3)),
    (summary(total: 3, completed: 1, waiting: 1, failed: 1), true, .failed(count: 1)),
  ])
  func stateFollowsTheSummary(
    summary: PinnedListDownloadSummary?, isPinned: Bool, expected: PinnedListDownloadModel.State
  ) {
    #expect(PinnedListDownloadModel.state(isPinned: isPinned, summary: summary) == expected)
  }

  @Test func observesPinAndSummary() async {
    let pins = FakePinnedListDownloads()
    let model = PinnedListDownloadModel(key: key, pins: pins)
    pins.keys.yield([key])
    pins.summaries.yield(summary(total: 2, completed: 2))
    _ = await awaitCondition("the pin and its summary arrive") { model.state == .downloaded }
    #expect(model.isPinned)
  }

  @Test func aSmallListPinsWithoutAsking() async {
    let pins = FakePinnedListDownloads()
    pins.preview = PinnedListDownloadPreview(count: 10, expectedBytes: nil)
    let model = PinnedListDownloadModel(key: key, pins: pins)
    await model.turnOn()
    #expect(model.pendingConfirmation == nil)
    #expect(pins.pinned == [key])
  }

  @Test(arguments: [
    (PinnedListDownloadPreview(count: 11, expectedBytes: nil), "Download 11 Items?"),
    (PinnedListDownloadPreview(count: 2, expectedBytes: 3_000_000_000), "Download 2 Items?"),
  ])
  func aLargeListAsksFirst(preview: PinnedListDownloadPreview, title: String) async throws {
    let pins = FakePinnedListDownloads()
    pins.preview = preview
    let model = PinnedListDownloadModel(key: key, pins: pins)
    await model.turnOn()

    let confirmation = try #require(model.pendingConfirmation)
    #expect(confirmation.title == title)
    #expect(pins.pinned.isEmpty)

    await model.confirm(confirmation)
    #expect(pins.pinned == [key])
    #expect(model.pendingConfirmation == nil)
  }

  @Test func theConfirmationGivesASizeOnlyWhenEveryOneIsKnown() async throws {
    let pins = FakePinnedListDownloads()
    pins.preview = PinnedListDownloadPreview(count: 12, expectedBytes: 6_100_000_000)
    let model = PinnedListDownloadModel(key: collectionKey, pins: pins)
    await model.turnOn()
    let sized = try #require(model.pendingConfirmation)
    #expect(sized.title == "Download 12 Books?")
    #expect(sized.message.contains("GB"))
    #expect(sized.message.contains("kept even when storage is full"))

    pins.preview = PinnedListDownloadPreview(count: 12, expectedBytes: nil)
    await model.turnOn()
    #expect(try #require(model.pendingConfirmation).message.contains("GB") == false)
  }

  @Test func turningOffAsksOnlyWhenItWillDeleteSomething() async throws {
    let pins = FakePinnedListDownloads()
    let model = PinnedListDownloadModel(key: key, pins: pins)
    pins.removalCount = 0
    await model.turnOff()
    #expect(pins.unpinned == [key])

    pins.removalCount = 8
    await model.turnOff()
    let confirmation = try #require(model.pendingConfirmation)
    #expect(confirmation.title == "Remove 8 Downloads?")
    #expect(confirmation.message == "Items you downloaded yourself stay.")
    #expect(pins.unpinned == [key])
    await model.confirm(confirmation)
    #expect(pins.unpinned == [key, key])
  }

  @Test func tryAgainRetriesTheListsFailedDownloads() async {
    let pins = FakePinnedListDownloads()
    let model = PinnedListDownloadModel(key: key, pins: pins)
    await model.retryFailed()
    #expect(pins.retried == [key])
  }

  @Test func aFailedPinSaysSo() async {
    let pins = FakePinnedListDownloads()
    pins.failure = URLError(.cannotOpenFile)
    let model = PinnedListDownloadModel(key: key, pins: pins)
    await model.turnOn()
    #expect(model.errorMessage != nil)
    model.dismissError()
    #expect(model.errorMessage == nil)
  }

  private let key = LibraryCollectionKey(serverLibraryID: "lib", kind: .playlist, serverID: "pl")
  private let collectionKey = LibraryCollectionKey(serverLibraryID: "lib", kind: .collection, serverID: "c")
}

private func summary(
  total: Int, completed: Int, waiting: Int = 0, failed: Int = 0
) -> PinnedListDownloadSummary {
  PinnedListDownloadSummary(
    total: total, completed: completed, waitingForWiFi: waiting, failed: failed, notDownloadable: 0)
}

final class FakePinnedListDownloads: PinnedListDownloadControlling, @unchecked Sendable {
  let keys = AsyncStreamPipe<Set<LibraryCollectionKey>>()
  let summaries = AsyncStreamPipe<PinnedListDownloadSummary?>()
  var preview = PinnedListDownloadPreview(count: 0, expectedBytes: 0)
  var removalCount = 0
  var failure: (any Error)?
  private(set) var pinned: [LibraryCollectionKey] = []
  private(set) var unpinned: [LibraryCollectionKey] = []
  private(set) var retried: [LibraryCollectionKey] = []

  func observePinnedKeys() -> AsyncStream<Set<LibraryCollectionKey>> { keys.stream }
  func observeSummary(_ key: LibraryCollectionKey) -> AsyncStream<PinnedListDownloadSummary?> {
    summaries.stream
  }
  func downloadPreview(_ key: LibraryCollectionKey) async throws -> PinnedListDownloadPreview { preview }
  func pin(_ key: LibraryCollectionKey) async throws {
    if let failure { throw failure }
    pinned.append(key)
  }
  func downloadsUnpinningWouldRemove(_ key: LibraryCollectionKey) async throws -> Int { removalCount }
  func unpin(_ key: LibraryCollectionKey) async throws { unpinned.append(key) }
  func retryFailed(_ key: LibraryCollectionKey) async throws { retried.append(key) }
}

/// A stream the test feeds by hand.
final class AsyncStreamPipe<Element: Sendable>: Sendable {
  let stream: AsyncStream<Element>
  private let continuation: AsyncStream<Element>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func yield(_ element: Element) { continuation.yield(element) }
}
