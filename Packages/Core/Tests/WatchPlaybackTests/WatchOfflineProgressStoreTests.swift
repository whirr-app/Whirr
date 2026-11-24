import ABSApi
import Foundation
import Testing
import WatchPlayback
import WatchProtocol

@MainActor
@Suite("Watch offline progress")
struct WatchOfflineProgressStoreTests {

  @Test("duplicate session IDs preserve the original session")
  func duplicateSessionID() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
    let id = UUID()
    let original = try await store.startSession(selection: .audiobookshelf(itemID: "book", episodeID: nil), id: id)
    await #expect(throws: WatchOfflineProgressStoreError.duplicate(id)) {
      try await store.startSession(selection: .audiobookshelf(itemID: "other", episodeID: nil), id: id)
    }
    #expect(await store.session(id: id) == original)
  }

  @Test("progress is durable, bounded, and clears only explicitly acknowledged uploads")
  func durableProgressAndPartialAcknowledgement() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let now = Date(timeIntervalSince1970: 100)
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: stamp, now: { now })
    let firstID = UUID()
    let secondID = UUID()
    let first = try await store.startSession(
      selection: .audiobookshelf(itemID: "book-1", episodeID: nil), startPosition: 0,
      duration: 100, id: firstID)
    _ = try await store.recordProgress(
      sessionID: first.id, currentPosition: 12, listenedDelta: 12)
    _ = try await store.finish(
      sessionID: first.id, currentPosition: 100, listenedDelta: 88)
    _ = try await store.startSession(
      selection: .audiobookshelf(itemID: "book-2", episodeID: nil), startPosition: 2,
      duration: 100, id: secondID)
    _ = try await store.recordProgress(
      sessionID: secondID, currentPosition: 4, listenedDelta: 2)

    let batch = try await store.pendingUploadBatch(limit: 2)
    #expect(
      Set(batch.map(\.id)) == Set([firstID.uuidString.lowercased(), secondID.uuidString.lowercased()]))
    await #expect(throws: WatchOfflineProgressStoreError.uploadAlreadyInFlight) {
      try await store.pendingUploadBatch()
    }
    try await store.acknowledge(
      LocalSessionSyncOutcome(acknowledged: [firstID.uuidString.lowercased()], unacknowledged: []))
    #expect(await store.session(id: firstID) == nil)
    #expect(await store.session(id: secondID) != nil)

    let retry = try await store.pendingUploadBatch()
    #expect(retry.map(\.id) == [secondID.uuidString.lowercased()])
    try await store.acknowledge(
      LocalSessionSyncOutcome(
        acknowledged: [secondID.uuidString.lowercased()], unacknowledged: []))
    #expect(await store.allSessions().isEmpty)

    let restarted = try WatchOfflineProgressStore(rootURL: root, accountStamp: stamp, now: { now })
    #expect(await restarted.allSessions().isEmpty)
  }

  @Test("an inflight batch is requeued after restart and native selections are rejected")
  func inflightRecoveryAndSourceBoundary() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: stamp)
    let id = UUID()
    await #expect(throws: WatchOfflineProgressStoreError.nativeSelection) {
      try await store.startSession(selection: .nativeFeed(feedID: "7", episodeID: "ep"), id: id)
    }
    _ = try await store.startSession(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), id: id)
    _ = try await store.recordProgress(sessionID: id, currentPosition: 5, listenedDelta: 5)
    _ = try await store.pendingUploadBatch()

    let restarted = try WatchOfflineProgressStore(rootURL: root, accountStamp: stamp)
    #expect(await restarted.isUploadInFlight(id: id) == false)
    #expect(try await restarted.pendingUploadBatch().count == 1)
  }

  @Test("only listening or a user seek moves the listen time; saves alone do not")
  func listenTimeTracksListeningNotSaves() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(Date(timeIntervalSince1970: 100))
    let store = try WatchOfflineProgressStore(
      rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), now: { clock.date })
    let session = try await store.startSession(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), startPosition: 0, duration: 100)
    #expect(session.lastListenedAt == nil)
    #expect(session.effectiveLastListenedAt == Date(timeIntervalSince1970: 100))

    clock.date = Date(timeIntervalSince1970: 110)
    try await store.recordProgress(sessionID: session.id, currentPosition: 10, listenedDelta: 10)
    #expect(await store.session(id: session.id)?.lastListenedAt == Date(timeIntervalSince1970: 110))

    clock.date = Date(timeIntervalSince1970: 200)
    try await store.recordProgress(sessionID: session.id, currentPosition: 10, listenedDelta: 0)
    let paused = try #require(await store.session(id: session.id))
    #expect(paused.lastListenedAt == Date(timeIntervalSince1970: 110))
    #expect(paused.updatedAt == Date(timeIntervalSince1970: 200))

    clock.date = Date(timeIntervalSince1970: 300)
    try await store.recordProgress(sessionID: session.id, currentPosition: 50, listenedDelta: 0, userSeek: true)
    #expect(await store.session(id: session.id)?.lastListenedAt == Date(timeIntervalSince1970: 300))

    let restarted = try WatchOfflineProgressStore(
      rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), now: { clock.date })
    #expect(await restarted.session(id: session.id)?.lastListenedAt == Date(timeIntervalSince1970: 300))
  }

  @Test("a row written during its upload keeps the unsent listening in a new row")
  func acknowledgementDoesNotDeleteWritesMadeDuringTheUpload() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(Date(timeIntervalSince1970: 100))
    let store = try WatchOfflineProgressStore(
      rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), now: { clock.date })
    let session = try await store.startSession(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), startPosition: 0, duration: 100,
      lastKnownSharedPosition: 0)
    try await store.recordProgress(sessionID: session.id, currentPosition: 20, listenedDelta: 20)
    let batch = try await store.pendingUploadBatch()
    #expect(batch.first?.timeListening == 20)

    clock.date = Date(timeIntervalSince1970: 130)
    try await store.recordProgress(sessionID: session.id, currentPosition: 30, listenedDelta: 10)
    let remap = try await store.acknowledge(
      LocalSessionSyncOutcome(acknowledged: [session.id.uuidString.lowercased()], unacknowledged: []))

    #expect(await store.session(id: session.id) == nil)
    let newID = try #require(remap[session.id])
    let remainder = try #require(await store.session(id: newID))
    #expect(remainder.currentPosition == 30)
    #expect(remainder.startPosition == 20)
    #expect(remainder.timeListening == 10)
    #expect(remainder.selection == session.selection)
    #expect(remainder.duration == 100)
    #expect(remainder.lastListenedAt == Date(timeIntervalSince1970: 130))
    #expect(await store.isUploadInFlight(id: newID) == false)
    #expect(try await store.pendingUploadBatch().map(\.id) == [newID.uuidString.lowercased()])
  }

  @Test("an unchanged row is deleted on acknowledgement and remaps nothing")
  func unchangedAcknowledgedRowIsDeleted() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
    let session = try await store.startSession(selection: .audiobookshelf(itemID: "book", episodeID: nil))
    try await store.recordProgress(sessionID: session.id, currentPosition: 5, listenedDelta: 5)
    _ = try await store.pendingUploadBatch()
    let remap = try await store.acknowledge(
      LocalSessionSyncOutcome(acknowledged: [session.id.uuidString.lowercased()], unacknowledged: []))
    #expect(remap.isEmpty)
    #expect(await store.allSessions().isEmpty)
  }

  @Test("sessions written without the optional baseline fields remain decodable")
  func persistedSessionWithoutBaselineDecodes() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: stamp)
    let id = UUID()
    _ = try await store.startSession(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), startPosition: 1, id: id)
    let data = try Data(contentsOf: root.appendingPathComponent("progress.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let sessions = try #require(object["sessions"] as? [[String: Any]])
    #expect(sessions.first?["lastKnownSharedPosition"] == nil)
    #expect(sessions.first?["lastKnownSharedObservedAt"] == nil)

    let restarted = try WatchOfflineProgressStore(rootURL: root, accountStamp: stamp)
    #expect(await restarted.session(id: id)?.lastKnownSharedPosition == nil)
    #expect(await restarted.session(id: id)?.lastKnownSharedObservedAt == nil)
  }

  @Test("a conflicted title does not reserve or block unrelated listening sessions")
  func eligibleTitlesUploadIndependently() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
    let held = try await store.startSession(selection: .audiobookshelf(itemID: "conflict", episodeID: nil))
    let ready = try await store.startSession(selection: .audiobookshelf(itemID: "ready", episodeID: nil))
    try await store.recordProgress(sessionID: held.id, currentPosition: 20, listenedDelta: 10)
    try await store.recordProgress(sessionID: ready.id, currentPosition: 5, listenedDelta: 5)
    let batch = try await store.pendingUploadBatch(eligibleIDs: [ready.id])
    #expect(batch.map(\.id) == [ready.id.uuidString.lowercased()])
    #expect(await store.isUploadInFlight(id: held.id) == false)
    try await store.acknowledge(
      LocalSessionSyncOutcome(acknowledged: [ready.id.uuidString.lowercased()], unacknowledged: []))
    #expect(await store.session(id: held.id)?.currentPosition == 20)
    #expect(await store.session(id: held.id)?.timeListening == 10)
  }

}
