import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// The Library Cache screen's two artwork-maintenance answers: what the disposable cover cache is
/// costing right now, and emptying it.
@Suite("ArtworkCacheMaintenance")
struct ArtworkCacheMaintenanceTests {
  @Test("the cached size sums every file in the cache directory tree")
  func cachedSizeSumsTheDirectoryTree() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try write(bytes: 4096, to: directory.appendingPathComponent("Cache.db"))
    let nested = directory.appendingPathComponent("fsCachedData", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try write(bytes: 8192, to: nested.appendingPathComponent("cover-1"))
    try write(bytes: 8192, to: nested.appendingPathComponent("cover-2"))
    let maintenance = DiskArtworkCacheMaintenance(directoryURL: directory, clearing: [])

    let bytes = await maintenance.cachedByteSize()

    // Allocated size is block-rounded, so the sum is a floor rather than an equality.
    #expect(bytes >= 4096 + 8192 + 8192)
  }

  @Test("the cached size sums separate artwork directories")
  func cachedSizeSumsMultipleDirectories() async throws {
    let coverDirectory = try makeTemporaryDirectory()
    let rssDirectory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: coverDirectory)
      try? FileManager.default.removeItem(at: rssDirectory)
    }
    try write(bytes: 4096, to: coverDirectory.appendingPathComponent("cover"))
    try write(bytes: 8192, to: rssDirectory.appendingPathComponent("rss-artwork"))
    let maintenance = DiskArtworkCacheMaintenance(
      directoryURLs: [coverDirectory, rssDirectory], clearing: [])

    let bytes = await maintenance.cachedByteSize()

    #expect(bytes >= 4096 + 8192)
  }

  @Test("a cache directory that does not exist yet costs nothing")
  func aMissingDirectoryIsZeroBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ArtworkCacheMaintenanceTests-absent-\(UUID().uuidString)", isDirectory: true)
    let maintenance = DiskArtworkCacheMaintenance(directoryURL: directory, clearing: [])

    #expect(await maintenance.cachedByteSize() == 0)
  }

  @Test("clearing empties every participant, not only the transport cache")
  func clearingReachesEveryParticipant() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let compressed = SpyArtworkCacheClearing()
    let decoded = SpyArtworkCacheClearing()
    let maintenance = DiskArtworkCacheMaintenance(
      directoryURL: directory, clearing: [compressed, decoded])

    await maintenance.clear()

    #expect(await compressed.callCount == 1)
    #expect(await decoded.callCount == 1)
  }

  @Test("clearing empties the cover cache a real client can still read from")
  func clearingEmptiesTheCacheACoverClientReads() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let request = try CoverRequest(itemID: "item-1", width: 132)
    let body = Data(repeating: 0x5A, count: 32 * 1024)
    let client = CoverImageClient(
      server: server, httpClient: coverClient(body: body), cacheDirectory: directory)
    _ = try await client.fetch(request)
    #expect(await client.data(for: request) == body)

    let maintenance = DiskArtworkCacheMaintenance(directoryURL: directory, clearing: [client])
    await maintenance.clear()

    // The cover is gone from the client that could still read it a moment ago. The figure the
    // screen quotes is not asserted here.
    #expect(await client.data(for: request) == nil)
  }

  @Test("the palette clearing participant deletes every persisted palette row")
  func paletteClearingParticipantDeletesEveryPersistedPaletteRow() async throws {
    let records = CoverPaletteRecordStore(database: try AppDatabase.inMemory())
    try await records.upsert(
      CoverPaletteRecord(
        itemId: "item-1", artworkKey: "art-1", accentHue: 0.1, accentSaturation: 0.2,
        accentBrightness: 0.3, extractedAt: Date()))

    await CoverPaletteRecordCacheClearing(recordStore: records).clearCachedArtwork()

    #expect(try await records.fetch(itemId: "item-1") == nil)
  }

  @Test("the no-op maintenance reports nothing and clears nothing")
  func theNoOpMaintenanceIsInert() async {
    let maintenance = NoOpArtworkCacheMaintenance()

    await maintenance.clear()

    #expect(await maintenance.cachedByteSize() == 0)
  }
}

private actor SpyArtworkCacheClearing: ArtworkCacheClearing {
  private(set) var callCount = 0

  func clearCachedArtwork() async {
    callCount += 1
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "ArtworkCacheMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

/// Answers every cover request with the same image bytes.
private func coverClient(body: Data) -> FakeHTTPClient {
  FakeHTTPClient(handler: { _ in
    HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/webp"], body: body)
  })
}

private func write(bytes: Int, to url: URL) throws {
  try Data(repeating: 0x5A, count: bytes).write(to: url)
}
