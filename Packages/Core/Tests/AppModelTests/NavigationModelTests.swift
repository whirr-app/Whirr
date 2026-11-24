import Foundation
import Persistence
import Testing

@testable import AppModel

/// The shell has one deep-linkable navigation model (ARCHITECTURE.md §6). A section is a place
/// you are, a route is a place you pushed to. Sections never enter a path, each section keeps
/// its own stack, and deep links round-trip a `Destination` (section + path), not a bare route.
@Suite struct NavigationModelTests {
  @MainActor
  @Test("notification episode composes show push with episode sheet")
  func notificationEpisode() {
    let model = NavigationModel(presentation: .shell)
    model.expandPlayer()
    model.navigate(to: RSSNotificationResolvedDestination.episode(feedID: 4, identityKey: "e"))
    #expect(model.playerPresentation == .collapsed)
    #expect(model.section == .podcasts)
    #expect(model[pathFor: .podcasts] == [.podcastShow(itemID: "rss:4")])
    #expect(model.presentedEpisode == .init(itemID: "rss:4", episodeID: "e"))
  }

  @MainActor
  @Test("every notification destination reveals its route by collapsing the expanded player")
  func notificationDestinationsCollapseThePlayer() {
    let destinations: [RSSNotificationResolvedDestination] = [
      .episode(feedID: 4, identityKey: "e"),
      .show(feedID: 4),
      .latest,
      .podcastsRoot,
    ]

    for destination in destinations {
      let model = NavigationModel(presentation: .shell)
      model.expandPlayer()

      model.navigate(to: destination)

      #expect(model.playerPresentation == .collapsed)
    }
  }
  @Test("item detail route equality ignores its display seed")
  func itemDetailRoutesAreEqualRegardlessOfSeed() {
    let seed = ItemSummary(
      serverItemId: "abc", mediaKind: "book", title: "Title", author: nil,
      durationSeconds: nil)

    #expect(
      NavigationModel.Route.itemDetail(itemID: "abc")
        == .itemDetail(itemID: "abc", seed: seed))
  }

  @Test("item detail route hashing ignores its display seed")
  func itemDetailRoutesHashIdenticallyRegardlessOfSeed() {
    let seed = ItemSummary(
      serverItemId: "abc", mediaKind: "book", title: "Title", author: nil,
      durationSeconds: nil)
    let routes: Set<NavigationModel.Route> = [
      .itemDetail(itemID: "abc"),
      .itemDetail(itemID: "abc", seed: seed),
    ]

    #expect(routes.count == 1)
  }

  @Test("podcast show route equality, hashing, and deep links ignore its display seed")
  func podcastShowRoutesIgnoreTheirDisplaySeed() {
    let seed = ItemSummary(
      serverItemId: "show", mediaKind: "podcast", title: "Show", author: "Publisher",
      durationSeconds: nil, category: .podcast)
    let seeded = NavigationModel.Route.podcastShow(
      itemID: "show", filter: .downloaded, seed: seed)
    let unseeded = NavigationModel.Route.podcastShow(itemID: "show", filter: .downloaded)

    #expect(seeded == unseeded)
    #expect(Set([seeded, unseeded]).count == 1)
    #expect(
      NavigationModel.Destination(section: .library, path: [seeded]).deepLinkPath
        == "library/podcast-filtered/show/downloaded")
  }

  // MARK: - Deep-link round trip

  @Test(arguments: NavigationModel.Section.allCases)
  func sectionOnlyDestinationRoundTrips(section: NavigationModel.Section) {
    assertRoundTrips(.init(section: section))
  }

  @Test func pushedItemDetailRoundTrips() {
    assertRoundTrips(.init(section: .library, path: [.itemDetail(itemID: "abc123")]))
  }

  @Test func podcastShowRoutesRoundTrip() {
    assertRoundTrips(.init(section: .library, path: [.podcastShow(itemID: "show-123")]))
    assertRoundTrips(
      .init(
        section: .home,
        path: [.podcastShow(itemID: "show-123", filter: .downloaded)]))
  }

  /// Up Next is a player-owned presentation, not a place you can push to or link into. Nothing
  /// persists a `deepLinkPath`, so an `up-next` token has no restoration obligation: a link
  /// carrying it fails to parse rather than installing a queue page under some tab.
  @Test func theQueueIsNotAPushedDestinationAndItsOldDeepLinkTokenIsGone() {
    #expect(NavigationModel.Destination(deepLinkPath: "home/up-next") == nil)
    #expect(NavigationModel.Destination(deepLinkPath: "podcasts/up-next") == nil)
    #expect(
      NavigationModel.Destination(deepLinkPath: "podcasts/podcast/show%2D1/up-next") == nil)
  }

  @Test func filteredPodcastShowUsesStableDeepLinkAndLegacyShowLinkStillParses() {
    let filtered = NavigationModel.Destination(
      section: .home,
      path: [.podcastShow(itemID: "show-1", filter: .downloaded)])

    #expect(filtered.deepLinkPath == "home/podcast-filtered/show%2D1/downloaded")
    #expect(NavigationModel.Destination(deepLinkPath: filtered.deepLinkPath) == filtered)
    #expect(
      NavigationModel.Destination(deepLinkPath: "home/podcast/show%2D1")
        == .init(section: .home, path: [.podcastShow(itemID: "show-1")]))
  }

  @Test func homeMoreRouteCarriesSectionAndFilter() {
    assertRoundTrips(
      .init(section: .home, path: [.homeMore(section: .recentlyAdded, filter: .podcasts)]))
  }

  @Test("cross-tab podcast headings share canonical detail routes")
  func podcastHeadingsShareCanonicalDetailRoutes() {
    #expect(
      NavigationModel.Route.latestEpisodes
        == .homeMore(section: .newEpisodes, filter: .podcasts))
    #expect(
      NavigationModel.Route.podcastContinueListening
        == .homeMore(section: .continueListening, filter: .podcasts))
  }

  /// An author/series search hit needs somewhere to land.
  @Test func authorAndSeriesRoutesRoundTrip() {
    assertRoundTrips(.init(section: .search, path: [.author(id: "author-123")]))
    assertRoundTrips(.init(section: .search, path: [.series(id: "series-123")]))
    assertRoundTrips(
      .init(
        section: .search,
        path: [.author(id: "author-123", libraryID: "ebook-library")]))
    assertRoundTrips(
      .init(
        section: .search,
        path: [.series(id: "series-123", libraryID: "ebook-library")]))
  }

  @Test func authorAndSeriesRoutesHaveDistinctStableTokens() {
    #expect(
      NavigationModel.Destination(
        section: .library, path: [.author(id: "author-1")]
      ).deepLinkPath == "library/author/author%2D1")
    #expect(
      NavigationModel.Destination(
        section: .library, path: [.series(id: "series-1")]
      ).deepLinkPath == "library/series/series%2D1")
  }

  @Test func namedMetadataRoutesHaveDistinctStableTokens() {
    #expect(
      NavigationModel.Destination(
        section: .home, path: [.authorName(name: "Matt Dinniman")]
      ).deepLinkPath == "home/author-name/Matt%20Dinniman")
    #expect(
      NavigationModel.Destination(
        section: .home, path: [.seriesName(name: "Dungeon Crawler Carl")]
      ).deepLinkPath == "home/series-name/Dungeon%20Crawler%20Carl")
    #expect(
      NavigationModel.Destination(
        section: .home, path: [.narrator(name: "Jeff Hays")]
      ).deepLinkPath == "home/narrator/Jeff%20Hays")
  }

  @Test(arguments: ["simple", "with/slash", "unicode-üñïçødé-📚", ""])
  func namedMetadataRoutesRoundTrip(name: String) {
    assertRoundTrips(.init(section: .search, path: [.authorName(name: name)]))
    assertRoundTrips(.init(section: .search, path: [.seriesName(name: name)]))
    assertRoundTrips(.init(section: .search, path: [.narrator(name: name)]))
  }

  @Test func authorAndSeriesPresentationSeedsDoNotChangeRouteIdentityOrDeepLinks() {
    let author = AuthorSeriesEntity(
      kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "library-1")
    let seededAuthor = NavigationModel.Route.author(
      id: author.entityID, libraryID: author.libraryID,
      seed: AuthorSeriesDestinationSeed(entity: author))
    let unseededAuthor = NavigationModel.Route.author(
      id: author.entityID, libraryID: author.libraryID)
    let series = AuthorSeriesEntity(
      kind: .series, entityID: "series-1", name: "Fixture Series", libraryID: "library-1")
    let seededSeries = NavigationModel.Route.series(
      id: series.entityID, libraryID: series.libraryID,
      seed: AuthorSeriesDestinationSeed(entity: series))
    let unseededSeries = NavigationModel.Route.series(
      id: series.entityID, libraryID: series.libraryID)

    #expect(seededAuthor == unseededAuthor)
    #expect(Set([seededAuthor, unseededAuthor]).count == 1)
    #expect(seededSeries == unseededSeries)
    #expect(Set([seededSeries, unseededSeries]).count == 1)
    #expect(
      NavigationModel.Destination(section: .library, path: [seededAuthor]).deepLinkPath
        == "library/library-author/library%2D1/author%2D1")
    #expect(
      NavigationModel.Destination(section: .library, path: [seededSeries]).deepLinkPath
        == "library/library-series/library%2D1/series%2D1")
  }

  @Test(arguments: [
    "simple",
    "with/slash",
    "with space",
    "with%percent",
    "with?query&chars=1",
    "unicode-üñïçødé-📚",
    "",
  ])
  func podcastShowRoundTripsForAdversarialIDs(itemID: String) {
    assertRoundTrips(.init(section: .search, path: [.podcastShow(itemID: itemID)]))
  }

  @Test(arguments: [
    "simple",
    "with/slash",
    "with space",
    "with%percent",
    "with?query&chars=1",
    "unicode-üñïçødé-📚",
    "",
  ])
  func authorAndSeriesRoundTripForAdversarialIDs(entityID: String) {
    assertRoundTrips(.init(section: .search, path: [.author(id: entityID)]))
    assertRoundTrips(.init(section: .search, path: [.series(id: entityID)]))
  }

  /// A collection or playlist is keyed by server identity.
  @Test(arguments: [
    "simple",
    "with/slash",
    "with space",
    "with%percent",
    "with?query&chars=1",
    "unicode-üñïçødé-📚",
    "",
  ])
  func libraryCollectionRoundTripsForAdversarialIDs(id: String) {
    for kind in LibraryCollectionListKind.allCases {
      assertRoundTrips(
        .init(
          section: .library,
          path: [.libraryCollection(kind: kind, serverID: id, libraryID: id + "-lib")]))
    }
    assertRoundTrips(
      .init(
        section: .library,
        path: [
          .libraryCollection(kind: .playlist, serverID: id, libraryID: "lib"),
          .itemDetail(itemID: "abc"),
        ]))
  }

  @Test func smartListRoutesRoundTripDeepLinks() {
    assertRoundTrips(.init(section: .podcasts, path: [.smartLists]))
    assertRoundTrips(.init(section: .podcasts, path: [.smartList(id: 42)]))
    assertRoundTrips(.init(section: .podcasts, path: [.smartLists, .smartList(id: 7)]))
    #expect(
      NavigationModel.Destination(section: .podcasts, path: [.smartList(id: 42)]).deepLinkPath
        == "podcasts/smart-list/42")
    #expect(NavigationModel.Destination(deepLinkPath: "podcasts/smart-list/x") == nil)
    #expect(NavigationModel.Destination(deepLinkPath: "podcasts/smart-list") == nil)
    #expect(NavigationModel.Route.smartList(id: 1) != .smartList(id: 2))
    #expect(NavigationModel.Route.smartList(id: 1) != .smartLists)
  }

  @Test func episodeRefEqualityAndHashIgnoreTheListContext() {
    let plain = NavigationModel.PodcastEpisodeRef(itemID: "show", episodeID: "ep")
    let fromList = NavigationModel.PodcastEpisodeRef(
      itemID: "show", episodeID: "ep",
      listContext: NavigationModel.SmartListContext(listID: 3, name: "Commute"))
    #expect(plain == fromList)
    #expect(Set([plain, fromList]).count == 1)
    #expect(fromList.listContext?.name == "Commute")
    #expect(plain.listContext == nil)
    #expect(plain != NavigationModel.PodcastEpisodeRef(itemID: "show", episodeID: "other"))
  }

  @MainActor
  @Test func presentingAnEpisodeKeepsItsListContext() {
    let model = NavigationModel(presentation: .shell)
    model.presentEpisode(
      .init(
        itemID: "show", episodeID: "ep",
        listContext: NavigationModel.SmartListContext(listID: 3, name: "Commute")))
    #expect(model.presentedEpisode?.listContext?.listID == 3)
  }

  @Test func libraryCollectionHasAStableTokenAndDistinctIdentityPerKind() {
    #expect(
      NavigationModel.Destination(
        section: .library,
        path: [.libraryCollection(kind: .collection, serverID: "col-1", libraryID: "lib-1")]
      ).deepLinkPath == "library/library-list/collection/lib%2D1/col%2D1")
    #expect(
      NavigationModel.Route.libraryCollection(kind: .collection, serverID: "x", libraryID: "l")
        != .libraryCollection(kind: .playlist, serverID: "x", libraryID: "l"))
    #expect(NavigationModel.Destination(deepLinkPath: "library/library-list/folder/l/x") == nil)
    #expect(NavigationModel.Destination(deepLinkPath: "library/library-list/collection/l") == nil)
  }

  /// The storage screen and resolution center are pushed under `.settings`.
  @Test func storageRouteRoundTrips() {
    assertRoundTrips(.init(section: .settings, path: [.storage]))
  }

  @Test func resolutionCenterRouteRoundTrips() {
    assertRoundTrips(.init(section: .settings, path: [.resolutionCenter]))
  }

  @Test func mixedRouteKindsRoundTripInOrder() {
    assertRoundTrips(
      .init(
        section: .settings,
        path: [.storage, .resolutionCenter, .itemDetail(itemID: "abc")]))
  }

  @Test func mixedRouteKindsIncludingAuthorAndSeriesRoundTripInOrder() {
    assertRoundTrips(
      .init(
        section: .search,
        path: [.author(id: "author-1"), .series(id: "series-1"), .itemDetail(itemID: "abc")]))
  }

  /// Adding `.author`/`.series` must never change how any other route encodes or decodes.
  @Test func preExistingRoutesStillResolveUnchangedAfterAuthorAndSeriesWereAdded() {
    #expect(
      NavigationModel.Destination(deepLinkPath: "library/item/abc123")
        == .init(section: .library, path: [.itemDetail(itemID: "abc123")]))
    #expect(
      NavigationModel.Destination(deepLinkPath: "library/podcast/show%2D1")
        == .init(section: .library, path: [.podcastShow(itemID: "show-1")]))
    #expect(
      NavigationModel.Destination(deepLinkPath: "home/home-more/recentlyAdded/podcasts")
        == .init(section: .home, path: [.homeMore(section: .recentlyAdded, filter: .podcasts)]))
    #expect(
      NavigationModel.Destination(deepLinkPath: "settings/storage")
        == .init(section: .settings, path: [.storage]))
    #expect(
      NavigationModel.Destination(deepLinkPath: "settings/resolution")
        == .init(section: .settings, path: [.resolutionCenter]))
  }

  /// Item ids are opaque server strings. The encoding must survive slashes, whitespace,
  /// percent signs, and unicode without corrupting the round trip.
  @Test(arguments: [
    "simple",
    "with/slash",
    "with space",
    "with%percent",
    "with?query&chars=1",
    "unicode-üñïçødé-📚",
    "",
  ])
  func pushedItemDetailRoundTripsForAdversarialIDs(itemID: String) {
    assertRoundTrips(.init(section: .search, path: [.itemDetail(itemID: itemID)]))
  }

  /// Property-style sweep (seeded RNG, not unseeded `Int.random`) over every destination shape,
  /// so the round trip holds generally, not just for hand-picked examples.
  @Test(arguments: Array(0..<200))
  func deepLinkRoundTripHoldsForAnyGeneratedDestination(seed: Int) {
    var rng = NavigationModelTestRNG(seed: UInt64(seed))
    assertRoundTrips(Self.randomDestination(using: &rng))
  }

  private static func randomDestination(
    using rng: inout NavigationModelTestRNG
  ) -> NavigationModel.Destination {
    let sections = NavigationModel.Section.allCases
    let section = sections[rng.nextInt(upperBound: sections.count)]
    let depth = rng.nextInt(upperBound: 3)
    let path = (0..<depth).map { _ -> NavigationModel.Route in
      let length = rng.nextInt(upperBound: 12)
      let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/ %üé📚")
      let id = String((0..<length).map { _ in alphabet[rng.nextInt(upperBound: alphabet.count)] })
      return .itemDetail(itemID: id)
    }
    return .init(section: section, path: path)
  }

  private func assertRoundTrips(_ destination: NavigationModel.Destination) {
    let encoded = destination.deepLinkPath
    let decoded = NavigationModel.Destination(deepLinkPath: encoded)
    #expect(
      decoded == destination,
      "round trip failed for \(destination): encoded to \(encoded), decoded to \(String(describing: decoded))"
    )
  }

  @Test func unknownPathsDecodeToNil() {
    // Guards against a naive encoding where unrelated paths collide with a real destination.
    #expect(NavigationModel.Destination(deepLinkPath: "not-a-route") == nil)
  }

  /// The setup/login gate is not a route, so its deep-link tokens must not decode into some
  /// adjacent shell destination.
  @Test(arguments: ["setup", "login"])
  func retiredGateTokensNoLongerDecode(token: String) {
    #expect(NavigationModel.Destination(deepLinkPath: token) == nil)
  }

  @Test func unknownSectionDecodesToNil() {
    #expect(NavigationModel.Destination(deepLinkPath: "podcastz/item/abc") == nil)
  }

  @Test func unknownPushedRouteKindDecodesToNil() {
    #expect(NavigationModel.Destination(deepLinkPath: "library/chapter/abc") == nil)
  }

  // MARK: - Home

  /// Adding `.home` ahead of the other sections must not change their raw values, and so not
  /// their deep-link encodings.
  @Test func homeIsFirstAmongTheSectionsAndEveryPreExistingSectionKeepsItsOwnDeepLinkToken() {
    #expect(NavigationModel.Section.allCases.first == .home)
    #expect(NavigationModel.Destination(section: .home).deepLinkPath == "home")
    #expect(NavigationModel.Destination(section: .podcasts).deepLinkPath == "podcasts")
    #expect(NavigationModel.Destination(section: .library).deepLinkPath == "library")
    #expect(NavigationModel.Destination(section: .search).deepLinkPath == "search")
    #expect(NavigationModel.Destination(section: .settings).deepLinkPath == "settings")
  }

  @Test func podcastsOwnsAnIndependentTopLevelStack() {
    let destination = NavigationModel.Destination(
      section: .podcasts, path: [.podcastShow(itemID: "show-1"), .podcastShows])

    assertRoundTrips(destination)
  }

  @Test func homeSectionDestinationRoundTrips() {
    assertRoundTrips(.init(section: .home))
  }

  /// Deep links pushed under `.library`/`.search`/`.settings` must still resolve to the same
  /// destination with `.home` present.
  @Test func preExistingDeepLinksStillResolveUnchanged() {
    #expect(NavigationModel.Destination(deepLinkPath: "library") == .init(section: .library))
    #expect(NavigationModel.Destination(deepLinkPath: "search") == .init(section: .search))
    #expect(NavigationModel.Destination(deepLinkPath: "settings") == .init(section: .settings))
    #expect(
      NavigationModel.Destination(deepLinkPath: "library/item/abc123")
        == .init(section: .library, path: [.itemDetail(itemID: "abc123")]))
    #expect(
      NavigationModel.Destination(deepLinkPath: "settings/storage")
        == .init(section: .settings, path: [.storage]))
    #expect(
      NavigationModel.Destination(deepLinkPath: "settings/resolution")
        == .init(section: .settings, path: [.resolutionCenter]))
  }

  @Test func podcastDeepLinksHaveDistinctStableTokens() {
    #expect(
      NavigationModel.Destination(
        section: .library, path: [.podcastShow(itemID: "show-1")]
      ).deepLinkPath == "library/podcast/show%2D1")
    #expect(
      NavigationModel.Destination(
        section: .podcasts, path: [.podcastShows]
      ).deepLinkPath == "podcasts/podcast-shows")
  }

  @MainActor
  @Test func homeIsTheDefaultSection() {
    let model = NavigationModel()
    #expect(model.section == .home)
  }

  // MARK: - Gate

  @MainActor
  @Test func startsAtTheSetupGate() {
    let model = NavigationModel()
    #expect(model.presentation == .setup)
  }

  @MainActor
  @Test func enteringTheShellLeavesTheSetupGate() {
    let model = NavigationModel()
    model.enterShell()
    #expect(model.presentation == .shell)
    #expect(model.section == .home)
  }

  /// A removal that survived to this launch gates the whole shell, login/setup included, until
  /// the resume finishes.
  @MainActor
  @Test func enteringTheRemovalPendingGateLeavesEveryOtherPresentation() {
    let model = NavigationModel()

    model.enterRemovalPendingGate()

    #expect(model.presentation == .removalPending)
  }

  @MainActor
  @Test func resetForLogoutClearsTheRemovalPendingGateBackToSetup() {
    let model = NavigationModel()
    model.enterRemovalPendingGate()

    model.resetForLogout()

    #expect(model.presentation == .setup)
  }

  // MARK: - Sections are not pushes

  @MainActor
  @Test func startsInTheHomeSectionWithEveryPathEmpty() {
    let model = NavigationModel()
    #expect(model.section == .home)
    for section in NavigationModel.Section.allCases {
      #expect(model[pathFor: section].isEmpty)
    }
  }

  /// Selecting a sidebar section must not append a route, or library → settings → library
  /// builds a three-deep stack instead of changing section.
  @MainActor
  @Test func switchingSectionNeverAppendsToAnyPath() {
    let model = NavigationModel()
    model.enterShell()

    model.section = .settings
    model.section = .library
    model.section = .search

    #expect(model.section == .search)
    for section in NavigationModel.Section.allCases {
      #expect(model[pathFor: section].isEmpty)
    }
  }

  @MainActor
  @Test func eachSectionKeepsItsOwnPath() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .library
    model.navigate(to: .itemDetail(itemID: "from-library"))

    model.section = .search
    #expect(model[pathFor: .search].isEmpty)
    model.navigate(to: .itemDetail(itemID: "from-search"))

    model.section = .library
    #expect(model[pathFor: .library] == [.itemDetail(itemID: "from-library")])
    #expect(model[pathFor: .search] == [.itemDetail(itemID: "from-search")])
  }

  @MainActor
  @Test func navigateAppendsToTheCurrentSectionOnly() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .search

    model.navigate(to: .itemDetail(itemID: "42"))

    #expect(model[pathFor: .search] == [.itemDetail(itemID: "42")])
    #expect(model[pathFor: .library].isEmpty)
    #expect(model[pathFor: .settings].isEmpty)
  }

  @MainActor
  @Test func popAffectsOnlyTheCurrentSection() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .library
    model.navigate(to: .itemDetail(itemID: "lib"))
    model.section = .search
    model.navigate(to: .itemDetail(itemID: "srch"))

    model.pop()

    #expect(model[pathFor: .search].isEmpty)
    #expect(model[pathFor: .library] == [.itemDetail(itemID: "lib")])
  }

  @MainActor
  @Test func popAtASectionRootDoesNothing() {
    let model = NavigationModel()
    model.enterShell()

    model.pop()

    #expect(model[pathFor: .home].isEmpty)
    #expect(model.section == .home)
  }

  /// The App target drives `NavigationStack(path:)` through this subscript, so SwiftUI writing
  /// a shorter array back (an interactive swipe-back or the system chevron) must be accepted as
  /// the source of truth rather than fought.
  @MainActor
  @Test func writingAPathBackThroughTheSubscriptIsHonoured() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .library
    model.navigate(to: .itemDetail(itemID: "1"))

    model[pathFor: .library] = []

    #expect(model[pathFor: .library].isEmpty)
    #expect(model.current == .init(section: .library))
  }

  @MainActor
  @Test func currentReflectsTheSectionAndItsPath() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .search
    model.navigate(to: .itemDetail(itemID: "9"))

    #expect(model.current == .init(section: .search, path: [.itemDetail(itemID: "9")]))
  }

  // MARK: - Deep-link navigation

  @MainActor
  @Test func navigatingToADestinationSetsBothSectionAndPath() {
    let model = NavigationModel()
    model.enterShell()

    model.navigate(to: NavigationModel.Destination(section: .search, path: [.itemDetail(itemID: "7")]))

    #expect(model.section == .search)
    #expect(model[pathFor: .search] == [.itemDetail(itemID: "7")])
  }

  // MARK: - Search root navigation

  @MainActor
  @Test func showingSearchRootClearsSearchPathAndSelectsSearchSection() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .search
    model.navigate(to: .itemDetail(itemID: "stale-search-result"))
    model.section = .library

    model.showSearchRoot()

    #expect(model[pathFor: .search].isEmpty)
    #expect(model.section == .search)
  }

  @MainActor
  @Test func showingSearchRootPreservesOtherSectionPaths() {
    let model = NavigationModel()
    model.enterShell()

    model.section = .library
    model.navigate(to: .itemDetail(itemID: "library-detail"))
    let libraryPath = model[pathFor: .library]

    model.section = .podcasts
    model.navigate(to: .podcastShow(itemID: "podcast-show"))
    let podcastsPath = model[pathFor: .podcasts]

    model.section = .search
    model.navigate(to: .itemDetail(itemID: "stale-search-result"))

    model.showSearchRoot()

    #expect(model[pathFor: .library] == libraryPath)
    #expect(model[pathFor: .podcasts] == podcastsPath)
  }

  @MainActor
  @Test func showingSearchRootDismissesPresentedEpisode() {
    let model = NavigationModel()
    model.enterShell()
    model.presentEpisode(.init(itemID: "show-1", episodeID: "episode-1"))

    model.showSearchRoot()

    #expect(model.presentedEpisode == nil)
  }

  // MARK: - Logout

  /// Logout removes every account-owned state, so the shell
  /// must not leave a stale path, section, or presentation behind.
  @MainActor
  @Test func resetForLogoutClearsEverySectionPathAndReturnsToTheSetupGate() {
    let model = NavigationModel()
    model.enterShell()
    model.navigate(to: .itemDetail(itemID: "lib"))
    model.section = .settings
    model.navigate(to: .itemDetail(itemID: "set"))

    model.resetForLogout()

    #expect(model.presentation == .setup)
    #expect(model.section == .home)
    for section in NavigationModel.Section.allCases {
      #expect(model[pathFor: section].isEmpty)
    }
  }

  // MARK: - Podcast device-downloads settings

  @Test func podcastSettingsRouteRoundTripsDeepLink() {
    assertRoundTrips(.init(section: .settings, path: [.podcastSettings]))
    #expect(
      NavigationModel.Destination(section: .settings, path: [.podcastSettings]).deepLinkPath
        == "settings/podcast-settings")
  }

  @Test(arguments: [
    "simple",
    "with/slash",
    "with space",
    "with%percent",
    "with?query&chars=1",
    "unicode-üñïçødé-📚",
    "",
  ])
  func podcastShowSettingsRouteRoundTripsEscapedItemID(itemID: String) {
    assertRoundTrips(.init(section: .settings, path: [.podcastShowSettings(itemID: itemID)]))
  }

  /// Mirrors `deepLinkingToASettingsDestinationPresentsItWithoutLeavingTheCurrentSection`: the
  /// Podcasts settings destination is reached from any tab's toolbar, so navigating to it must
  /// raise the sheet over whatever section the user is on rather than moving them off it.
  @MainActor
  @Test func settingsDestinationPresentsSheetWithoutChangingSelectedSection() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .podcasts

    model.navigate(to: NavigationModel.Destination(section: .settings, path: [.podcastSettings]))

    #expect(model.settingsPresentation == .presented)
    #expect(model.section == .podcasts)
    #expect(model[pathFor: .settings] == [.podcastSettings])
  }

  /// The show overflow entry installs `[.podcastSettings, .podcastShowSettings(itemID:)]` in
  /// one deep link. Settings is its own sheet, not the current section (`navigate(to:
  /// Destination)` leaves `model.section` on the tab that raised it), so the system back control's
  /// truncation of the bound path returns to Podcast Settings; `pop()` only acts on
  /// `model.section`. Same contract as `writingAPathBackThroughTheSubscriptIsHonoured`.
  @MainActor
  @Test func showSettingsPathBacksUpToPodcastSettings() {
    let model = NavigationModel()
    model.enterShell()

    model.navigate(
      to: NavigationModel.Destination(
        section: .settings,
        path: [.podcastSettings, .podcastShowSettings(itemID: "show-1")]))
    model[pathFor: .settings] = [.podcastSettings]

    #expect(model[pathFor: .settings] == [.podcastSettings])
  }

  // MARK: - Podcast show ordering

  @Test func podcastShowsRouteRoundTripsDeepLink() {
    assertRoundTrips(.init(section: .podcasts, path: [.podcastShows]))
    #expect(
      NavigationModel.Destination(section: .podcasts, path: [.podcastShows]).deepLinkPath
        == "podcasts/podcast-shows")
  }

  @Test func nativePodcastShowsRouteHasADistinctStableDeepLink() {
    let destination = NavigationModel.Destination(
      section: .podcasts, path: [.nativePodcastShows])

    assertRoundTrips(destination)
    #expect(destination.deepLinkPath == "podcasts/your-shows")
    #expect(NavigationModel.Route.nativePodcastShows != .podcastShows)
  }

  @Test func podcastShowsRouteIdentityIsDistinctFromPodcastShow() {
    #expect(NavigationModel.Route.podcastShows != .podcastShow(itemID: "show-1"))
    let routes: Set<NavigationModel.Route> = [
      .podcastShows, .podcastShow(itemID: "show-1"),
    ]
    #expect(routes.count == 2)
  }

  @Test func podcastShowsRouteLivesOnPodcastsStack() {
    let destination = NavigationModel.Destination(
      section: .podcasts, path: [.podcastShows, .podcastShow(itemID: "show-1")])

    assertRoundTrips(destination)
  }

  // MARK: - Global player presentation

  /// The mini-player is global to the shell, so its expanded/collapsed presentation is tracked
  /// separately from every section's navigation path.
  @MainActor
  @Test func playerPresentationStartsCollapsed() {
    let model = NavigationModel()
    #expect(model.playerPresentation == .collapsed)
  }

  @MainActor
  @Test func expandingAndCollapsingThePlayerNeverAltersSectionPathOrDeepLinkDestination() {
    let model = NavigationModel()
    model.enterShell()
    model.navigate(to: .itemDetail(itemID: "abc"))
    model.section = .search
    let before = model.current

    model.expandPlayer()
    #expect(model.playerPresentation == .expanded)
    #expect(model.current == before)
    #expect(model.presentation == .shell)

    model.collapsePlayer()
    #expect(model.playerPresentation == .collapsed)
    #expect(model.current == before)
  }

  @MainActor
  @Test func expandingThePlayerDoesNotBypassTheSetupGate() {
    let model = NavigationModel()
    model.expandPlayer()
    #expect(model.presentation == .setup, "player presentation is independent of the account gate")
  }

  @MainActor
  @Test func logoutCollapsesAnExpandedPlayer() {
    let model = NavigationModel()
    model.enterShell()
    model.expandPlayer()

    model.resetForLogout()

    #expect(model.playerPresentation == .collapsed)
  }

  /// The collapse style is a property of one collapse. It defaults to a slide, is whatever the
  /// caller asked for until the player next expands, and never survives an expand or a logout, so
  /// a dissolve chosen for View Details cannot shape the pull-down that follows a later expand.
  @MainActor
  @Test func collapseStyleDefaultsToSlideAndIsResetByExpandAndLogout() {
    let model = NavigationModel()
    model.enterShell()
    #expect(model.playerCollapseStyle == .slide)

    model.expandPlayer()
    model.collapsePlayer(style: .dissolve)
    #expect(model.playerPresentation == .collapsed)
    #expect(model.playerCollapseStyle == .dissolve)

    model.expandPlayer()
    #expect(model.playerCollapseStyle == .slide, "an expand forgets the previous collapse's style")

    model.collapsePlayer()
    #expect(model.playerCollapseStyle == .slide, "the plain collapse is a slide")

    model.expandPlayer()
    model.collapsePlayer(style: .dissolve)
    model.resetForLogout()
    #expect(model.playerCollapseStyle == .slide)
    #expect(model.playerPresentation == .collapsed)
  }

  /// ARCHITECTURE.md D22: the expanded player is a `.sheet`, so an interactive swipe-down is a
  /// system dismissal. SwiftUI calls the `isPresented` binding's setter with `false`, which
  /// `PlayerPresentationBinding` (App target) forwards to `collapsePlayer()`. To
  /// `NavigationModel` that is any other collapse; this pins the contract the binding relies on.
  @MainActor
  @Test func systemDismissalCollapsesThePlayerPresentation() {
    let model = NavigationModel()
    model.enterShell()
    model.expandPlayer()

    model.collapsePlayer()

    #expect(model.playerPresentation == .collapsed)
  }

  // MARK: - Settings presentation

  /// Settings is reachable from every content root's toolbar rather than owning a tab, so, like
  /// the global player, it is presented over wherever you are instead of navigated to. It keeps
  /// its own `.settings` path, so its Storage/Resolution Center stack and deep-link tokens are
  /// unaffected.
  @MainActor
  @Test func settingsPresentationStartsDismissed() {
    let model = NavigationModel()
    #expect(model.settingsPresentation == .dismissed)
  }

  @MainActor
  @Test func presentingSettingsNeverAltersSectionPathOrDeepLinkDestination() {
    let model = NavigationModel()
    model.enterShell()
    model.navigate(to: .itemDetail(itemID: "abc"))
    model.section = .library
    let before = model.current

    model.presentSettings()
    #expect(model.settingsPresentation == .presented)
    #expect(model.current == before)
    #expect(model.section == .library)

    model.dismissSettings()
    #expect(model.settingsPresentation == .dismissed)
    #expect(model.current == before)
    #expect(model.section == .library, "dismissing returns to the section settings was raised over")
  }

  /// Settings is the one stack whose depth is not the user's place in the app: it is raised and
  /// dropped as a sheet. Its route stays in place during dismissal so the pushed screen does not
  /// pop mid-animation, then the next ordinary `presentSettings()` opens at the root.
  @MainActor
  @Test func dismissingSettingsDefersStackResetUntilTheNextPresentation() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .library
    model.navigate(to: NavigationModel.Destination(section: .settings, path: [.podcastSettings]))

    model.dismissSettings()

    #expect(model[pathFor: .settings] == [.podcastSettings])
    #expect(model.section == .library, "dismissing settings must not move the user")

    model.presentSettings()
    #expect(model[pathFor: .settings].isEmpty)
  }

  /// Selecting `.settings` as a section would leave the tab bar with nothing selected and no
  /// way back, because settings has no tab. A deep link must raise the sheet, not move the user
  /// off their section.
  @MainActor
  @Test func deepLinkingToASettingsDestinationPresentsItWithoutLeavingTheCurrentSection() {
    let model = NavigationModel()
    model.enterShell()
    model.section = .library

    model.navigate(to: NavigationModel.Destination(section: .settings, path: [.storage]))

    #expect(model.settingsPresentation == .presented)
    #expect(model.section == .library)
    #expect(model[pathFor: .settings] == [.storage])
  }

  @MainActor
  @Test func deepLinkingAnywhereElseDismissesPresentedSettings() {
    let model = NavigationModel()
    model.enterShell()
    model.presentSettings()

    model.navigate(to: NavigationModel.Destination(section: .search, path: [.itemDetail(itemID: "7")]))

    #expect(model.settingsPresentation == .dismissed)
    #expect(model.section == .search)
  }

  @MainActor
  @Test func logoutDismissesPresentedSettings() {
    let model = NavigationModel()
    model.enterShell()
    model.presentSettings()

    model.resetForLogout()

    #expect(model.settingsPresentation == .dismissed)
  }

  // MARK: - Item detail card presentation (ADR 0008)

  @MainActor
  @Test func itemDetailPresentationDefaultsToPush() {
    let model = NavigationModel()
    model.enterShell()

    model.navigate(to: .itemDetail(itemID: "book-1"))

    #expect(model.itemDetailPresentation == .push)
    #expect(model[pathFor: .home] == [.itemDetail(itemID: "book-1")])
    #expect(model.presentedItemDetail == nil)
  }

  @MainActor
  @Test func cardItemDetailPresentationLeavesPathUntouched() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    let seed = ItemSummary(
      serverItemId: "book-1", mediaKind: "book", title: "Book", author: "Author",
      durationSeconds: 3600)

    model.navigate(to: .itemDetail(itemID: "book-1", seed: seed))

    #expect(model[pathFor: .home].isEmpty)
    #expect(model.presentedItemDetail?.itemID == "book-1")
    #expect(model.presentedItemDetail?.seed == seed)
  }

  @MainActor
  @Test func cardItemDetailNavigationReplacesThePresentedCard() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    let first = ItemSummary(
      serverItemId: "book-1", mediaKind: "book", title: "First", author: nil,
      durationSeconds: nil)
    let second = ItemSummary(
      serverItemId: "book-2", mediaKind: "book", title: "Second", author: nil,
      durationSeconds: nil)

    model.navigate(to: .itemDetail(itemID: "book-1", seed: first))
    model.navigate(to: .itemDetail(itemID: "book-2", seed: second))

    #expect(model[pathFor: .home].isEmpty)
    #expect(model.presentedItemDetail?.itemID == "book-2")
    #expect(model.presentedItemDetail?.seed == second)
  }

  @MainActor
  @Test func onwardNavigationClearsTheItemDetailCardAndPushes() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    model.navigate(to: .itemDetail(itemID: "book-1"))

    model.navigate(to: .authorName(name: "Author"))

    #expect(model.presentedItemDetail == nil)
    #expect(model[pathFor: .home] == [.authorName(name: "Author")])
  }

  @MainActor
  @Test func presentingAnEpisodeDropsAnOpenItemDetailCard() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    model.navigate(to: .itemDetail(itemID: "book-1"))

    model.presentEpisode(.init(itemID: "show-1", episodeID: "ep-1"))

    #expect(model.presentedItemDetail == nil)
    #expect(model.presentedEpisode?.episodeID == "ep-1")
  }

  @MainActor
  @Test func dismissItemDetailClearsTheCard() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    model.navigate(to: .itemDetail(itemID: "book-1"))

    model.dismissItemDetail()

    #expect(model.presentedItemDetail == nil)
  }

  @MainActor
  @Test func switchingItemDetailToPushDismissesAnOpenCard() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    model.navigate(to: .itemDetail(itemID: "book-1"))

    model.setItemDetailPresentation(.push)

    #expect(model.itemDetailPresentation == .push)
    #expect(model.presentedItemDetail == nil)
  }

  @MainActor
  @Test func deepLinkNavigationClearsTheItemDetailCardWhenItPushes() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    model.navigate(to: .itemDetail(itemID: "book-1"))

    model.navigate(
      to: NavigationModel.Destination(section: .search, path: [.authorName(name: "Author")]))

    #expect(model.presentedItemDetail == nil)
    #expect(model.section == .search)
    #expect(model[pathFor: .search] == [.authorName(name: "Author")])
  }

  @MainActor
  @Test func cardPresentationAppliesToTerminalDeepLinkItemDetail() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)

    model.navigate(
      to: NavigationModel.Destination(
        section: .search, path: [.itemDetail(itemID: "book-1")]))

    #expect(model.section == .search)
    #expect(model[pathFor: .search].isEmpty)
    #expect(model.presentedItemDetail?.itemID == "book-1")
  }

  @MainActor
  @Test func logoutClearsPresentedItemDetail() {
    let model = NavigationModel()
    model.enterShell()
    model.setItemDetailPresentation(.card)
    model.navigate(to: .itemDetail(itemID: "book-1"))

    model.resetForLogout()

    #expect(model.presentedItemDetail == nil)
  }

  // MARK: - Episode card presentation

  /// `presentedEpisode` sits beside the path rather than inside it: a shell-level
  /// `.sheet(item:)` binds straight to it, as settings does to `settingsPresentation`.
  @MainActor
  @Test func presentEpisodeSetsPresentedEpisode() {
    let model = NavigationModel()
    model.enterShell()

    model.presentEpisode(.init(itemID: "show-1", episodeID: "ep-1"))

    #expect(model.presentedEpisode == .init(itemID: "show-1", episodeID: "ep-1"))
  }

  @MainActor
  @Test func dismissEpisodeClears() {
    let model = NavigationModel()
    model.enterShell()
    model.presentEpisode(.init(itemID: "show-1", episodeID: "ep-1"))

    model.dismissEpisode()

    #expect(model.presentedEpisode == nil)
  }

  /// The card pushing `.podcastShow` (its own show line, or the not-found fallback) must not leave
  /// itself covering the destination it just pushed to.
  @MainActor
  @Test func navigateClearsPresentedEpisode() {
    let model = NavigationModel()
    model.enterShell()
    model.presentEpisode(.init(itemID: "show-1", episodeID: "ep-1"))

    model.navigate(to: .podcastShow(itemID: "show-1"))

    #expect(model.presentedEpisode == nil)
    #expect(model[pathFor: .home] == [.podcastShow(itemID: "show-1")])
  }

  /// The deep-link entry point is the other push-shaped route into a section; it must clear the
  /// card for the same reason `navigate(to: Route)` does.
  @MainActor
  @Test func deepLinkNavigationClearsPresentedEpisode() {
    let model = NavigationModel()
    model.enterShell()
    model.presentEpisode(.init(itemID: "show-1", episodeID: "ep-1"))

    model.navigate(to: NavigationModel.Destination(section: .search, path: [.itemDetail(itemID: "7")]))

    #expect(model.presentedEpisode == nil)
  }

  /// Logout leaves nothing account-owned behind, the episode
  /// card included.
  @MainActor
  @Test func logoutClearsPresentedEpisode() {
    let model = NavigationModel()
    model.enterShell()
    model.presentEpisode(.init(itemID: "show-1", episodeID: "ep-1"))

    model.resetForLogout()

    #expect(model.presentedEpisode == nil)
  }

  /// An endpoint switch replaces the whole account graph, navigation model included. The account
  /// is the same one, so the user must come back to the place they left.
  @MainActor
  @Test("a rebuilt graph's navigation adopts the outgoing section and every stack")
  func adoptsLocationFromOutgoingModel() {
    let outgoing = NavigationModel(presentation: .shell)
    outgoing.section = .library
    outgoing.navigate(to: .author(id: "author-1"))
    outgoing.navigate(to: .itemDetail(itemID: "book-1"))
    outgoing[pathFor: .podcasts] = [.podcastShow(itemID: "show-1")]

    let fresh = NavigationModel(presentation: .shell)
    fresh.adoptLocation(from: outgoing)

    #expect(fresh.section == .library)
    #expect(fresh[pathFor: .library] == [.author(id: "author-1"), .itemDetail(itemID: "book-1")])
    #expect(fresh[pathFor: .podcasts] == [.podcastShow(itemID: "show-1")])
    #expect(fresh[pathFor: .home].isEmpty)
    #expect(fresh.current == outgoing.current)
  }

  /// Surfaces raised over the shell hold models built from the outgoing graph, and the account
  /// gate belongs to the graph that resolved it. Neither crosses.
  @MainActor
  @Test("adopting a location leaves the account gate and every raised surface alone")
  func adoptingLocationLeavesPresentationsAlone() {
    let outgoing = NavigationModel(presentation: .shell)
    outgoing.section = .podcasts
    outgoing.presentSettings()
    outgoing.presentEpisode(.init(itemID: "show-1", episodeID: "ep-1"))
    outgoing.expandPlayer()

    let fresh = NavigationModel(presentation: .setup)
    fresh.adoptLocation(from: outgoing)

    #expect(fresh.section == .podcasts)
    #expect(fresh.presentation == .setup)
    #expect(fresh.settingsPresentation == .dismissed)
    #expect(fresh.presentedEpisode == nil)
    #expect(fresh.presentedItemDetail == nil)
    #expect(fresh.playerPresentation == .collapsed)
  }
}

/// Deterministic, seedable RNG for the property-style deep-link sweep above. Mirrors
/// `SplitMix64` in `LibraryTraversalPlannerTests`, kept local because test targets don't share
/// sources.
struct NavigationModelTestRNG {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed &+ 0x9E37_79B9_7F4A_7C15
  }

  private mutating func nextUInt64() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func nextInt(upperBound: Int) -> Int {
    Int(nextUInt64() % UInt64(upperBound))
  }
}
