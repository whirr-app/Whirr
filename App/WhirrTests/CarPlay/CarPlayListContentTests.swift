import ABSApi
import AppModel
import Foundation
import PlayerCore
import Testing

@testable import Whirr

/// What a car list shows, before any template exists.
@MainActor
@Suite struct CarPlayListContentTests {
  private static func snapshot(_ route: CarPlayBrowseRoute, _ rows: [CarPlayBrowseRow]?) -> CarPlayBrowseSnapshot {
    CarPlayBrowseSnapshot(generation: 1, route: route, content: rows.map { .rows($0) } ?? .loading)
  }

  @Test func loadingListSaysSoRatherThanLookingEmpty() {
    let content = CarPlayListContent.observed(Self.snapshot(.upNext, nil), maximumItemCount: 12)
    #expect(content == .loading)
    #expect(content.emptyTitle == "Loading")
  }

  @Test func emptyListUsesItsRoutesMessage() {
    let content = CarPlayListContent.observed(Self.snapshot(.upNext, []), maximumItemCount: 12)
    #expect(content.sections.isEmpty)
    #expect(content.emptyTitle == CarPlayBrowseRoute.upNext.emptyMessage)
  }

  @Test func leadingRowsStayWhileTheShelfLoadsOrIsEmpty() {
    let loading = CarPlayListContent.observed(
      Self.snapshot(.continueListening, nil), leading: [.resume], maximumItemCount: 12)
    let empty = CarPlayListContent.observed(
      Self.snapshot(.continueListening, []), leading: [.resume], maximumItemCount: 12)
    #expect(loading.sections.map(\.entries) == [[.resume]])
    #expect(empty.sections.map(\.entries) == [[.resume]])
    #expect(empty.emptyTitle == nil)
  }

  @Test func leadingRowsCountAgainstTheCarsLimit() {
    let rows = (1...10).map { CarPlayTestWorld.book("\($0)") }
    let content = CarPlayListContent.observed(
      Self.snapshot(.recentBooks, rows), leading: [.allBooks], header: "Recently Added", maximumItemCount: 6)

    #expect(content.sections.flatMap(\.entries).count == 6)
    #expect(content.rows == Array(rows.prefix(5)))
    #expect(content.sections.last?.header == CarPlayListContent.truncatedHeader)
  }

  @Test func wholeListKeepsItsOwnHeader() {
    let content = CarPlayListContent.observed(
      Self.snapshot(.recentBooks, [CarPlayTestWorld.book("a")]), leading: [.allBooks], header: "Recently Added",
      maximumItemCount: 6)
    #expect(content.sections.map(\.header) == [nil, "Recently Added"])
  }

  private static func shows(_ rows: [CarPlayBrowseRow]) async -> CarPlayPagedList {
    let list = CarPlayPagedList(route: .podcastShows) { _ in
      .page(CarPlayBrowsePage(generation: 1, route: .podcastShows, rows: rows, next: nil))
    }
    list.load()
    await list.settled()
    return list
  }

  @Test func podcastsLeadWithNewEpisodesThenTheShows() async {
    let episodes = (1...3).map { CarPlayTestWorld.episode("\($0)") }
    let shows = await Self.shows([CarPlayTestWorld.show("s")])

    let content = CarPlayListContent.podcasts(
      latest: Self.snapshot(.latestEpisodes, episodes), shows: shows, maximumItemCount: 12)

    #expect(content.sections.map(\.header) == ["New Episodes", "Your Shows"])
    #expect(content.rows == episodes + [CarPlayTestWorld.show("s")])
  }

  @Test func newEpisodesKeepToTheirShareSoTheShowsCanStillPage() async {
    let episodes = (1...10).map { CarPlayTestWorld.episode("\($0)") }
    let shows = await Self.shows((1...6).map { CarPlayTestWorld.show("\($0)") })

    let content = CarPlayListContent.podcasts(
      latest: Self.snapshot(.latestEpisodes, episodes), shows: shows, maximumItemCount: 12)

    let slots = CarPlayListContent.latestEpisodeSlots(maximumItemCount: 12)
    #expect(slots == 4)
    #expect(content.sections.map(\.entries.count) == [4, 6])
    #expect(content.sections.last?.header == "Your Shows")
    // A full page of shows and both page controls fit in what the episodes leave.
    #expect(CarPlayListLayout.pageSize(maximumItemCount: 12 - slots, productLimit: 100) == 6)
  }

  @Test func podcastsWithNothingNewAreJustTheShowsAndWithNoShowsJustTheEpisodes() async {
    let shows = await Self.shows([CarPlayTestWorld.show("s")])
    let none = await Self.shows([])

    let onlyShows = CarPlayListContent.podcasts(
      latest: Self.snapshot(.latestEpisodes, []), shows: shows, maximumItemCount: 12)
    let onlyEpisodes = CarPlayListContent.podcasts(
      latest: Self.snapshot(.latestEpisodes, [CarPlayTestWorld.episode("e")]), shows: none, maximumItemCount: 12)
    let nothing = CarPlayListContent.podcasts(
      latest: Self.snapshot(.latestEpisodes, []), shows: none, maximumItemCount: 12)

    #expect(onlyShows == .paged(shows, maximumItemCount: 12))
    #expect(onlyEpisodes.sections.map(\.header) == ["New Episodes"])
    #expect(onlyEpisodes.emptyTitle == nil)
    #expect(nothing.emptyTitle == CarPlayBrowseRoute.podcastShows.emptyMessage)
  }

  @Test func chaptersBeyondTheLimitKeepAWindowAroundTheCurrentOne() throws {
    let chapters = (0..<20).map {
      PlaybackChapter(title: "C\($0)", start: Double($0) * 10, end: Double($0 + 1) * 10)
    }
    let item = PlayerItem(
      id: "book", episodeID: nil,
      timeline: try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 200)]),
      chapters: PlaybackChapterMap(chapters: chapters))
    func window(at position: Double) throws -> [Int] {
      let state = PlayerState(phase: .playing, item: item, currentTrackIndex: 0, globalPosition: position, rate: 1)
      let list = CarPlayNowPlayingControls(state: state, effectiveRate: 1, presets: [1], generation: 1).chapters
      let content = CarPlayListContent.chapters(list, maximumItemCount: 6)
      #expect(content.sections.first?.header == CarPlayListContent.truncatedHeader)
      return content.sections.flatMap(\.entries).compactMap { if case .chapter(let row) = $0 { row.id } else { nil } }
    }

    #expect(try window(at: 5) == Array(0..<6))
    #expect(try window(at: 105) == Array(7..<13))
    #expect(try window(at: 195) == Array(14..<20))
  }

  @Test func noChaptersIsAnEmptyListNotACrash() {
    #expect(CarPlayListContent.chapters(nil, maximumItemCount: 6).emptyTitle == "No chapters")
  }

  // MARK: - Artwork keys

  private static let server = ArtworkSource.audiobookshelf(ArtworkAccountScope("server"))

  private static func key(_ reference: CarPlayArtworkReference, pixelSize: Int = 90) -> CarPlayArtworkKey {
    CarPlayArtworkKey(generation: 1, reference: reference, pixelSize: pixelSize, isDark: false)
  }

  @Test func rowWithoutArtworkHasNoPipelineKey() {
    #expect(CarPlayArtworkLoader.artworkKey(for: Self.key(.none), defaultSource: Self.server) == nil)
  }

  @Test func serverCoverIsAThumbnailOfTheSignedInServersItem() throws {
    let updated = Date(timeIntervalSince1970: 1_000)
    let key = try #require(
      CarPlayArtworkLoader.artworkKey(
        for: Self.key(.item(id: "book", updatedAt: updated), pixelSize: 180), defaultSource: Self.server))

    #expect(key.source == Self.server)
    #expect(key.itemID == "book")
    #expect(key.variant == .libraryThumbnail(pixelWidth: 180))
    #expect(key.revision == ArtworkRevision(serverUpdatedAt: updated))
  }

  @Test func serverCoverWithNoSignedInServerIsNotRequested() {
    let key = Self.key(.item(id: "book", updatedAt: nil))
    #expect(CarPlayArtworkLoader.artworkKey(for: key, defaultSource: nil) == nil)
  }
}
