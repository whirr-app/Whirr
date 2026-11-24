import Foundation
import Testing
import WatchPlayback
import WatchProtocol

@MainActor
@Suite("Watch durable downloads")
struct WatchDownloadStoreTests {

  @Test("queued downloads become playable only after verified completion and survive restart")
  func verifiedCompletionPersistsAcrossRestart() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
    let selection = WatchSelection.audiobookshelf(itemID: "book-1", episodeID: nil)
    let id = UUID()
    let queued = try await store.enqueue(
      selection: selection, fileID: "audio-file", expectedBytes: 4,
      expectedMIMEType: "audio/mpeg", id: id, chapters: [.init(title: "Chapter 1", start: 0, end: 30)])
    #expect(queued.state == .queued)
    #expect(queued.isPlayable == false)
    await #expect(throws: WatchDownloadStoreError.completedFileMissing) {
      try await store.completedFileURL(for: id)
    }

    let held = try await store.beginTransfer(id: id, isWiFiAvailable: false)
    #expect(held.state == .queued)
    #expect(held.failureReason == .waitingForWiFi)
    _ = try await store.beginTransfer(id: id, isWiFiAvailable: true)
    _ = try await store.attachTransfer(taskIdentifier: "task-1", to: id)

    let temporary = root.appendingPathComponent("incoming.tmp")
    try Data([1, 2, 3, 4]).write(to: temporary)
    let completed = try await store.commitDownloadedTemporaryFile(temporary, for: id)
    #expect(completed.state == .completed)
    #expect(completed.receivedBytes == 4)
    let playable = try await store.completedFileURL(for: id)
    #expect(try Data(contentsOf: playable) == Data([1, 2, 3, 4]))

    let restarted = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
    let persisted = try #require(await restarted.manifest(id: id))
    #expect(persisted.state == .completed)
    #expect(persisted.destinationRelativePath == queued.destinationRelativePath)
    #expect(persisted.chapters == queued.chapters)
    #expect(persisted.chapters.first?.end == 30)

    let otherStamp = try accountStamp(account: "other", server: "s")
    #expect(throws: WatchDownloadStoreError.accountMismatch) {
      try WatchDownloadStore(rootURL: root, accountStamp: otherStamp, storageQuotaBytes: 100)
    }
  }

  @Test("native selections, traversal inputs, symlinks, and corrupt sizes never become playable")
  func rejectsUnsafeOrInvalidFiles() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)

    await #expect(throws: WatchDownloadStoreError.nativeSelection) {
      try await store.enqueue(
        selection: .nativeFeed(feedID: "7", episodeID: "ep"), fileID: "file",
        expectedBytes: 2, expectedMIMEType: "audio/mpeg")
    }
    await #expect(throws: WatchDownloadStoreError.invalidFileIdentity) {
      try await store.enqueue(
        selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "../secret",
        expectedBytes: 2, expectedMIMEType: "audio/mpeg")
    }

    let id = UUID()
    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
      expectedBytes: 2, expectedMIMEType: "audio/mpeg", id: id)
    _ = try await store.beginTransfer(id: id, isWiFiAvailable: true)
    let corrupt = root.appendingPathComponent("corrupt.tmp")
    try Data([1]).write(to: corrupt)
    await #expect(throws: WatchDownloadStoreError.fileSizeMismatch) {
      try await store.commitDownloadedTemporaryFile(corrupt, for: id)
    }
    #expect((await store.manifest(id: id))?.state == .downloading)
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
      let target = root.appendingPathComponent("target.tmp")
      let link = root.appendingPathComponent("link.tmp")
      try Data([1, 2]).write(to: target)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      await #expect(throws: WatchDownloadStoreError.temporaryFileIsSymlink) {
        try await store.commitDownloadedTemporaryFile(link, for: id)
      }
    #endif
    let orphanPart = root.appendingPathComponent("files/orphan.part")
    try Data([9]).write(to: orphanPart)
    _ = try await store.recoverInterruptedTransfers()
    #expect(FileManager.default.fileExists(atPath: orphanPart.path) == false)
  }

  @Test("interrupted rows recover to retryable failure and quota is reserved deterministically")
  func interruptionRetryDeleteAndQuota() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 10)
    let first = try await store.enqueue(
      selection: .audiobookshelf(itemID: "book-1", episodeID: nil), fileID: "one",
      expectedBytes: 8, expectedMIMEType: "audio/mpeg")
    _ = try await store.beginTransfer(id: first.id, isWiFiAvailable: true)
    _ = try await store.attachTransfer(taskIdentifier: "task", to: first.id)

    let restarted = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 10)
    let recovered = try await restarted.recoverInterruptedTransfers()
    #expect(recovered.first?.state == .failed)
    #expect(recovered.first?.failureReason == .interrupted)
    _ = try await restarted.retry(id: first.id)
    try await restarted.delete(id: first.id)
    #expect(await restarted.allManifests().isEmpty)

    _ = try await restarted.enqueue(
      selection: .audiobookshelf(itemID: "book-2", episodeID: nil), fileID: "two",
      expectedBytes: 8, expectedMIMEType: "audio/mpeg")
    await #expect(throws: WatchDownloadStoreError.quotaExceeded) {
      try await restarted.enqueue(
        selection: .audiobookshelf(itemID: "book-3", episodeID: nil), fileID: "three",
        expectedBytes: 3, expectedMIMEType: "audio/mpeg")
    }
  }

  @Test("tampered manifests drop only the invalid rows: duplicate IDs and noncanonical destinations")
  func rejectsTamperedManifestRows() async throws {
    let stamp = try accountStamp(account: "a", server: "s")
    let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)

    do {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
      _ = try await store.enqueue(
        selection: selection, fileID: "file", expectedMIMEType: "audio/mpeg")
      let manifestURL = root.appendingPathComponent("manifest.json")
      var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
      var rows = try #require(object["manifests"] as? [[String: Any]])
      rows[0]["destinationRelativePath"] = "../outside"
      object["manifests"] = rows
      try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
      let reopened = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
      #expect(await reopened.allManifests().isEmpty)
    }

    do {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
      _ = try await store.enqueue(
        selection: selection, fileID: "file", expectedMIMEType: "audio/mpeg")
      let manifestURL = root.appendingPathComponent("manifest.json")
      var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
      var rows = try #require(object["manifests"] as? [[String: Any]])
      rows.append(rows[0])
      object["manifests"] = rows
      try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
      let reopened = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
      #expect(await reopened.allManifests().count == 1)
    }
  }

  @Test("a corrupt or wrong-version manifest file is set aside and the store starts empty")
  func corruptManifestFileStartsEmpty() async throws {
    let stamp = try accountStamp(account: "a", server: "s")
    for contents in ["broken", #"{"version":99,"accountStamp":{},"manifests":[]}"#] {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let manifestURL = root.appendingPathComponent("manifest.json")
      try Data(contents.utf8).write(to: manifestURL)
      let files = root.appendingPathComponent("files", isDirectory: true)
      try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
      let orphan = files.appendingPathComponent("orphan.m4b")
      try Data([1, 2, 3]).write(to: orphan)
      let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
      #expect(await store.allManifests().isEmpty)
      // The unreadable manifest is kept aside, and the files it alone could name are removed.
      let aside = root.appendingPathComponent("manifest.unreadable.json")
      #expect(try Data(contentsOf: aside) == Data(contents.utf8))
      #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
      let reopened = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
      #expect(await reopened.allManifests().isEmpty)
    }
  }

  @Test("opening the store sweeps staging files left by a crash")
  func openingSweepsStagingFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    _ = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
    let orphan = root.appendingPathComponent("files/.audio.1234.part")
    try Data([9]).write(to: orphan)
    _ = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
    #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
  }

  @Test("progress is held in memory and persisted only after a coarse step")
  func progressPersistenceIsThrottled() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 10_000)
    let id = UUID()
    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
      expectedBytes: 1_000, expectedMIMEType: "audio/mpeg", id: id)
    _ = try await store.beginTransfer(id: id, isWiFiAvailable: true)
    let update = { (bytes: Int64) in WatchDownloadTransferUpdate(receivedBytes: bytes, expectedBytes: 1_000) }

    _ = try await store.recordTransferProgress(update(10), for: id)
    #expect((await store.manifest(id: id))?.receivedBytes == 10)
    let afterSmall = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 10_000)
    #expect((await afterSmall.manifest(id: id))?.receivedBytes == 0)

    _ = try await store.recordTransferProgress(update(600), for: id)
    let afterStep = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 10_000)
    #expect((await afterStep.manifest(id: id))?.receivedBytes == 600)
  }

  @Test("a failed persist rolls the in-memory row back")
  func failedPersistRollsBack() async throws {
    #if os(macOS)
      let root = try temporaryDirectory()
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
      }
      let stamp = try accountStamp(account: "a", server: "s")
      let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp)
      let id = UUID()
      _ = try await store.enqueue(
        selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
        expectedBytes: 4, expectedMIMEType: "audio/mpeg", id: id)
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
      await #expect(throws: WatchDownloadStoreError.storageFailure) {
        try await store.beginTransfer(id: id, isWiFiAvailable: true)
      }
      #expect((await store.manifest(id: id))?.state == .queued)
    #endif
  }

  @Test("symlinked storage roots are rejected before any file is installed")
  func rejectsSymlinkedStorageRoots() async throws {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let stamp = try accountStamp(account: "a", server: "s")
      let realRoot = root.appendingPathComponent("real", isDirectory: true)
      try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
      let rootLink = root.appendingPathComponent("root-link", isDirectory: true)
      try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: realRoot)
      #expect(throws: WatchDownloadStoreError.storageFailure) {
        try WatchDownloadStore(rootURL: rootLink, accountStamp: stamp)
      }

      let filesLinkRoot = root.appendingPathComponent("files-link-root", isDirectory: true)
      try FileManager.default.createDirectory(at: filesLinkRoot, withIntermediateDirectories: true)
      let outside = root.appendingPathComponent("outside", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: filesLinkRoot.appendingPathComponent("files", isDirectory: true),
        withDestinationURL: outside)
      #expect(throws: WatchDownloadStoreError.storageFailure) {
        try WatchDownloadStore(rootURL: filesLinkRoot, accountStamp: stamp)
      }
    #endif
  }

  @Test("a shared budget refuses an enqueue that fits the store's own quota")
  func sharedBudgetRefusesEnqueue() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let budget = WatchStorageBudget(totalBytes: 100)
    budget.record(60, for: .receivedEpisodes)
    let store = try WatchDownloadStore(
      rootURL: root, accountStamp: stamp, storageQuotaBytes: 200, storageBudget: budget)

    await #expect(throws: WatchDownloadStoreError.quotaExceeded) {
      try await store.enqueue(
        selection: .audiobookshelf(itemID: "book-1", episodeID: nil), fileID: "one",
        expectedBytes: 50, expectedMIMEType: "audio/mpeg")
    }
    #expect(budget.reservedBytes(for: .audiobookshelf) == 0)
    #expect(budget.reservedBytes(for: .receivedEpisodes) == 60)
    #expect(await store.allManifests().isEmpty)

    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "book-2", episodeID: nil), fileID: "two",
      expectedBytes: 40, expectedMIMEType: "audio/mpeg")
    #expect(budget.reservedBytes(for: .audiobookshelf) == 40)
    #expect(budget.usedBytes == 100)
  }

  @Test("the shared ledger follows enqueue, failure, retry, commit and delete")
  func sharedBudgetTracksManifestChanges() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let budget = WatchStorageBudget(totalBytes: 1_000)
    let store = try WatchDownloadStore(
      rootURL: root, accountStamp: stamp, storageQuotaBytes: 1_000, storageBudget: budget)
    let id = UUID()

    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
      expectedBytes: 30, expectedMIMEType: "audio/mpeg", id: id)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 30)

    _ = try await store.fail(id: id, reason: .transport)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 0)

    _ = try await store.retry(id: id)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 30)

    _ = try await store.beginTransfer(id: id, isWiFiAvailable: true)
    let temporary = root.appendingPathComponent("incoming.tmp")
    try Data(repeating: 7, count: 30).write(to: temporary)
    _ = try await store.commitDownloadedTemporaryFile(temporary, for: id)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 30)

    try await store.delete(id: id)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 0)
    #expect(budget.usedBytes == 0)
  }

  @Test("opening a store records what its manifests already reserve")
  func sharedBudgetRecordsOnLoad() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    do {
      let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
      _ = try await store.enqueue(
        selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
        expectedBytes: 25, expectedMIMEType: "audio/mpeg")
    }

    let budget = WatchStorageBudget(totalBytes: 100)
    budget.record(99, for: .audiobookshelf)
    _ = try WatchDownloadStore(
      rootURL: root, accountStamp: stamp, storageQuotaBytes: 100, storageBudget: budget)
    #expect(budget.reservedBytes(for: .audiobookshelf) == 25)
  }

  @Test("a failed write restores the shared reservation")
  func failedPersistRestoresSharedBudget() async throws {
    #if os(macOS)
      let root = try temporaryDirectory()
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
      }
      let stamp = try accountStamp(account: "a", server: "s")
      let budget = WatchStorageBudget(totalBytes: 100)
      let store = try WatchDownloadStore(
        rootURL: root, accountStamp: stamp, storageQuotaBytes: 100, storageBudget: budget)
      _ = try await store.enqueue(
        selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
        expectedBytes: 4, expectedMIMEType: "audio/mpeg")
      #expect(budget.reservedBytes(for: .audiobookshelf) == 4)

      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
      await #expect(throws: WatchDownloadStoreError.storageFailure) {
        try await store.enqueue(
          selection: .audiobookshelf(itemID: "other", episodeID: nil), fileID: "other",
          expectedBytes: 5, expectedMIMEType: "audio/mpeg")
      }
      #expect(budget.reservedBytes(for: .audiobookshelf) == 4)
    #endif
  }

  // MARK: Phone-sent downloads

  @Test("an enqueue records its origin, and a phone revision only for a phone download")
  func enqueueRecordsOrigin() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
    let book = WatchSelection.audiobookshelf(itemID: "book-1", episodeID: nil)
    let episode = WatchSelection.audiobookshelf(itemID: "show-1", episodeID: "ep-1")
    let phone = try await store.enqueue(
      selection: book, fileID: "f1", expectedBytes: 4, expectedMIMEType: "audio/mpeg", origin: .phone,
      phoneRevision: 3)
    let wrist = try await store.enqueue(
      selection: episode, fileID: "f2", expectedBytes: 4, expectedMIMEType: "audio/mpeg", phoneRevision: 9)
    #expect(phone.origin == .phone && phone.phoneRevision == 3)
    #expect(wrist.origin == .watch && wrist.phoneRevision == nil)

    let restarted = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
    #expect(await restarted.manifest(id: phone.id)?.phoneRevision == 3)
    #expect(await restarted.manifests(for: book).map(\.id) == [phone.id])
    #expect(await restarted.manifests(for: episode).map(\.id) == [wrist.id])
    #expect(await restarted.manifests(for: .audiobookshelf(itemID: "other", episodeID: nil)).isEmpty)
  }

  /// The phone asks for a book the listener already downloaded on the wrist: the files are kept
  /// and become the phone's, so a later omission from the phone's set can remove them.
  @Test("adopting a selection makes every file of it the phone's, and survives restart")
  func adoptionMakesFilesThePhones() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
    let book = WatchSelection.audiobookshelf(itemID: "book-1", episodeID: nil)
    let other = WatchSelection.audiobookshelf(itemID: "book-2", episodeID: nil)
    for index in 0..<2 {
      _ = try await store.enqueue(
        selection: book, downloadGroupID: "book-1", expectedTrackCount: 2, fileID: "f\(index)", fileIndex: index,
        expectedBytes: 4, expectedMIMEType: "audio/mpeg")
    }
    let untouched = try await store.enqueue(
      selection: other, fileID: "g", expectedBytes: 4, expectedMIMEType: "audio/mpeg")

    let adopted = try await store.adopt(selection: book, revision: 5)
    #expect(adopted.count == 2)
    #expect(adopted.allSatisfy { $0.origin == .phone && $0.phoneRevision == 5 })
    #expect(await store.manifest(id: untouched.id)?.origin == .watch)
    #expect(try await store.adopt(selection: .audiobookshelf(itemID: "none", episodeID: nil), revision: 5).isEmpty)

    let restarted = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
    let files = await restarted.manifests(for: book)
    #expect(files.count == 2 && files.allSatisfy { $0.origin == .phone && $0.phoneRevision == 5 })
  }
}
