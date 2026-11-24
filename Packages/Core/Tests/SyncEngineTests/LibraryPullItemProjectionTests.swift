import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// What a minified traversal page maps onto the stored `ItemRecord`: series, media signals, and
/// the preserve-on-absent fields an expanded item detail owns.
@Suite("Library pull: persisted item projection")
struct LibraryPullItemProjectionTests {

  // MARK: - addedAt/duration/media-signal mapping

  @Test("a library pull persists series from minified metadata")
  func libraryPullPersistsMinifiedSeries() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePageWithSeries(
      id: "item1", title: "The Fellowship of the Ring", author: "J. R. R. Tolkien",
      seriesName: "The Lord of the Rings")

    await h.engine.refresh()

    let library = try #require(try h.fetchLibrary(serverLibraryId: "lib1"))
    let libraryRowID = try #require(library.id)
    let item = try #require(
      try h.fetchItem(libraryRowId: libraryRowID, serverItemId: "item1"))
    #expect(item.seriesName == "The Lord of the Rings")
  }

  @Test("decoded minified metadata without a series clears the stored series")
  func libraryPullClearsSeriesWhenMetadataDecodedWithoutOne() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowID = try #require(library.id)
    _ = try await h.seedItem(
      libraryRowId: libraryRowID, serverItemId: "item1", generation: 1,
      seriesName: "Old Series")
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePageWithSeries(
      id: "item1", title: "Standalone", author: "Author", seriesName: nil)

    await h.engine.refresh()

    let item = try #require(
      try h.fetchItem(libraryRowId: libraryRowID, serverItemId: "item1"))
    #expect(item.seriesName == nil)
  }

  @Test("a payload with no metadata container preserves the stored series")
  func libraryPullPreservesSeriesWhenMetadataIsAbsentEntirely() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowID = try #require(library.id)
    _ = try await h.seedItem(
      libraryRowId: libraryRowID, serverItemId: "item1", generation: 1,
      seriesName: "Preserved Series")
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePageWithoutMediaMetadata(id: "item1")

    await h.engine.refresh()

    let item = try #require(
      try h.fetchItem(libraryRowId: libraryRowID, serverItemId: "item1"))
    #expect(item.seriesName == "Preserved Series")
  }

  @Test("a minified pull never clears expanded narrator state")
  func minifiedPullDoesNotClearExpandedNarrator() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowID = try #require(library.id)
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try await h.seedItem(
      libraryRowId: libraryRowID, serverItemId: "item1", generation: 1,
      seriesName: "Old Series", narratorName: "Julia Whelan",
      expandedMetadataFetchedAt: fetchedAt)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePageWithSeries(
      id: "item1", title: "Updated Title", author: "Updated Author",
      seriesName: "Updated Series")

    await h.engine.refresh()

    let item = try #require(
      try h.fetchItem(libraryRowId: libraryRowID, serverItemId: "item1"))
    #expect(item.seriesName == "Updated Series")
    #expect(item.narratorName == "Julia Whelan")
    #expect(item.expandedMetadataFetchedAt == fetchedAt)
  }

  /// The show synopsis only arrives on an expanded item detail, so the minified traversal carries
  /// no information about it. Same preserve-on-absent rule as `addedAt` and `narratorName`.
  @Test("a minified pull never clears a stored show description")
  func minifiedPullDoesNotClearShowDescription() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowID = try #require(library.id)
    _ = try await h.seedItem(
      libraryRowId: libraryRowID, serverItemId: "item1", generation: 1,
      itemDescription: "A show about shows")
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [(id: "item1", title: "Updated Title", author: "Updated Author")], total: 1,
      limit: 100, page: 0)

    await h.engine.refresh()

    let item = try #require(
      try h.fetchItem(libraryRowId: libraryRowID, serverItemId: "item1"))
    #expect(item.title == "Updated Title")
    #expect(item.itemDescription == "A show about shows")
  }

  @Test("a pull persists addedAt, duration, and media signals; the derived category matches ItemMediaCategory.derive")
  func pullPersistsAddedAtDurationAndMediaSignals() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePageWithMediaSignals(
      items: [
        (
          id: "item1", title: "Title One", author: "Author One", addedAtMs: 1_750_000_000_000,
          durationSeconds: 3_600, numAudioFiles: 4, ebookFormat: nil
        )
      ],
      total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    let library = try #require(try h.fetchLibrary(serverLibraryId: "lib1"))
    let libraryRowId = try #require(library.id)
    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1"))
    #expect(item.addedAt == Date(timeIntervalSince1970: 1_750_000_000))
    #expect(item.durationSeconds == 3_600)
    #expect(item.numAudioFiles == 4)
    #expect(item.ebookFormat == nil)
    let expectedCategory = ItemMediaCategory.derive(
      mediaKind: item.mediaKind, numAudioFiles: item.numAudioFiles, ebookFormat: item.ebookFormat)
    #expect(expectedCategory == .audiobook)
  }

  @Test("a full traversal page retains its complete item projection")
  func aFullTraversalPageRetainsItsCompleteItemProjection() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": "item1",
              "libraryId": "irrelevant",
              "mediaType": "book",
              "addedAt": 1_750_000_000_000,
              "updatedAt": 1_750_000_001_000,
              "media": [
                "metadata": [
                  "title": "The Full Traversal",
                  "authorName": "An Author",
                  "seriesName": "A Series",
                ],
                "duration": 3_600,
                "numAudioFiles": 2,
                "ebookFormat": "epub",
                "numEpisodes": 3,
                "coverPath": "/metadata/items/item1.jpg",
              ],
            ]
          ],
          "total": 1,
          "limit": 100,
          "page": 0,
        ]))

    await h.engine.refresh()

    let library = try #require(try h.fetchLibrary(serverLibraryId: "lib1"))
    let libraryRowId = try #require(library.id)
    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1"))
    #expect(item.mediaKind == "book")
    #expect(item.title == "The Full Traversal")
    #expect(item.sortTitle == "Full Traversal")
    #expect(item.author == "An Author")
    #expect(item.addedAt == Date(timeIntervalSince1970: 1_750_000_000))
    #expect(item.durationSeconds == 3_600)
    #expect(item.numAudioFiles == 2)
    #expect(item.ebookFormat == "epub")
    #expect(item.seriesName == "A Series")
    #expect(item.serverUpdatedAt == Date(timeIntervalSince1970: 1_750_000_001))
    #expect(item.podcastServerEpisodeCount == 3)
    #expect(item.hasServerArtwork == true)
    #expect(
      ItemMediaCategory.derive(
        mediaKind: item.mediaKind, numAudioFiles: item.numAudioFiles, ebookFormat: item.ebookFormat)
        == .audiobook)
  }

  @Test("a pull whose payload omits the new fields still syncs, leaving them nil and the category .audiobook")
  func pullWithoutNewFieldsLeavesThemNil() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title One", author: "Author One")], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    let library = try #require(try h.fetchLibrary(serverLibraryId: "lib1"))
    let libraryRowId = try #require(library.id)
    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1"))
    #expect(item.addedAt == nil)
    #expect(item.durationSeconds == nil)
    #expect(item.numAudioFiles == nil)
    #expect(item.ebookFormat == nil)
    let expectedCategory = ItemMediaCategory.derive(
      mediaKind: item.mediaKind, numAudioFiles: item.numAudioFiles, ebookFormat: item.ebookFormat)
    #expect(expectedCategory == .audiobook)
  }

  @Test("a second pull whose payload omits addedAt does not null out a previously-stored value")
  func repeatedPullDoesNotClobberAddedAt() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePageWithMediaSignals(
      items: [
        (
          id: "item1", title: "Title One", author: "Author One", addedAtMs: 1_750_000_000_000,
          durationSeconds: nil, numAudioFiles: nil, ebookFormat: nil
        )
      ],
      total: 1, limit: 100, page: 0)
    await h.engine.refresh()

    let library = try #require(try h.fetchLibrary(serverLibraryId: "lib1"))
    let libraryRowId = try #require(library.id)
    let afterFirst = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1"))
    #expect(afterFirst.addedAt == Date(timeIntervalSince1970: 1_750_000_000))

    // Bypass backoff pacing (not this test's concern) and trigger a second pull whose payload
    // shape has no addedAt field at all.
    h.clock.advance(by: 1000)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title One", author: "Author One")], total: 1, limit: 100, page: 0)
    await h.engine.refresh()

    let afterSecond = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1"))
    #expect(afterSecond.addedAt == Date(timeIntervalSince1970: 1_750_000_000))
  }
}
