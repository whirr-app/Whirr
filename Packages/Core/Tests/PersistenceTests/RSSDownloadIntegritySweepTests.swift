import Foundation
import Testing

@testable import Persistence

@Suite struct RSSDownloadIntegritySweepTests {

  @Test("RSS launch sweep reconciles rows and removes only RSS-root orphans")
  func sweepReconcilesRowsAndIsRootScoped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RSSDownloadIntegritySweepTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let database = try AppDatabase.inMemory()
    let store = try RSSDownloadStore(database: database)
    let valid = try await seedDownload(database: database, store: store, key: "valid", bytes: 10)
    let deleting = try await seedDownload(
      database: database, store: store, key: "deleting", bytes: 10)
    let missing = try await seedDownload(
      database: database, store: store, key: "missing", bytes: 10)
    let invalid = try await seedDownload(
      database: database, store: store, key: "invalid", bytes: 10)

    try writeFile(root: root, relativePath: valid.relativePath, bytes: 10)
    try writeFile(root: root, relativePath: deleting.relativePath, bytes: 10)
    try writeFile(root: root, relativePath: invalid.relativePath, bytes: 5)
    try writeFile(root: root, relativePath: "RSS/orphan.mp3", bytes: 3)
    let absPath = root.appendingPathComponent("1/abs-owned.bin")
    try FileManager.default.createDirectory(
      at: absPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 7).write(to: absPath)

    _ = try await store.transitionAsync(downloadId: deleting.id!, to: .deleting)

    let result = try RSSDownloadIntegritySweep(rootURL: root, downloadStore: store).run()

    #expect(result.failedMissingFileDownloadIds == [missing.id!, invalid.id!].sorted())
    #expect(result.finishedDeletionDownloadIds == [deleting.id!])
    #expect(result.removedOrphanRelativePaths.contains("RSS/orphan.mp3"))
    #expect(result.removedOrphanRelativePaths.contains(invalid.relativePath))
    #expect(try store.fetch(downloadId: valid.id!)?.state == .completed)
    #expect(try store.fetch(downloadId: missing.id!)?.state == .failed)
    #expect(try store.fetch(downloadId: invalid.id!)?.state == .failed)
    #expect(try store.fetch(downloadId: deleting.id!) == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(valid.relativePath).path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("RSS/orphan.mp3").path) == false)
    #expect(FileManager.default.fileExists(atPath: absPath.path))
  }

  @Test("a deleting RSS row whose path escapes the RSS root leaves the file alone")
  func traversalRowPathIsNeverRemoved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "RSSDownloadIntegritySweepTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let database = try AppDatabase.inMemory()
    let store = try RSSDownloadStore(database: database)
    let deleting = try await seedDownload(
      database: database, store: store, key: "deleting", bytes: 10)
    let sentinel = root.deletingLastPathComponent().appendingPathComponent(
      "rss-sweep-escape-\(UUID().uuidString)")
    try Data([0xA5, 0x5A]).write(to: sentinel)
    defer { try? FileManager.default.removeItem(at: sentinel) }
    let maliciousPath = "RSS/../\(sentinel.lastPathComponent)"
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET relativePath = ? WHERE id = ?",
        arguments: [maliciousPath, deleting.id!])
    }
    _ = try await store.transitionAsync(downloadId: deleting.id!, to: .deleting)

    let result = try RSSDownloadIntegritySweep(rootURL: root, downloadStore: store).run()

    #expect(result.finishedDeletionDownloadIds == [deleting.id!])
    #expect(try store.fetch(downloadId: deleting.id!) == nil)
    #expect(try Data(contentsOf: sentinel) == Data([0xA5, 0x5A]))
  }

  private func seedDownload(
    database: AppDatabase, store: RSSDownloadStore, key: String, bytes: Int64
  ) async throws -> RSSDownloadRecord {
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(UUID().uuidString).xml")!, title: key,
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodeStore = RSSEpisodeStore(database: database)
    _ = try await episodeStore.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: key, title: key,
          enclosureURL: URL(string: "https://example.com/\(UUID().uuidString).mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: bytes)
      ])
    let episode = try #require(await episodeStore.fetchEpisode(feedId: feedId, identityKey: key))
    let row = try await store.claimOrCreateAsync(episodeId: try #require(episode.id))
    _ = try await store.transitionAsync(downloadId: try #require(row.id), to: .downloading)
    return try await store.completeAsync(downloadId: try #require(row.id), actualBytes: bytes)
  }

  private func writeFile(root: URL, relativePath: String, bytes: Int) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: bytes).write(to: url)
  }
}
