import Foundation
import GRDB
import Persistence
import Testing

@testable import SyncEngine

/// The five read-only podcast diagnostics are written only by the expanded show refresh
/// (`PodcastRefreshStore`). Neither the minified traversal nor a search hit carries them, so both
/// must leave a stored value in place rather than resetting it.
@Suite struct PodcastDiagnosticsPreservationTests {
  private static let lastEpisodeCheck = Date(timeIntervalSince1970: 1_750_000_300)

  @Test("a library traversal preserves the podcast diagnostics")
  func aTraversalPreservesPodcastDiagnostics() async throws {
    let h = try await Harness()
    let libraryRowId = try await seedShowWithDiagnostics(h)

    h.enqueueLibraries([(id: "podcast-library", name: "Podcasts", mediaType: "podcast")])
    h.enqueueEmptyProgress()
    h.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": "show-1",
              "libraryId": "irrelevant",
              "mediaType": "podcast",
              "media": [
                "metadata": ["title": "Traversed Show", "author": "Traversed Host"],
                "numEpisodes": 12,
              ],
            ]
          ],
          "total": 1,
          "limit": 100,
          "page": 0,
        ]))

    await h.engine.refresh()

    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "show-1"))
    #expect(item.title == "Traversed Show")
    expectDiagnosticsPreserved(item)
  }

  @Test("a search upsert preserves the podcast diagnostics")
  func aSearchUpsertPreservesPodcastDiagnostics() async throws {
    let h = try await Harness()
    let libraryRowId = try await seedShowWithDiagnostics(h)

    h.enqueueSearchResponse(
      book: [],
      podcast: [
        (id: "show-1", title: "Search Show", author: "Search Host", matchKey: "title", matchText: "Search Show")
      ])
    _ = try await h.engine.search(libraryIDs: ["podcast-library"], query: "search", limit: 25)

    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "show-1"))
    #expect(item.title == "Search Show")
    expectDiagnosticsPreserved(item)
  }

  private func seedShowWithDiagnostics(_ h: Harness) async throws -> Int64 {
    let library = try await h.seedLibrary(serverLibraryId: "podcast-library", mediaType: "podcast")
    let libraryRowId = try #require(library.id)
    var show = try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "show-1", generation: 1)
    show.mediaKind = "podcast"
    show.podcastAutoDownloadEpisodes = true
    show.podcastAutoDownloadSchedule = "0 * * * *"
    show.podcastLastEpisodeCheck = Self.lastEpisodeCheck
    show.podcastMaxEpisodesToKeep = 5
    show.podcastMaxNewEpisodesToDownload = 2
    try await h.database.writeAsync { [show] db in try show.update(db) }
    return libraryRowId
  }

  private func expectDiagnosticsPreserved(_ item: ItemRecord) {
    #expect(item.podcastAutoDownloadEpisodes == true)
    #expect(item.podcastAutoDownloadSchedule == "0 * * * *")
    #expect(item.podcastLastEpisodeCheck == Self.lastEpisodeCheck)
    #expect(item.podcastMaxEpisodesToKeep == 5)
    #expect(item.podcastMaxNewEpisodesToDownload == 2)
  }
}
