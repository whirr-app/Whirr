import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

@MainActor
@Suite("Watch persisted format compatibility")
struct WatchStoreFormatCompatibilityTests {
  private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let date = Date(timeIntervalSince1970: 100.5)

  // Literal schemas from the envelopes at HEAD before the fenced-store migration.
  private let progress = """
    {"version":1,"accountStamp":{"accountIdentityHash":"a","serverIdentityHash":"s"},
     "sessions":[{"id":"00000000-0000-0000-0000-000000000001",
       "accountStamp":{"accountIdentityHash":"a","serverIdentityHash":"s"},
       "selection":{"source":"audiobookshelf","itemID":"book"},
       "startedAt":100500,"updatedAt":100500,"startPosition":2,"currentPosition":2,
       "duration":50,"timeListening":0,"isFinished":false}],"inFlightIDs":[]}
    """
  private let downloads = """
    {"version":1,"accountStamp":{"accountIdentityHash":"a","serverIdentityHash":"s"},
     "networkPolicy":"wifiOnly","storageQuotaBytes":100,
     "manifests":[{"id":"00000000-0000-0000-0000-000000000001",
       "accountStamp":{"accountIdentityHash":"a","serverIdentityHash":"s"},
       "selection":{"source":"audiobookshelf","itemID":"book"},
       "downloadGroupID":"group","expectedTrackCount":1,"fileID":"audio","fileIndex":0,
       "startOffset":0,"duration":50,"expectedBytes":4,"expectedMIMEType":"audio/mpeg",
       "destinationRelativePath":"7cff2432ae1972bcb349fbe5707f4920a21748eb2dddab6b4f051231f35c8cb1-0.mp3",
       "state":"queued","receivedBytes":0,"createdAt":100500,"updatedAt":100500}]}
    """

  @Test func progressPersistedBytesMatchLegacyFormat() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WatchOfflineProgressStore(
      rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), now: { date })
    try await store.startSession(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), startPosition: 2, duration: 50, id: id)
    try expectJSON(at: root.appendingPathComponent("progress.json"), equals: progress)
  }

  @Test func downloadsPersistedBytesMatchLegacyFormat() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WatchDownloadStore(
      rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), storageQuotaBytes: 100, now: { date })
    try await store.enqueue(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), downloadGroupID: "group",
      fileID: "audio", duration: 50, expectedBytes: 4, expectedMIMEType: "audio/mpeg", id: id)
    try expectJSON(at: root.appendingPathComponent("manifest.json"), equals: downloads)
  }

  @Test func progressLoadsHandwrittenLegacyBlob() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(progress.utf8).write(to: root.appendingPathComponent("progress.json"))
    let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
    let session = try #require(await store.session(id: id))
    #expect(session.startedAt == date)
    #expect(session.currentPosition == 2)
    #expect(await store.allSessions().count == 1)
  }

  @Test func downloadsLoadHandwrittenLegacyBlob() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(downloads.utf8).write(to: root.appendingPathComponent("manifest.json"))
    let store = try WatchDownloadStore(
      rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), storageQuotaBytes: 100)
    let manifest = try #require(await store.manifest(id: id))
    #expect(manifest.createdAt == date)
    #expect(manifest.expectedBytes == 4)
    #expect(await store.allManifests().count == 1)
  }

  @Test func consumerPayloadsDoNotUseReservedKeys() throws {
    let encoder = JSONEncoder()
    let payloads = [
      try encoder.encode(WatchOfflineProgressStore.Payload(sessions: [], inFlightIDs: [])),
      try encoder.encode(WatchDownloadStore.Payload(networkPolicy: .wifiOnly, storageQuotaBytes: 100, manifests: [])),
    ]
    for data in payloads {
      let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(Set(json.keys).isDisjoint(with: ["version", "accountStamp"]))
    }
  }

  @Test(arguments: ["corrupt", "version", "account", "io"])
  func consumerLoadErrorMapping(failure: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for (filename, literal) in [("progress.json", progress), ("manifest.json", downloads)] {
      let url = root.appendingPathComponent(filename)
      switch failure {
      case "corrupt": try Data("broken".utf8).write(to: url)
      case "version":
        try Data(literal.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8).write(to: url)
      case "account":
        try Data(
          literal.replacingOccurrences(of: "\"accountIdentityHash\":\"a\"", with: "\"accountIdentityHash\":\"other\"")
            .utf8
        )
        .write(to: url)
      default: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      }
    }
    // A progress file that can never be read starts empty: refusing it would fail every later
    // launch and sign-in for the account.
    switch failure {
    case "corrupt", "version":
      let store = try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
      #expect(await store.allSessions().isEmpty)
    default:
      #expect(throws: failure == "account" ? WatchOfflineProgressStoreError.accountMismatch : .storageFailure) {
        try WatchOfflineProgressStore(rootURL: root, accountStamp: accountStamp(account: "a", server: "s"))
      }
    }
    if failure == "corrupt" || failure == "version" {
      let recovered = try WatchDownloadStore(
        rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), storageQuotaBytes: 100)
      _ = recovered
    } else {
      #expect(throws: failure == "account" ? WatchDownloadStoreError.accountMismatch : .storageFailure) {
        try WatchDownloadStore(
          rootURL: root, accountStamp: accountStamp(account: "a", server: "s"), storageQuotaBytes: 100)
      }
    }
  }

  /// A's received-episode store persisted `expectedBytes` and no `enclosureURL`. A ready copy stays
  /// usable; a queued one has no download to resume, so it is dropped with its file and the phone
  /// offers the episode again (ADR 0020 Decision 1).
  @Test func receivedEpisodesDropOnlyWhatAFormatCannotExpress() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let ready = try WatchNativeSelection(feedID: "feed", episodeID: "ready")
    let queued = try WatchNativeSelection(feedID: "feed", episodeID: "queued")
    let readyPath = WatchReceivedEpisodeStore.destinationRelativePath(
      accountStamp: stamp, selection: ready, revision: 4, mimeType: "audio/mpeg")
    let queuedPath = WatchReceivedEpisodeStore.destinationRelativePath(
      accountStamp: stamp, selection: queued, revision: 1, mimeType: "audio/mpeg")
    let files = root.appendingPathComponent("files", isDirectory: true)
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: 4).write(to: files.appendingPathComponent(readyPath))
    try Data([0xCD]).write(to: files.appendingPathComponent(queuedPath))

    let legacy = """
      {"version":1,"accountStamp":{"accountIdentityHash":"a","serverIdentityHash":"s"},
       "appliedGeneration":5,
       "entries":[
         {"selection":{"feedID":"feed","episodeID":"ready"},"revision":4,"state":"ready",
          "title":"Ready","showTitle":"Show","duration":120,"expectedBytes":4,
          "mimeType":"audio/mpeg","chapters":[{"title":"One","start":0}],"phonePosition":0,
          "committedBytes":4,"relativePath":"\(readyPath)","offeredAt":100500,"updatedAt":100500},
         {"selection":{"feedID":"feed","episodeID":"queued"},"revision":1,"state":"receiving",
          "title":"Queued","showTitle":"Show","duration":120,"expectedBytes":4,
          "mimeType":"audio/mpeg","chapters":[],"phonePosition":0,"committedBytes":null,
          "relativePath":"\(queuedPath)","offeredAt":100500,"updatedAt":100500}]}
      """
    try Data(legacy.utf8).write(to: root.appendingPathComponent("received.json"))

    let budget = WatchStorageBudget()
    let store = try WatchReceivedEpisodeStore(
      rootURL: root, accountStamp: stamp, installID: "11111111-1111-4111-8111-111111111111",
      budget: budget, now: { self.date })
    let kept = try #require(await store.entry(for: ready))
    #expect(kept.state == .ready)
    #expect(kept.committedBytes == 4)
    #expect(kept.declaredBytes == nil)
    #expect(kept.enclosureURL == nil)
    #expect(await store.entry(for: queued) == nil)
    #expect(await store.appliedGeneration == 5)
    #expect(await store.reservedBytes() == 4)
    #expect(budget.reservedBytes(for: .receivedEpisodes) == 4)
    let playable = try await store.playableFileURL(for: ready)
    #expect(try Data(contentsOf: playable).count == 4)
    #expect(FileManager.default.fileExists(atPath: files.appendingPathComponent(queuedPath).path) == false)
    #expect(FileManager.default.fileExists(atPath: files.appendingPathComponent(readyPath).path))
  }

  private func expectJSON(at url: URL, equals literal: String) throws {
    let actual = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    let expected = try #require(JSONSerialization.jsonObject(with: Data(literal.utf8)) as? NSDictionary)
    #expect(actual == expected)
  }
}
