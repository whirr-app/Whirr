import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// `HomeViewPresentation` derives section order, visibility and per-card values from
/// `HomeItem`, `HomeCopy` and `HomeRowPresentation` alone, so these tests need no rendering.
@Suite("Home view presentation")
struct HomeViewPresentationTests {

  @Test("Home and Podcasts share the compact filter-to-first-shelf rhythm")
  func browseRootsShareFirstShelfSpacing() {
    #expect(HomePodcastsBrowseLayout.filterBottomSpacing == WhirrSpacing.small)
    #expect(HomePodcastsBrowseLayout.firstShelfTopSpacing == WhirrSpacing.medium)
  }

  @Test("the browse page margin stays at the base until the window outgrows the page")
  func browsePageInsetCentresOnlyBeyondThePage() {
    let base = WhirrSpacing.medium
    let pageWidth = HomePodcastsBrowseLayout.pageMaxWidth
    func inset(_ width: CGFloat, _ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
      HomePodcastsBrowseLayout.pageInset(availableWidth: width, horizontalSizeClass: sizeClass)
    }
    #expect(inset(2000, .compact) == base)
    #expect(inset(2000, nil) == base)
    #expect(inset(0, .regular) == base)
    #expect(inset(.infinity, .regular) == base)
    // Every full-screen iPad, and a window of just the page plus its margins, runs edge to edge.
    for width in [CGFloat(744), 1032, 1376, pageWidth + 2 * base] {
      #expect(inset(width, .regular) == base)
    }
    #expect(inset(pageWidth + 2 * base + 200, .regular) == base + 100)
  }

  @Test("Home and the Podcasts root use one page margin, so their shared rail lines up")
  func homeAndPodcastsPageInsetsAgree() {
    #expect(HomePodcastsBrowseLayout.pageMaxWidth == PodcastsViewPresentation.pageMaxWidth)
    for width in stride(from: CGFloat(0), through: 3000, by: 125) {
      for sizeClass in [UserInterfaceSizeClass.compact, .regular, nil] {
        let podcasts = PodcastsViewPresentation.pageColumnInset(
          availableWidth: width, horizontalSizeClass: sizeClass)
        let home = HomePodcastsBrowseLayout.pageInset(
          availableWidth: width, horizontalSizeClass: sizeClass)
        #expect(podcasts == home)
      }
    }
  }

  @Test("Continue Listening dismissal springs the card away unless Reduce Motion is enabled")
  func continueListeningDismissalMotionRespectsReduceMotion() {
    #expect(
      HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: false) == .springAway)
    #expect(HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: true) == .fade)
  }

  @Test("Continue Listening card menus expose the removal accessibility identifier")
  func continueListeningCardMenuExposesRemovalAction() {
    for isEpisode in [false, true] {
      let row = ItemContextMenuPresentation.row(
        .removeFromContinueListening,
        context: ItemContextMenuPresentation.RowContext(
          isEpisode: isEpisode,
          playback: ItemContextMenuPresentation.playbackButton(
            isActiveItem: false, isPlaybackIntended: false)))

      #expect(row?.accessibilityIdentifier == HomeAccessibilityID.removeFromContinueListeningAction)
    }
  }

  @Test("Reduce Motion drops the shrink and shortens the animation")
  func continueListeningDismissalMotionShapes() {
    let spring = HomeViewPresentation.ContinueListeningDismissalMotion.springAway
    let fade = HomeViewPresentation.ContinueListeningDismissalMotion.fade
    #expect(spring.removalScale < 1)
    #expect(fade.removalScale == 1)
    #expect(spring.animation == .snappy(duration: 0.35))
    #expect(fade.animation == .easeOut(duration: 0.2))
  }

  private static func item(
    id: String = "item-1",
    title: String = "A Title",
    author: String? = "An Author",
    category: ItemMediaCategory = .audiobook,
    durationSeconds: Double? = 36_000,
    progressSeconds: Double = 18_000,
    ebookProgress: Double = 0,
    isFinished: Bool = false,
    addedAt: Date? = nil,
    isDownloaded: Bool = false,
    episodeID: String? = nil,
    episodeTitle: String? = nil
  ) -> HomeItem {
    HomeItem(
      serverItemId: id, title: title, author: author, category: category,
      durationSeconds: durationSeconds, progressSeconds: progressSeconds,
      ebookProgress: ebookProgress, isFinished: isFinished,
      addedAt: addedAt, isDownloaded: isDownloaded, episodeID: episodeID,
      episodeTitle: episodeTitle)
  }

  private static func episode(
    id: String = "ep-1", showID: String = "show-1", progressSeconds: Double = 0,
    isFinished: Bool = false
  ) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: showID, showTitle: "The Show", showAuthor: "Publisher", episodeID: id,
      title: "Episode \(id)", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      durationSeconds: 1_800, progressSeconds: progressSeconds, isFinished: isFinished)
  }

  private static func savedItem(
    id: String = "saved-item", category: ItemMediaCategory = .audiobook,
    title: String = "Saved Title", isUnavailable: Bool = false
  ) -> SavedShelfItem {
    let summary = ItemSummary(
      serverItemId: id, mediaKind: "book", title: title, author: "Saved Author",
      durationSeconds: 3_600, category: category)
    return SavedShelfItem(
      identity: .item(itemID: id), savedAt: Date(timeIntervalSince1970: 1_700_000_000),
      subjectTitle: title, contextTitle: nil, category: category, itemSummary: summary,
      episode: nil, isUnavailable: isUnavailable)
  }

  private static func savedEpisode(
    id: String = "saved-episode", showID: String = "saved-show", isUnavailable: Bool = false,
    progressSeconds: Double = 0, isFinished: Bool = false
  ) -> SavedShelfItem {
    let episode = Self.episode(
      id: id, showID: showID, progressSeconds: progressSeconds, isFinished: isFinished)
    return SavedShelfItem(
      identity: .podcastEpisode(itemID: episode.itemID, episodeID: episode.episodeID),
      savedAt: Date(timeIntervalSince1970: 1_700_000_000), subjectTitle: episode.title,
      contextTitle: episode.showTitle, category: .podcast, itemSummary: nil, episode: episode,
      isUnavailable: isUnavailable)
  }

  // MARK: - Section order / visibility

  @Test("the filter row keeps the same bottom spacing when the first shelf loads")
  func filterRowSpacingDoesNotShiftAfterInitialLoad() {
    let loadingElements = HomeViewPresentation.contentElements(
      state: .loading,
      continueListening: [],
      recentlyAdded: [],
      downloaded: [])
    let loadedElements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [Self.item()],
      recentlyAdded: [],
      downloaded: [])

    let loadingSpacing = HomeViewPresentation.rowBottomSpacing(
      for: loadingElements[0].kind, isLast: true)
    let loadedSpacing = HomeViewPresentation.rowBottomSpacing(
      for: loadedElements[0].kind, isLast: false)

    #expect(loadingSpacing == loadedSpacing)
    #expect(loadedSpacing == 0)
  }

  @Test("a podcast in Downloaded deep-links to the show's Downloaded filter")
  func downloadedPodcastSelectionCarriesDownloadedFilter() {
    #expect(
      HomeViewPresentation.podcastShowFilter(for: .podcast, in: .downloaded) == .downloaded)
    #expect(
      HomeViewPresentation.podcastShowFilter(for: .podcast, in: .continueListening) == nil)
    #expect(
      HomeViewPresentation.podcastShowFilter(for: .audiobook, in: .downloaded) == nil)
  }

  @Test("Continue Reading cards open the reader")
  func continueReadingCardsOpenReader() {
    #expect(HomeViewPresentation.cardOpensReader(for: .continueReading))
    #expect(HomeViewPresentation.cardOpensReader(for: .continueListening) == false)
    #expect(HomeViewPresentation.cardOpensReader(for: .continueSeries) == false)
    #expect(HomeViewPresentation.cardOpensReader(for: .downloaded) == false)
    #expect(HomeViewPresentation.cardOpensReader(for: .recentlyAdded) == false)
  }

  @Test("Continue Listening cards resume playback")
  func continueListeningCardsResumePlayback() {
    #expect(HomeViewPresentation.cardResumesPlayback(for: .audiobook, in: .continueListening))
    #expect(HomeViewPresentation.cardResumesPlayback(for: .podcast, in: .continueListening))
    #expect(
      HomeViewPresentation.cardResumesPlayback(for: .ebook, in: .continueListening) == false)
    #expect(HomeViewPresentation.cardResumesPlayback(for: .audiobook, in: .continueSeries) == false)
    #expect(HomeViewPresentation.cardResumesPlayback(for: .audiobook, in: .downloaded) == false)
    #expect(HomeViewPresentation.cardResumesPlayback(for: .audiobook, in: .recentlyAdded) == false)
    #expect(HomeViewPresentation.cardResumesPlayback(for: .ebook, in: .continueReading) == false)
  }

  @Test("shelves follow the order the reader dragged them into")
  func shelvesFollowTheStoredOrder() {
    let order = HomeSectionOrder.stored([
      .downloaded, .newEpisodes, .recentlyAdded, .continueListening, .continueSeries,
    ])
    let elements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [Self.item(id: "cl")],
      // Absent from `order`: a shelf the stored preference has never heard of still appears,
      // appended in `HomeMoreSection.allCases` order behind the listed ones.
      continueReading: [Self.item(id: "cr", category: .ebook)],
      continueSeries: [Self.item(id: "cs")],
      recentlyAdded: [Self.item(id: "ra")],
      newPodcastEpisodes: [Self.episode()],
      downloaded: [Self.item(id: "dl")],
      savedForLater: [Self.savedItem()],
      filter: .all,
      sectionOrder: order)
    #expect(
      elements.map(\.kind) == [
        .filter, .section(.downloaded), .section(.newEpisodes), .section(.recentlyAdded),
        .section(.continueListening), .section(.continueSeries), .section(.continueReading),
        .section(.savedForLater),
      ])
  }

  @Test("a reordered shelf that is empty or hidden still drops out")
  func reorderingDoesNotResurrectEmptyOrHiddenShelves() {
    let order = HomeSectionOrder.stored([.downloaded, .recentlyAdded, .continueListening])
    let elements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [Self.item(id: "cl")],
      continueSeries: [],
      recentlyAdded: [Self.item(id: "ra")],
      newPodcastEpisodes: [Self.episode()],
      downloaded: [Self.item(id: "dl")],
      filter: .all,
      hiddenSections: [.newEpisodes],
      sectionOrder: order)
    #expect(
      elements.map(\.kind) == [
        .filter, .section(.downloaded), .section(.recentlyAdded), .section(.continueListening),
      ])
  }

  @Test("sections the reader hid in Settings are dropped without disturbing the rest")
  func hiddenSectionsAreDropped() {
    let hidden = HomeSectionVisibility.stored(hidden: [.recentlyAdded, .downloaded])
    let elements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [Self.item(id: "cl")],
      continueSeries: [Self.item(id: "cs")],
      recentlyAdded: [Self.item(id: "ra")],
      newPodcastEpisodes: [Self.episode()],
      downloaded: [Self.item(id: "dl")],
      filter: .all,
      hiddenSections: HomeSectionVisibility.hidden(in: hidden))
    #expect(
      elements.map(\.kind) == [
        .filter, .section(.continueListening), .section(.continueSeries), .section(.newEpisodes),
      ])
  }

  @Test("hiding every section leaves the filter row and nothing else")
  func hidingEverythingLeavesOnlyTheFilter() {
    let elements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [Self.item(id: "cl")],
      continueSeries: [Self.item(id: "cs")],
      recentlyAdded: [Self.item(id: "ra")],
      newPodcastEpisodes: [Self.episode()],
      downloaded: [Self.item(id: "dl")],
      filter: .all,
      hiddenSections: Set(HomeMoreSection.allCases))
    #expect(elements.map(\.kind) == [.filter])
  }

  @Test("each filter keeps only its relevant shelves in stable order")
  func eachFilterKeepsRelevantShelvesInStableOrder() {
    let expected: [MediaFilter: [HomeMoreSection]] = [
      .all: [
        .continueListening, .continueReading, .continueSeries, .newEpisodes, .recentlyAdded,
        .downloaded, .savedForLater,
      ],
      .audiobooks: [
        .continueListening, .continueReading, .continueSeries, .recentlyAdded,
        .downloaded, .savedForLater,
      ],
      .podcasts: [.continueListening, .newEpisodes, .downloaded, .savedForLater],
      .ebooks: [
        .continueListening, .continueReading, .continueSeries, .recentlyAdded, .downloaded,
        .savedForLater,
      ],
    ]
    for filter in MediaFilter.allCases {
      let elements = HomeViewPresentation.contentElements(
        state: .loaded,
        continueListening: [Self.item(id: "cl")],
        continueReading: [Self.item(id: "cr", category: .ebook)],
        continueSeries: [Self.item(id: "cs")],
        recentlyAdded: [Self.item(id: "ra")],
        newPodcastEpisodes: [Self.episode()],
        downloaded: [Self.item(id: "dl")],
        savedForLater: [Self.savedItem()],
        filter: filter
      )

      #expect(
        elements.map(\.kind)
          == [.filter]
          + (expected[filter] ?? []).map {
            HomeViewPresentation.ContentElement.Kind.section($0)
          })
    }
  }

  @Test("the podcasts filter fills the middle section with episodes, titled Latest Episodes")
  func podcastsFilterFillsTheMiddleSectionWithEpisodes() {
    let episode = Self.episode()
    let sections = HomeViewPresentation.sections(
      continueListening: [],
      recentlyAdded: [Self.item(id: "show")],
      newPodcastEpisodes: [episode],
      downloaded: [],
      filter: .podcasts
    )

    #expect(sections.map(\.kind) == [.newEpisodes])
    #expect(sections[0].title == HomeCopy.latestEpisodesTitle)
    #expect(sections[0].content == .podcastEpisodes([episode]))
    // The shows the model happens to still hold are never rendered under this filter.
    #expect(sections[0].items.isEmpty)
  }

  @Test("a podcasts filter with no new episodes omits the middle section rather than showing shows")
  func podcastsFilterWithNoEpisodesOmitsTheMiddleSection() {
    let sections = HomeViewPresentation.sections(
      continueListening: [Self.item(id: "cl")],
      recentlyAdded: [Self.item(id: "show")],
      newPodcastEpisodes: [],
      downloaded: [],
      filter: .podcasts
    )

    #expect(sections.map(\.kind) == [.continueListening])
  }

  @Test("audiobook and ebook filters keep the item-level Recently Added section and its title")
  func nonPodcastFiltersKeepRecentlyAdded() {
    for filter in [MediaFilter.audiobooks, .ebooks] {
      let sections = HomeViewPresentation.sections(
        continueListening: [],
        recentlyAdded: [Self.item(id: "ra")],
        newPodcastEpisodes: [Self.episode()],
        downloaded: [],
        filter: filter
      )

      #expect(sections.map(\.kind) == [.recentlyAdded])
      #expect(sections[0].title == HomeCopy.recentlyAddedTitle)
      #expect(sections[0].items.map(\.id) == ["ra"])
    }
  }

  @Test("the All filter presents every shelf in its fixed order")
  func allFilterPresentsEveryShelfInFixedOrder() {
    let sections = HomeViewPresentation.sections(
      continueListening: [Self.item(id: "cl")],
      continueReading: [Self.item(id: "cr", category: .ebook)],
      continueSeries: [Self.item(id: "cs")],
      recentlyAdded: [Self.item(id: "ra")],
      newPodcastEpisodes: [Self.episode()],
      downloaded: [Self.item(id: "dl")],
      savedForLater: [Self.savedItem()]
    )
    #expect(
      sections.map(\.kind)
        == [
          .continueListening, .continueReading, .continueSeries, .newEpisodes, .recentlyAdded,
          .downloaded, .savedForLater,
        ])
    #expect(
      sections.map(\.title) == [
        HomeCopy.continueListeningTitle, HomeCopy.continueReadingTitle,
        HomeCopy.continueSeriesTitle,
        HomeCopy.latestEpisodesTitle, HomeCopy.recentlyAddedTitle, HomeCopy.downloadedTitle,
        HomeCopy.savedForLaterTitle,
      ])
  }

  @Test("Saved for Later appears for every filter and is omitted when empty")
  func savedForLaterFollowsEveryFilterAndOmitsEmptyContent() {
    let entry = Self.savedItem()
    for filter in MediaFilter.allCases {
      let sections = HomeViewPresentation.sections(
        continueListening: [], recentlyAdded: [], downloaded: [], savedForLater: [entry],
        filter: filter)
      #expect(sections.map(\.kind) == [.savedForLater])
      #expect(sections[0].content == .savedEntries([entry]))
    }

    let empty = HomeViewPresentation.sections(
      continueListening: [], recentlyAdded: [], downloaded: [], savedForLater: [])
    #expect(empty.isEmpty)
  }

  @Test("Latest Episodes always opens the canonical podcast destination")
  func latestEpisodesUsesCanonicalDestination() {
    #expect(
      HomeViewPresentation.detailRoute(for: .newEpisodes, selectedFilter: .all)
        == .latestEpisodes)
    #expect(
      HomeViewPresentation.detailRoute(for: .newEpisodes, selectedFilter: .podcasts)
        == .latestEpisodes)
    #expect(
      HomeViewPresentation.detailRoute(for: .recentlyAdded, selectedFilter: .all)
        == .homeMore(section: .recentlyAdded, filter: .all))
    #expect(
      HomeViewPresentation.detailRoute(for: .savedForLater, selectedFilter: .podcasts)
        == .homeMore(section: .savedForLater, filter: .podcasts))
  }

  @Test("the Podcasts Continue Listening heading resolves to Home's podcast-filtered route")
  func podcastsContinueListeningHeadingMatchesHome() {
    // `PodcastsView` hands this heading to the shell's `.podcastContinueListening` callback and
    // ignores the shelf's route, which is only safe while the two are equal.
    #expect(
      HomeViewPresentation.detailRoute(for: .continueListening, selectedFilter: .podcasts)
        == .podcastContinueListening)
  }

  @Test("Home readiness includes the shared Latest Episodes model")
  func homeReadinessIncludesLatestEpisodes() {
    #expect(
      HomeViewPresentation.pageState(
        home: .empty, latestEpisodes: .loaded, filter: .all) == .loaded)
    #expect(
      HomeViewPresentation.pageState(
        home: .empty, latestEpisodes: .empty, filter: .all) == .empty)
    #expect(
      HomeViewPresentation.pageState(
        home: .loaded, latestEpisodes: .loading, filter: .podcasts) == .loading)
    #expect(
      HomeViewPresentation.pageState(
        home: .loaded, latestEpisodes: .loading, filter: .audiobooks) == .loaded)
  }

  @Test("an empty section is omitted entirely, not rendered blank")
  func emptySectionIsOmitted() {
    let sections = HomeViewPresentation.sections(
      continueListening: [],
      recentlyAdded: [Self.item(id: "ra")],
      downloaded: [Self.item(id: "dl")]
    )
    #expect(sections.map(\.kind) == [.recentlyAdded, .downloaded])
  }

  @Test("every section empty yields no sections at all")
  func allSectionsEmptyYieldsNoSections() {
    let sections = HomeViewPresentation.sections(continueListening: [], recentlyAdded: [], downloaded: [])
    #expect(sections.isEmpty)
  }

  @Test("section item order is preserved, not re-sorted")
  func sectionItemOrderIsPreserved() {
    let items = [Self.item(id: "a"), Self.item(id: "b"), Self.item(id: "c")]
    let sections = HomeViewPresentation.sections(continueListening: items, recentlyAdded: [], downloaded: [])
    #expect(sections[0].items.map(\.id) == ["a", "b", "c"])
  }

  @Test("loaded scroll content starts with the filter and includes the downloads section")
  func loadedScrollContentStartsWithFilterAndIncludesDownloads() {
    let elements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [Self.item(id: "cl")],
      recentlyAdded: [Self.item(id: "ra")],
      downloaded: [Self.item(id: "dl")]
    )

    #expect(
      elements.map(\.kind) == [
        .filter,
        .section(.continueListening),
        .section(.recentlyAdded),
        .section(.downloaded),
      ])
  }

  @Test("the filter remains the first scroll element when downloads are the only home row")
  func loadedScrollContentWithOnlyDownloads() {
    let elements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [],
      recentlyAdded: [],
      downloaded: [Self.item(id: "dl")]
    )

    #expect(elements.map(\.kind) == [.filter, .section(.downloaded)])
  }

  @Test("a filter that matches nothing keeps the filter row in the same scroll content")
  func nonLoadedStatesKeepTheFilterInTheSameContent() {
    for state in [HomeModel.State.loading, .empty] {
      // Still-held contents from the previous filter must not surface under the placeholder.
      let elements = HomeViewPresentation.contentElements(
        state: state,
        continueListening: [Self.item(id: "cl")],
        recentlyAdded: [Self.item(id: "ra")],
        downloaded: [Self.item(id: "dl")],
        filter: .ebooks
      )

      #expect(elements.map(\.kind) == [.filter])
    }
  }

  @Test("only a non-loaded state raises a placeholder, and it names that state")
  func placeholderNamesTheNonLoadedState() {
    #expect(HomeViewPresentation.placeholder(for: .loading, hasWaitedForContent: true) == .loading)
    #expect(HomeViewPresentation.placeholder(for: .empty, hasWaitedForContent: true) == .empty)
    #expect(HomeViewPresentation.placeholder(for: .loaded, hasWaitedForContent: true) == nil)
  }

  @Test("a loaded state carries its shelves")
  func loadedStateCarriesItsShelves() {
    let elements = HomeViewPresentation.contentElements(
      state: .loaded,
      continueListening: [Self.item(id: "cl")],
      recentlyAdded: [],
      downloaded: []
    )

    #expect(elements.map(\.kind) == [.filter, .section(.continueListening)])
  }

  @Test("only Continue Listening shows progress")
  func onlyContinueListeningShowsProgress() {
    #expect(HomeViewPresentation.Section.Kind.continueListening.showsProgress == true)
    #expect(HomeViewPresentation.Section.Kind.continueReading.showsProgress == true)
    #expect(HomeViewPresentation.Section.Kind.continueSeries.showsProgress == false)
    #expect(HomeViewPresentation.Section.Kind.newEpisodes.showsProgress == false)
    #expect(HomeViewPresentation.Section.Kind.recentlyAdded.showsProgress == false)
    #expect(HomeViewPresentation.Section.Kind.downloaded.showsProgress == false)
    #expect(HomeViewPresentation.Section.Kind.savedForLater.showsProgress == false)
  }

  @Test("Continue Reading renders the ebook badge and reader progress")
  func continueReadingCardUsesEbookPresentation() {
    let item = Self.item(category: .audiobook, progressSeconds: 0, ebookProgress: 0.25, isFinished: false)
    let card = HomeViewPresentation.card(
      for: item, showsProgress: HomeMoreSection.continueReading.showsProgress, usesEbookProgress: true)
    #expect(card.badgeKind == .ebook)
    #expect(card.badgeLabel == HomeRowPresentation.badgeLabel(for: .ebook))
    #expect(card.progressFraction == 0.25)
  }

  // MARK: - Podcast source mark

  @Test("a shelf mixing server shows with followed feeds marks only the server podcasts")
  func mixedShelfMarksTheServerPodcast() throws {
    let feedID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    let server = Self.item(id: "li_empire", category: .podcast)
    let feed = Self.item(id: feedID, category: .podcast)
    let book = Self.item(id: "li_book", category: .audiobook)
    let mixes = HomeViewPresentation.shelfMixesPodcastSources(items: [server, feed, book])
    #expect(mixes)
    #expect(
      HomeViewPresentation.card(for: server, showsProgress: false, surfaceMixesSources: mixes)
        .sourceMark == .server)
    #expect(
      HomeViewPresentation.card(for: feed, showsProgress: false, surfaceMixesSources: mixes)
        .sourceMark == nil)
    #expect(
      HomeViewPresentation.card(for: book, showsProgress: false, surfaceMixesSources: mixes)
        .sourceMark == nil)
  }

  @Test("a shelf of one podcast source marks nothing")
  func unmixedShelfMarksNothing() {
    let items = [Self.item(id: "li_a", category: .podcast), Self.item(id: "li_b", category: .podcast)]
    let mixes = HomeViewPresentation.shelfMixesPodcastSources(items: items)
    #expect(mixes == false)
    #expect(
      HomeViewPresentation.card(for: items[0], showsProgress: false, surfaceMixesSources: mixes)
        .sourceMark == nil)
  }

  @Test("episode and saved cards mark provenance the same way item cards do")
  func episodeAndSavedCardsCarryTheMark() throws {
    let feedShowID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    let serverEpisode = Self.episode(id: "ep-1", showID: "li_empire")
    let feedEpisode = Self.episode(id: "ep-2", showID: feedShowID)
    #expect(
      HomeViewPresentation.episodeCard(for: serverEpisode, surfaceMixesSources: true).sourceMark
        == .server)
    #expect(
      HomeViewPresentation.episodeCard(for: feedEpisode, surfaceMixesSources: true).sourceMark
        == nil)
    #expect(
      HomeViewPresentation.savedCard(
        for: Self.savedEpisode(id: "ep-3", showID: "li_empire"), surfaceMixesSources: true
      ).sourceMark == .server)
    // An audiobook is never followed from a feed, so a saved book stays unmarked on a mixed shelf.
    #expect(
      HomeViewPresentation.savedCard(for: Self.savedItem(), surfaceMixesSources: true).sourceMark
        == nil)
  }

  @Test("a shelf's mixing is decided over the podcasts it holds, episodes included")
  func episodeShelfMixingReadsShowIdentities() throws {
    let feedShowID = try #require(PodcastSourceIdentity.rss(feedId: 17)).itemId
    #expect(
      HomeViewPresentation.shelfMixesPodcastSources(
        episodes: [Self.episode(showID: "li_empire"), Self.episode(showID: feedShowID)]))
    #expect(
      HomeViewPresentation.shelfMixesPodcastSources(
        episodes: [Self.episode(showID: "li_empire")]) == false)
  }

  @Test("Home covers use a fixed square frame regardless of artwork aspect ratio")
  func homeCoverFrameIsSquare() {
    #expect(HomeViewPresentation.coverFrame(forWidth: 140) == CGSize(width: 140, height: 140))
  }

  @Test("a resolved regular shelf width still derives a square cover frame")
  func homeResolvedShelfCoverFrameIsSquare() {
    let layout = HomeViewPresentation.ShelfLayout.resolve(
      horizontalSizeClass: .regular, availableWidth: 802, isAccessibilitySize: false)
    let frame = HomeViewPresentation.coverFrame(forWidth: layout.drawnCoverWidth)

    #expect(frame == CGSize(width: layout.drawnCoverWidth, height: layout.drawnCoverWidth))
  }

  // MARK: - category → MediaKindBadge mapping

  @Test("every media category maps to its own badge kind, 1:1")
  func categoryMapsToBadgeKind() {
    #expect(HomeViewPresentation.badgeKind(for: .audiobook) == .audiobook)
    #expect(HomeViewPresentation.badgeKind(for: .podcast) == .podcast)
    #expect(HomeViewPresentation.badgeKind(for: .ebook) == .ebook)
  }

  @Test("every ItemMediaCategory case has a mapping")
  func everyCategoryHasAMapping() {
    let mapped = ItemMediaCategory.allCases.map(HomeViewPresentation.badgeKind(for:))
    #expect(mapped.count == ItemMediaCategory.allCases.count)
    #expect(Set(mapped).count == ItemMediaCategory.allCases.count)
  }

  // MARK: - card: caption/fraction sourced from HomeRowPresentation, never re-derived

  @Test("a progress-showing card's fraction and caption exactly match HomeRowPresentation")
  func progressCardMatchesHomeRowPresentation() {
    let item = Self.item(
      category: .audiobook, durationSeconds: 36_000, progressSeconds: 18_000, isFinished: false)
    let card = HomeViewPresentation.card(for: item, showsProgress: true, playbackRate: 1.15)

    let expectedFraction = HomeRowPresentation.progressFraction(
      progressSeconds: item.progressSeconds, durationSeconds: item.durationSeconds)
    let expectedCaption = HomeRowPresentation.remainingCaption(
      progressSeconds: item.progressSeconds, durationSeconds: item.durationSeconds,
      isFinished: item.isFinished, category: item.category, playbackRate: 1.15)

    #expect(card.progressFraction == expectedFraction)
    #expect(card.trailingCaption == expectedCaption)
    #expect(card.badgeLabel == HomeRowPresentation.badgeLabel(for: item.category))
  }

  @Test("a podcast progress card uses its stored snapshot")
  func podcastProgressCardUsesStoredSnapshot() {
    let item = Self.item(
      category: .podcast, durationSeconds: 3_600, progressSeconds: 2_400, isFinished: false)
    let card = HomeViewPresentation.card(for: item, showsProgress: true)

    #expect(card.progressFraction == 2.0 / 3.0)
    #expect(card.trailingCaption == "20m left")
  }

  @Test("a progress-showing card changes its countdown when playback rate changes")
  func progressCardAccountsForPlaybackRate() {
    let item = Self.item(
      category: .audiobook, durationSeconds: 80 * 3600, progressSeconds: 0, isFinished: false)
    let normal = HomeViewPresentation.card(
      for: item, showsProgress: true, playbackRate: 1.0
    ).trailingCaption
    let faster = HomeViewPresentation.card(
      for: item, showsProgress: true, playbackRate: 1.15
    ).trailingCaption

    #expect(normal == "80h 0m left")
    #expect(faster == "69h 34m left")
  }

  @Test("a nil-duration item's card carries no progress fraction (no divide-by-zero path)")
  func nilDurationCardHasNoFraction() {
    let item = Self.item(durationSeconds: nil, progressSeconds: 1_200)
    let card = HomeViewPresentation.card(for: item, showsProgress: true)
    #expect(card.progressFraction == nil)
  }

  @Test("a non-progress section's card suppresses fraction and caption regardless of item data")
  func nonProgressSectionSuppressesFractionAndCaption() {
    let item = Self.item(durationSeconds: 36_000, progressSeconds: 18_000, isFinished: false)
    let card = HomeViewPresentation.card(for: item, showsProgress: false)
    #expect(card.progressFraction == nil)
    #expect(card.trailingCaption == nil)
  }

  @Test("a finished item's card is marked finished on every shelf, progress-showing or not")
  func finishedItemCardCarriesTheFinishedMark() {
    let finished = Self.item(durationSeconds: 36_000, progressSeconds: 36_000, isFinished: true)

    // Recently Added and Downloaded suppress the caption, so without this mark those shelves have
    // no way to say a title is done.
    #expect(
      HomeViewPresentation.card(for: finished, showsProgress: false).finishedLabel
        == ItemFinishedCopy.badgeLabel)
    #expect(
      HomeViewPresentation.card(for: finished, showsProgress: true).finishedLabel
        == ItemFinishedCopy.badgeLabel)
  }

  /// Done titles suppress the bar: the stored position would otherwise read as part-played, and a
  /// frozen bar contradicts the finished mark and caption. `HomeMoreItemRowPresentation` does the
  /// same.
  @Test("a finished item draws no bar, whatever position it was marked done at")
  func finishedItemCardDrawsNoProgressBar() {
    let markedDonePartway = Self.item(
      durationSeconds: 36_000, progressSeconds: 4_000, isFinished: true)
    let card = HomeViewPresentation.card(for: markedDonePartway, showsProgress: true)

    #expect(card.progressFraction == nil)
    #expect(card.trailingCaption == "Finished")
    #expect(card.finishedLabel == ItemFinishedCopy.badgeLabel)
  }

  @Test("a finished ebook draws no bar either")
  func finishedEbookCardDrawsNoProgressBar() {
    let markedDonePartway = Self.item(
      category: .ebook, durationSeconds: nil, progressSeconds: 0, ebookProgress: 0.3,
      isFinished: true)
    let card = HomeViewPresentation.card(
      for: markedDonePartway, showsProgress: true, usesEbookProgress: true)

    #expect(card.progressFraction == nil)
    #expect(card.trailingCaption == "Finished")
  }

  @Test("an unfinished item's card carries no finished mark")
  func unfinishedItemCardCarriesNoFinishedMark() {
    let item = Self.item(durationSeconds: 36_000, progressSeconds: 18_000, isFinished: false)
    #expect(HomeViewPresentation.card(for: item, showsProgress: true).finishedLabel == nil)
  }

  @Test("a started new episode carries its progress bar")
  func startedNewEpisodeCarriesItsProgressBar() {
    // New Episodes keeps started episodes with a minute or more left; only finished ones leave.
    let episode = Self.episode(progressSeconds: 600)
    let card = HomeViewPresentation.episodeCard(for: episode)

    #expect(card.progressFraction == HomePodcastEpisodePresentation(episode: episode).listening.progressFraction)
    #expect(card.progressFraction == 600.0 / 1_800.0)
    #expect(card.trailingCaption == HomePodcastEpisodePresentation(episode: episode).dateText)
  }

  @Test("a new-episode card carries no finished mark - the section filters finished episodes out")
  func newEpisodeCardCarriesNoFinishedMark() {
    #expect(HomeViewPresentation.episodeCard(for: Self.episode()).finishedLabel == nil)
  }

  @Test("card title/subtitle pass the item's own title/author through unchanged")
  func cardTitleSubtitlePassThrough() {
    let item = Self.item(title: "Some Book", author: "Some Author")
    let card = HomeViewPresentation.card(for: item, showsProgress: false)
    #expect(card.title == "Some Book")
    #expect(card.subtitle == "Some Author")
  }

  @Test("a podcast continuation card presents the episode over its parent show")
  func podcastContinuationPresentsEpisodeAndShow() {
    let item = Self.item(
      title: "The Show", author: "Publisher", category: .podcast,
      episodeID: "episode", episodeTitle: "The Episode")
    let card = HomeViewPresentation.card(for: item, showsProgress: true)
    #expect(card.title == "The Episode")
    #expect(card.subtitle == "The Show")
    #expect(card.usesItemContextMenu)
  }

  @Test("a podcast show card is offered its podcast-specific context menu")
  func podcastShowCardUsesItemContextMenu() {
    let showCard = HomeViewPresentation.card(
      for: Self.item(title: "The Show", category: .podcast), showsProgress: false)
    #expect(showCard.usesItemContextMenu)

    let bookCard = HomeViewPresentation.card(for: Self.item(), showsProgress: false)
    #expect(bookCard.usesItemContextMenu)
  }

  @Test("a new-episode card leads with the episode and captions it from the shared presentation")
  func newEpisodeCardLeadsWithTheEpisode() {
    let episode = Self.episode()
    let card = HomeViewPresentation.episodeCard(for: episode)
    let shared = HomePodcastEpisodePresentation(episode: episode)

    #expect(card.title == shared.title)
    #expect(card.subtitle == episode.showTitle)
    #expect(card.trailingCaption == shared.dateText)
    #expect(card.badgeKind == .podcast)
    #expect(card.progressFraction == nil)
    #expect(card.usesItemContextMenu)
  }

  @Test("a saved episode card has no New Episodes date caption")
  func savedEpisodeCardHasNoDateCaption() {
    let entry = Self.savedEpisode()
    let card = HomeViewPresentation.savedCard(for: entry)
    let episode = entry.episode!

    #expect(card.title == HomePodcastEpisodePresentation(episode: episode).title)
    #expect(card.subtitle == (entry.contextTitle ?? ""))
    #expect(card.progressFraction == nil)
    #expect(card.trailingCaption == nil)
    #expect(card.finishedLabel == nil)
    #expect(card.badgeKind == .podcast)
  }

  @Test("a started saved episode carries its progress bar")
  func startedSavedEpisodeCarriesItsProgressBar() {
    let card = HomeViewPresentation.savedCard(for: Self.savedEpisode(progressSeconds: 900))

    #expect(card.progressFraction == 0.5)
    #expect(card.finishedLabel == nil)
    #expect(card.trailingCaption == nil)
  }

  @Test("a finished saved episode carries the finished mark and no bar")
  func finishedSavedEpisodeCarriesTheFinishedMark() {
    // Saved for Later keeps an episode after it is played, unlike New Episodes.
    let card = HomeViewPresentation.savedCard(
      for: Self.savedEpisode(progressSeconds: 900, isFinished: true))

    #expect(card.finishedLabel == ItemFinishedCopy.badgeLabel)
    #expect(card.progressFraction == nil)
  }

  @Test("an episode shelf always holds the bar's line, so starting an episode never resizes it")
  func episodeShelfAlwaysReservesTheBarLine() {
    let unstarted = Self.episode(id: "a")
    let started = Self.episode(id: "b", progressSeconds: 600)

    #expect(HomeViewPresentation.shelfReservesProgressLine(episodes: [unstarted]))
    #expect(HomeViewPresentation.shelfReservesProgressLine(episodes: [unstarted, started]))
  }

  @Test("a saved shelf holds the bar's line only for a card that draws one")
  func savedShelfReservesTheBarLineOnlyForADrawnBar() {
    let finished = Self.savedEpisode(id: "a", progressSeconds: 900, isFinished: true)
    let started = Self.savedEpisode(id: "b", progressSeconds: 900)

    // A finished card draws no bar, so a shelf of them keeps its shorter cards.
    #expect(HomeViewPresentation.shelfReservesProgressLine(savedEntries: [finished]) == false)
    #expect(
      HomeViewPresentation.shelfReservesProgressLine(savedEntries: [Self.savedItem(), started]))
    #expect(HomeViewPresentation.shelfReservesProgressLine(savedEntries: [Self.savedItem()]) == false)
  }

  @Test("a saved whole-item card has no progress or caption and follows its category badge")
  func savedWholeItemCardSuppressesProgressAndUsesCategoryBadge() {
    let entry = Self.savedItem(category: .ebook)
    let card = HomeViewPresentation.savedCard(for: entry)

    #expect(card.title == entry.subjectTitle)
    #expect(card.subtitle == (entry.itemSummary?.author ?? ""))
    #expect(card.progressFraction == nil)
    #expect(card.trailingCaption == nil)
    #expect(card.finishedLabel == nil)
    #expect(card.badgeKind == .ebook)
    #expect(card.badgeLabel == HomeRowPresentation.badgeLabel(for: .ebook))
  }

  @Test("an unavailable saved whole item uses the unavailable subtitle")
  func unavailableSavedWholeItemUsesUnavailableSubtitle() {
    let card = HomeViewPresentation.savedCard(for: Self.savedItem(isUnavailable: true))
    #expect(card.subtitle == HomeCopy.savedItemUnavailable)
  }

  @Test("an unavailable saved episode uses the unavailable subtitle")
  func unavailableSavedEpisodeUsesUnavailableSubtitle() {
    let card = HomeViewPresentation.savedCard(for: Self.savedEpisode(isUnavailable: true))
    #expect(card.subtitle == PodcastCopy.unavailableOnServer)
  }

  /// Home's chrome (nav title, editorial background, tab bar) is already correct while its
  /// observations land, because the placeholder is an overlay, not a replacement. A cold launch
  /// that resolves promptly shows no loading copy. The spinner is for a wait long enough to need
  /// explaining.
  @Test("a short load shows no spinner, because the chrome around it is already right")
  func loadingRaisesNoPlaceholderUntilTheWaitIsWorthExplaining() {
    #expect(HomeViewPresentation.placeholder(for: .loading, hasWaitedForContent: false) == nil)
    #expect(HomeViewPresentation.placeholder(for: .loading, hasWaitedForContent: true) == .loading)
  }

  /// Empty is a terminal answer, not a wait, so it must never be withheld: a genuinely empty Home
  /// would otherwise render as a blank scroll view for the length of the delay.
  @Test("the empty state is an answer and is never delayed")
  func emptyIsNeverWithheld() {
    #expect(HomeViewPresentation.placeholder(for: .empty, hasWaitedForContent: false) == .empty)
  }

  @Test("a loaded Home raises no placeholder regardless of the delay")
  func loadedNeverRaisesAPlaceholder() {
    #expect(HomeViewPresentation.placeholder(for: .loaded, hasWaitedForContent: false) == nil)
    #expect(HomeViewPresentation.placeholder(for: .loaded, hasWaitedForContent: true) == nil)
  }

  /// Long enough that an ordinary launch never crosses it, short enough that a real stall is still
  /// explained rather than looking like a dead screen.
  @Test("the spinner delay is bounded at both ends")
  func theLoadingDelayIsBoundedAtBothEnds() {
    #expect(HomeViewPresentation.loadingPlaceholderDelay >= .milliseconds(200))
    #expect(HomeViewPresentation.loadingPlaceholderDelay <= .milliseconds(600))
  }

  @Test("a nil author falls back to an empty subtitle, not a placeholder string")
  func nilAuthorFallsBackToEmptySubtitle() {
    let item = Self.item(author: nil)
    let card = HomeViewPresentation.card(for: item, showsProgress: false)
    #expect(card.subtitle == "")
  }
}
