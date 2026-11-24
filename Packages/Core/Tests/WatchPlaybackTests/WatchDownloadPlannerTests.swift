import ABSApi
import Foundation
import Testing
import WatchPlayback
import WatchProtocol

@Suite("Watch download planning")
struct WatchDownloadPlannerTests {
  @Test("book plans every validated audio file as one complete group")
  func plansAllBookFiles() throws {
    let detail = ItemDetail(
      id: "book-1", libraryID: "library", mediaType: "book",
      media: .book(
        BookMedia(
          title: "Book", subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil,
          description: nil, duration: 300,
          audioFiles: AudioFileCatalog(
            files: [
              AudioFileInfo(index: 1, ino: "two", expectedSize: 20, mimeType: "audio/mpeg", duration: 100),
              AudioFileInfo(index: 0, ino: "one", expectedSize: 10, mimeType: "audio/mpeg", duration: 200),
            ], invalidEntryCount: 0),
          tracks: [
            AudioTrack(
              index: 0, startOffset: 0, duration: 200, title: "Part One", contentUrl: nil, mimeType: "audio/mpeg"),
            AudioTrack(
              index: 1, startOffset: 200, duration: 100, title: "Part Two", contentUrl: nil, mimeType: "audio/mpeg"),
          ],
          chapters: [
            .init(id: 0, start: 0, end: 100, title: "Opening"), .init(id: 1, start: 100, end: 300, title: "Ending"),
          ], ebookFile: nil)))

    let plan = try WatchDownloadPlanner.plan(for: detail)
    #expect(plan.map(\.fileIndex) == [0, 1])
    // The descriptor title names the player, so it is the book's, never a per-file track name.
    #expect(plan.map(\.title) == ["Book", "Book"])
    #expect(plan.allSatisfy { $0.downloadGroupID == "book-1" && $0.expectedTrackCount == 2 })
    #expect(plan[1].startOffset == 200)
    #expect(plan[0].chapters.count == 2)
    #expect(plan[0].chapters[1].start == 100)
    #expect(plan[1].chapters.isEmpty)
  }

  @Test("a track named after its file never titles the book")
  func fileNamedTrackDoesNotTitleBook() throws {
    func detail(title: String?) -> ItemDetail {
      ItemDetail(
        id: "provenance", libraryID: "library", mediaType: "book",
        media: .book(
          BookMedia(
            title: title, subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil,
            description: nil, duration: 100,
            audioFiles: AudioFileCatalog(
              files: [AudioFileInfo(index: 0, ino: "one", expectedSize: 10, mimeType: "audio/mp4", duration: 100)],
              invalidEntryCount: 0),
            tracks: [
              AudioTrack(
                index: 0, startOffset: 0, duration: 100, title: "Provenance.m4b", contentUrl: nil,
                mimeType: "audio/mp4")
            ],
            chapters: [], ebookFile: nil)))
    }
    #expect(try WatchDownloadPlanner.plan(for: detail(title: "Provenance")).map(\.title) == ["Provenance"])
    // With no book title, the track's name is all there is; its file extension is not part of it.
    #expect(try WatchDownloadPlanner.plan(for: detail(title: nil)).map(\.title) == ["Provenance"])
  }

  @Test("book files without track metadata receive cumulative offsets")
  func plansBookFilesWithoutTrackRows() throws {
    let detail = ItemDetail(
      id: "book-fallback", libraryID: "library", mediaType: "book",
      media: .book(
        BookMedia(
          title: "Fallback Book", subtitle: nil, authorName: nil, narratorName: nil,
          seriesName: nil, description: nil, duration: 210,
          audioFiles: AudioFileCatalog(
            files: [
              AudioFileInfo(index: 1, ino: "part-two", expectedSize: 20, mimeType: "audio/mpeg", duration: 120),
              AudioFileInfo(index: 0, ino: "part-one", expectedSize: 10, mimeType: "audio/mpeg", duration: 90),
            ], invalidEntryCount: 0),
          tracks: [], chapters: [], ebookFile: nil)))

    let plan = try WatchDownloadPlanner.plan(for: detail)
    #expect(plan.map(\.fileIndex) == [0, 1])
    #expect(plan.map(\.startOffset) == [0, 90])
    #expect(plan.map(\.duration) == [90, 120])
    #expect(plan.allSatisfy { $0.title == "Fallback Book" })
  }

  @Test("book plans reject any invalid source audio entry")
  func rejectsInvalidSourceEntry() {
    let detail = ItemDetail(
      id: "book-invalid", libraryID: "library", mediaType: "book",
      media: .book(
        BookMedia(
          title: "Invalid Book", subtitle: nil, authorName: nil, narratorName: nil,
          seriesName: nil, description: nil, duration: 90,
          audioFiles: AudioFileCatalog(
            files: [
              AudioFileInfo(index: 0, ino: "part-one", expectedSize: 10, mimeType: "audio/mpeg", duration: 90)
            ], invalidEntryCount: 1),
          tracks: [], chapters: [], ebookFile: nil)))

    #expect(throws: WatchDownloadPlanningError.noAudioFiles) {
      try WatchDownloadPlanner.plan(for: detail)
    }
  }

  @Test("podcast planning skips episodes without a validated stored file")
  func skipsUnstoredPodcastEpisode() throws {
    let detail = ItemDetail(
      id: "show-1", libraryID: nil, mediaType: "podcast",
      media: .podcast(
        PodcastMedia(
          title: "Show", author: nil, description: nil,
          episodes: [
            PodcastEpisode(
              id: "episode-1", title: "Stored", contentUrl: nil, mimeType: "audio/mpeg",
              duration: 60, publishedAt: nil,
              audioFile: PodcastEpisodeAudio(ino: "stored", expectedSize: 30, mimeType: "audio/mpeg", duration: 60)),
            PodcastEpisode(
              id: "episode-2", title: "Remote", contentUrl: "https://example.invalid/a.mp3",
              mimeType: "audio/mpeg", duration: 60, publishedAt: nil),
          ])))

    let plan = try WatchDownloadPlanner.plan(for: detail)
    #expect(plan.count == 1)
    #expect(plan.first?.selection == .audiobookshelf(itemID: "show-1", episodeID: "episode-1"))
    #expect(plan.first?.expectedTrackCount == 1)
  }

  /// The show's other episodes are not this download's business: one with a missing size used to
  /// fail every episode of the show, on the wrist and from the phone alike.
  @Test("planning one episode ignores a malformed sibling")
  func plansTheRequestedEpisodeDespiteAMalformedSibling() throws {
    let detail = ItemDetail(
      id: "show-1", libraryID: nil, mediaType: "podcast",
      media: .podcast(
        PodcastMedia(
          title: "Show", author: nil, description: nil,
          episodes: [
            PodcastEpisode(
              id: "episode-1", title: "Broken", contentUrl: nil, mimeType: "audio/mpeg", duration: 60,
              publishedAt: nil,
              audioFile: PodcastEpisodeAudio(ino: "broken", expectedSize: 0, mimeType: "audio/mpeg", duration: 60)),
            PodcastEpisode(
              id: "episode-2", title: "Good", contentUrl: nil, mimeType: "audio/mpeg", duration: 60,
              publishedAt: nil,
              audioFile: PodcastEpisodeAudio(ino: "good", expectedSize: 30, mimeType: "audio/mpeg", duration: 60)),
          ])))

    #expect(throws: WatchDownloadPlanningError.missingSize) { try WatchDownloadPlanner.plan(for: detail) }
    let plan = try WatchDownloadPlanner.plan(for: detail, episodeID: "episode-2")
    #expect(plan.map(\.selection) == [.audiobookshelf(itemID: "show-1", episodeID: "episode-2")])
    #expect(throws: WatchDownloadPlanningError.missingSize) {
      try WatchDownloadPlanner.plan(for: detail, episodeID: "episode-1")
    }
    #expect(throws: WatchDownloadPlanningError.episodeNotFound) {
      try WatchDownloadPlanner.plan(for: detail, episodeID: "episode-3")
    }
  }

  @Test("a book is planned whole, and an episode identifier on a book fails closed")
  func aBookIgnoresNoEpisode() throws {
    let detail = ItemDetail(
      id: "book-1", libraryID: nil, mediaType: "book",
      media: .book(
        BookMedia(
          title: "Book", subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil, description: nil,
          duration: 60,
          audioFiles: AudioFileCatalog(
            files: [AudioFileInfo(index: 1, ino: "a", expectedSize: 10, mimeType: "audio/mpeg", duration: 60)],
            invalidEntryCount: 0),
          tracks: [], chapters: [], ebookFile: nil)))
    #expect(try WatchDownloadPlanner.plan(for: detail, episodeID: nil).count == 1)
    #expect(throws: WatchDownloadPlanningError.unsupportedMedia) {
      try WatchDownloadPlanner.plan(for: detail, episodeID: "episode-1")
    }
  }

  @Test("unsupported and empty details fail closed")
  func rejectsIncompleteDetails() {
    let noMedia = ItemDetail(id: "item", libraryID: nil, mediaType: nil, media: nil)
    #expect(throws: WatchDownloadPlanningError.unsupportedMedia) {
      try WatchDownloadPlanner.plan(for: noMedia)
    }
    let emptyBook = ItemDetail(
      id: "book", libraryID: nil, mediaType: "book",
      media: .book(
        BookMedia(
          title: nil, subtitle: nil, authorName: nil, narratorName: nil, seriesName: nil,
          description: nil, duration: nil, audioFiles: AudioFileCatalog(files: [], invalidEntryCount: 2),
          tracks: [], chapters: [], ebookFile: nil)))
    #expect(throws: WatchDownloadPlanningError.noAudioFiles) {
      try WatchDownloadPlanner.plan(for: emptyBook)
    }
  }
}
