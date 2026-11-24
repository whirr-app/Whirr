import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Explicit library removal. `handleMissingLibrary` tombstones the library's items and must also
/// mark the `library` row, as `SyncEngine.search` fans out over every local row: a library deleted
/// on the server (or re-created under a new id) would otherwise 404 every search.
///
/// The row is tombstoned, not deleted: `library` cascades to `item` and `download`, so removal
/// would let the next `DownloadIntegritySweep` reclaim downloaded files over an inference one
/// server response can reverse.
@Suite("Library removal: tombstoned, not deleted, and never fanned out to again")
struct LibraryRemovalTests {

  @Test("a library the server stops listing is tombstoned, and disappears from the fan-out source")
  func missingLibraryIsTombstoned() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "gone", name: "Old Books")

    // The server lists only the other library, which is what deleting one and re-creating it
    // under a new id looks like from here.
    h.enqueueLibraries([(id: "kept", name: "Books", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    #expect(try h.fetchLibrary(serverLibraryId: "gone") == nil, "the tombstoned row must be hidden")
    #expect(try h.fetchLibrary(serverLibraryId: "kept") != nil)

    // Hidden, not destroyed: the items and any downloads under them survive the inference.
    let tombstoned = try #require(try h.fetchLibrary(serverLibraryId: "gone", includingRemoved: true))
    #expect(tombstoned.softDeleted)
  }

  @Test("a malformed library entry does not tombstone an absent local library")
  func malformedLibraryEntryDoesNotTombstoneAbsentLocalLibrary() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "gone", name: "Old Books")

    h.http.enqueue(
      Harness.jsonResponse(object: [
        "libraries": [
          ["id": "kept", "name": "Books", "mediaType": "book"],
          ["name": "Malformed", "mediaType": "book"],
        ]
      ]))
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    let local = try #require(try h.fetchLibrary(serverLibraryId: "gone", includingRemoved: true))
    #expect(local.softDeleted == false)
  }

  /// The reported failure, end to end: after the removal pass, a search must stop requesting the
  /// library that no longer exists: no request, so no `SearchLibraryFailure` and no banner.
  @Test("a tombstoned library is never searched again")
  func tombstonedLibraryIsNeverSearched() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "gone", name: "Old Books")

    h.enqueueLibraries([(id: "kept", name: "Books", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)
    await h.engine.refresh()

    h.enqueueSearchResponse(book: [], podcast: [])
    let result = try await h.engine.search(libraryIDs: nil, query: "dinniman", limit: 25)

    #expect(result.failures.isEmpty, "a library the server no longer has must not be requested")
    let searchedLibraryIDs = h.http.requests
      .filter { $0.url.path.hasSuffix("/search") }
      .compactMap { $0.url.pathComponents.dropLast().last }
    #expect(searchedLibraryIDs == ["kept"])
  }

  /// A server that blinked, or a library restored, must come back whole, reusing its own
  /// row so nothing under it is orphaned.
  @Test("a library the server lists again is live once more, on its original row")
  func reappearingLibraryIsRevived() async throws {
    let h = try await Harness()
    let seeded = try await h.seedLibrary(serverLibraryId: "blinked", name: "Books")

    h.enqueueLibraries([])
    await h.engine.refresh()
    #expect(try h.fetchLibrary(serverLibraryId: "blinked") == nil)

    h.enqueueLibraries([(id: "blinked", name: "Books", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)
    await h.engine.refresh()

    let revived = try #require(try h.fetchLibrary(serverLibraryId: "blinked"))
    #expect(revived.softDeleted == false)
    #expect(revived.id == seeded.id, "revival must reuse the row, not strand what hung off it")
  }
}
