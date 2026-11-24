import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// The one rule that folds a group's manifests into a row and an inventory entry. A
/// group mid-plan is not a failure, a storage refusal is a decline, and only a complete plan of
/// completed files is ready.
@Suite("Watch download group")
struct WatchDownloadGroupTests {
  private let book = WatchSelection.audiobookshelf(itemID: "book-1", episodeID: nil)
  private let createdAt = Date(timeIntervalSinceReferenceDate: 5_000)

  @Test func aBookWithThreeOfTwelveManifestsEnqueuedIsEnqueuingNotFailed() throws {
    let manifests = try (1...3).map {
      try manifest(index: $0, of: 12, state: $0 == 1 ? .downloading : .queued)
    }
    let group = try #require(WatchDownloadGroup.make(manifests))
    #expect(group.state == .enqueuing)
    #expect(group.expectedTrackCount == 12)

    let entry = try #require(try WatchABSInventoryProjection.entry(for: group))
    #expect(entry.state == .receiving)
    #expect(entry.trackCount == 12)
    #expect(entry.completedTracks == 0)
  }

  @Test func oneStorageFailureFoldsTheGroupToDeclined() throws {
    for reason in [WatchDownloadFailureReason.storage, .quota] {
      let manifests = [
        try manifest(index: 1, of: 2, state: .completed, received: 100),
        try manifest(index: 2, of: 2, state: .failed, failure: reason),
      ]
      let group = try #require(WatchDownloadGroup.make(manifests))
      #expect(group.state == .declined)
      let entry = try #require(try WatchABSInventoryProjection.entry(for: group))
      #expect(entry.state == .declined)
      #expect(entry.declineReason == .storageFull)
    }
  }

  @Test func otherFailuresMapOntoTheSharedVocabulary() throws {
    let cases: [(WatchDownloadFailureReason?, WatchABSInventoryEntry.FailureReason)] = [
      (.transport, .network), (.interrupted, .network), (.cancelled, .network),
      (.unauthorized, .httpStatus), (.validation, .invalidResponse), (nil, .invalidResponse),
    ]
    for (reason, expected) in cases {
      let group = try #require(
        WatchDownloadGroup.make([try manifest(index: 1, of: 1, state: .failed, failure: reason)]))
      #expect(group.state == .failed)
      #expect(try WatchABSInventoryProjection.entry(for: group)?.failureReason == expected)
    }
  }

  @Test func onlyAWholePlanOfCompletedFilesIsReady() throws {
    let manifests = [
      try manifest(index: 1, of: 2, state: .completed, received: 300),
      try manifest(index: 2, of: 2, state: .completed, received: 200),
    ]
    let group = try #require(WatchDownloadGroup.make(manifests))
    #expect(group.state == .ready)
    let entry = try #require(try WatchABSInventoryProjection.entry(for: group))
    #expect(entry.state == .ready)
    #expect(entry.committedBytes == 500)
    #expect(entry.trackCount == 2)
    #expect(entry.completedTracks == 2)

    // One file finished of two is downloading, not "on the Watch".
    let partial = try #require(
      WatchDownloadGroup.make([
        try manifest(index: 1, of: 2, state: .completed, received: 300),
        try manifest(index: 2, of: 2, state: .downloading, received: 50),
      ]))
    #expect(partial.state == .downloading)
    #expect(try WatchABSInventoryProjection.entry(for: partial)?.completedTracks == 1)
  }

  @Test func progressIsWeightedByBytesAcrossTheGroup() throws {
    let group = try #require(
      WatchDownloadGroup.make([
        try manifest(index: 1, of: 2, state: .completed, received: 300, expected: 300),
        try manifest(index: 2, of: 2, state: .downloading, received: 100, expected: 700),
      ]))
    #expect(group.progress == 0.4)
    #expect(try WatchABSInventoryProjection.entry(for: group)?.progress == 0.4)
  }

  @Test func aWiFiHoldIsWaitingForNetwork() throws {
    let group = try #require(
      WatchDownloadGroup.make([try manifest(index: 1, of: 1, state: .queued, failure: .waitingForWiFi)]))
    #expect(group.state == .waitingForNetwork)
    #expect(try WatchABSInventoryProjection.entry(for: group)?.state == .waitingForNetwork)

    let queued = try #require(WatchDownloadGroup.make([try manifest(index: 1, of: 1, state: .queued)]))
    #expect(queued.state == .waiting)
    #expect(try WatchABSInventoryProjection.entry(for: queued)?.state == .receiving)
  }

  /// A plan that names a track twice, or more tracks than it expects, can never complete; reading
  /// it as mid-plan would leave the row spinning for ever.
  @Test func anInconsistentPlanIsFailed() throws {
    let duplicated = [
      try manifest(index: 1, of: 3, state: .completed), try manifest(index: 1, of: 3, state: .queued),
    ]
    #expect(WatchDownloadGroup.make(duplicated)?.state == .failed)
    let overfull = try (1...3).map { try manifest(index: $0, of: 2, state: .completed) }
    #expect(WatchDownloadGroup.make(overfull)?.state == .failed)
  }

  @Test func originAndRevisionComeFromTheManifests() throws {
    let phone = try #require(
      WatchDownloadGroup.make([try manifest(index: 1, of: 1, state: .queued, origin: .phone, revision: 4)]))
    #expect(phone.origin == .phone)
    #expect(phone.phoneRevision == 4)
    let entry = try #require(try WatchABSInventoryProjection.entry(for: phone))
    #expect(entry.origin == .phone)
    #expect(entry.revision == 4)

    let wrist = try #require(WatchDownloadGroup.make([try manifest(index: 1, of: 1, state: .queued)]))
    #expect(wrist.origin == .watch)
    #expect(try WatchABSInventoryProjection.entry(for: wrist)?.revision == nil)
  }

  @Test func groupsAreKeyedByAccountAndSelection() throws {
    let episode = WatchSelection.audiobookshelf(itemID: "show-1", episodeID: "ep-1")
    let groups = WatchDownloadGroup.groups(from: [
      try manifest(index: 1, of: 2, state: .completed),
      try manifest(index: 1, of: 1, state: .queued, selection: episode),
      try manifest(index: 2, of: 2, state: .completed),
    ])
    #expect(groups.count == 2)
    #expect(Set(groups.map(\.selection)) == [book, episode])
    #expect(groups.first { $0.selection == book }?.state == .ready)
  }

  // MARK: Manifest origin on disk

  @Test func aManifestWrittenBeforeOriginDecodesAsWatchOrigin() throws {
    let written = try manifest(index: 1, of: 1, state: .queued)
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(written)) as? [String: Any])
    #expect(object["origin"] == nil)
    #expect(object["phoneRevision"] == nil)
    object["phoneRevision"] = 9
    let decoded = try JSONDecoder().decode(
      WatchDownloadManifest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.origin == .watch)
    #expect(decoded.phoneRevision == nil)
  }

  @Test func aPhoneOriginManifestKeepsItsRevision() throws {
    let written = try manifest(index: 1, of: 1, state: .queued, origin: .phone, revision: 3)
    let decoded = try JSONDecoder().decode(WatchDownloadManifest.self, from: JSONEncoder().encode(written))
    #expect(decoded.origin == .phone)
    #expect(decoded.phoneRevision == 3)

    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(written)) as? [String: Any])
    object["origin"] = "satellite"
    let unknown = try JSONDecoder().decode(
      WatchDownloadManifest.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(unknown.origin == .watch)
    #expect(unknown.phoneRevision == nil)
  }

  // MARK: Fixtures

  private func manifest(
    index: Int, of count: Int, state: WatchDownloadState, received: Int64 = 0, expected: Int64 = 1_000,
    failure: WatchDownloadFailureReason? = nil, selection: WatchSelection? = nil,
    origin: WatchABSOrigin = .watch, revision: UInt64? = nil
  ) throws -> WatchDownloadManifest {
    let selection = selection ?? book
    return WatchDownloadManifest(
      id: UUID(), accountStamp: try accountStamp(account: "a", server: "s"), selection: selection,
      downloadGroupID: selection == book ? "book-1" : "ep-1", expectedTrackCount: count, fileID: "file-\(index)",
      fileIndex: index, startOffset: 0, duration: 60, expectedBytes: expected, expectedMIMEType: "audio/mpeg",
      destinationRelativePath: "file-\(index).mp3", state: state, receivedBytes: received,
      failureReason: failure, createdAt: createdAt, updatedAt: createdAt, origin: origin,
      phoneRevision: revision)
  }
}
