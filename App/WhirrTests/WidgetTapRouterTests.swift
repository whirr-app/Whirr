import AppModel
import Foundation
import Persistence
import Testing
import WidgetProtocol

@testable import Whirr

@Suite struct WidgetTapRouterTests {

  private static let context = WidgetTapContext(hasNowPlaying: true, homeFilter: .all, showsPodcastsTab: true)

  private static func lookup(_ entries: [String: CompanionSelection]) -> (String) -> CompanionSelection? {
    { entries[$0] }
  }

  // MARK: - Resolving a link

  @Test func anEpisodeTokenResolvesToItsCard() throws {
    let source = try #require(PodcastSourceIdentity(itemId: "li_show"))
    let action = WidgetTapRouter.action(
      for: .item(token: "t1"),
      selection: Self.lookup(["t1": CompanionSelection(source: source, episodeID: "ep_1")]))
    #expect(action == .presentEpisode(.init(itemID: "li_show", episodeID: "ep_1")))
  }

  @Test func aNativeEpisodeTokenResolvesToItsCard() throws {
    let source = try #require(PodcastSourceIdentity.rss(feedId: 42))
    let action = WidgetTapRouter.action(
      for: .item(token: "t1"),
      selection: Self.lookup(["t1": CompanionSelection(source: source, episodeID: "guid-1")]))
    #expect(action == .presentEpisode(.init(itemID: source.itemId, episodeID: "guid-1")))
  }

  @Test func aBookTokenResolvesToItsDetail() throws {
    let source = try #require(PodcastSourceIdentity(itemId: "li_book"))
    let action = WidgetTapRouter.action(
      for: .item(token: "t1"), selection: Self.lookup(["t1": CompanionSelection(source: source)]))
    #expect(action == .itemDetail(itemID: "li_book"))
  }

  /// Stale, another account's, or signed out: the runtime resolves nothing, and the app opens
  /// where it was.
  @Test func anUnresolvedTokenDoesNothing() {
    #expect(WidgetTapRouter.action(for: .item(token: "gone"), selection: Self.lookup([:])) == WidgetTapAction.none)
  }

  @Test func fixedDestinationsNeedNoLookup() {
    let never: (String) -> CompanionSelection? = { _ in
      Issue.record("looked up a token")
      return nil
    }
    #expect(WidgetTapRouter.action(for: .player, selection: never) == .expandPlayer)
    #expect(WidgetTapRouter.action(for: .listeningStats, selection: never) == .listeningStats)
    #expect(WidgetTapRouter.action(for: .latestEpisodes, selection: never) == .latestEpisodes)
  }

  /// A list row's card says which list it plays from, so its Play continues the list's run.
  @Test func aListRowTokenResolvesToItsCardWithTheList() throws {
    let source = try #require(PodcastSourceIdentity(itemId: "li_show"))
    let row = WidgetTokenMap.ListSelection(
      listID: 3, selection: CompanionSelection(source: source, episodeID: "ep_1"))
    let action = WidgetTapRouter.action(
      for: .item(token: "r1"), selection: Self.lookup([:]),
      listSelection: { $0 == "r1" ? row : nil }, listName: { $0 == 3 ? "Morning" : nil })

    guard case .presentEpisode(let ref) = action else {
      Issue.record("expected a card, got \(action)")
      return
    }
    #expect(ref == .init(itemID: "li_show", episodeID: "ep_1"))
    #expect(ref.listContext == .init(listID: 3, name: "Morning"))
  }

  @Test func aListLinkOpensOnlyAPublishedList() {
    let names: (Int64) -> String? = { $0 == 3 ? "Morning" : nil }
    #expect(
      WidgetTapRouter.action(for: .smartList(id: 3), selection: Self.lookup([:]), listName: names)
        == .smartList(id: 3))
    #expect(
      WidgetTapRouter.action(for: .smartList(id: 4), selection: Self.lookup([:]), listName: names)
        == WidgetTapAction.none)
  }

  // MARK: - Applying it

  @MainActor @Test func theCardRaisesOverWhereTheListenerWas() {
    let navigation = NavigationModel(presentation: .shell, section: .library)
    navigation.navigate(to: .podcastShows)
    navigation.expandPlayer()
    navigation.presentSettings()
    let ref = NavigationModel.PodcastEpisodeRef(itemID: "li_show", episodeID: "ep_1")

    WidgetTapRouter.apply(.presentEpisode(ref), to: navigation, context: Self.context)

    #expect(navigation.presentedEpisode == ref)
    #expect(navigation.playerPresentation == .collapsed)
    #expect(navigation.settingsPresentation == .dismissed)
    #expect(navigation.section == .library)
    #expect(navigation[pathFor: .library] == [.podcastShows])
  }

  @MainActor @Test func aBookPushesItsDetailAtPushWidth() {
    let navigation = NavigationModel(presentation: .shell, section: .home)
    navigation.expandPlayer()

    WidgetTapRouter.apply(.itemDetail(itemID: "li_book"), to: navigation, context: Self.context)

    #expect(navigation[pathFor: .home] == [.itemDetail(itemID: "li_book")])
    #expect(navigation.presentedItemDetail == nil)
    #expect(navigation.playerPresentation == .collapsed)
  }

  @MainActor @Test func aBookRaisesItsCardAtCardWidth() {
    let navigation = NavigationModel(presentation: .shell, section: .home)
    navigation.setItemDetailPresentation(.card)
    navigation.presentSettings()

    WidgetTapRouter.apply(.itemDetail(itemID: "li_book"), to: navigation, context: Self.context)

    #expect(navigation.presentedItemDetail?.itemID == "li_book")
    #expect(navigation[pathFor: .home].isEmpty)
    #expect(navigation.settingsPresentation == .dismissed)
  }

  @MainActor @Test func thePlayerExpandsWhenThereIsSomethingToShow() {
    let navigation = NavigationModel(presentation: .shell)
    navigation.presentSettings()

    WidgetTapRouter.apply(.expandPlayer, to: navigation, context: Self.context)

    #expect(navigation.playerPresentation == .expanded)
    #expect(navigation.settingsPresentation == .dismissed)
  }

  @MainActor @Test func thePlayerStaysPutWithNothingToShow() {
    let navigation = NavigationModel(presentation: .shell)
    navigation.presentSettings()

    WidgetTapRouter.apply(
      .expandPlayer, to: navigation,
      context: WidgetTapContext(hasNowPlaying: false, homeFilter: .all, showsPodcastsTab: true))

    #expect(navigation.playerPresentation == .collapsed)
    #expect(navigation.settingsPresentation == .presented)
  }

  @MainActor @Test(arguments: MediaFilter.allCases)
  func statsOpensTheRouteTheHomeCardPushes(filter: MediaFilter) {
    let navigation = NavigationModel(presentation: .shell, section: .search)
    navigation.expandPlayer()

    WidgetTapRouter.apply(
      .listeningStats, to: navigation,
      context: WidgetTapContext(hasNowPlaying: true, homeFilter: filter, showsPodcastsTab: true))

    #expect(navigation.section == .home)
    #expect(
      navigation[pathFor: .home] == [HomeViewPresentation.detailRoute(for: .listeningStats, selectedFilter: filter)])
    #expect(navigation.playerPresentation == .collapsed)
  }

  @MainActor @Test func latestEpisodesOpensOnThePodcastsTab() {
    let navigation = NavigationModel(presentation: .shell, section: .home)

    WidgetTapRouter.apply(.latestEpisodes, to: navigation, context: Self.context)

    #expect(navigation.section == .podcasts)
    #expect(navigation[pathFor: .podcasts] == [.latestEpisodes])
  }

  @MainActor @Test func latestEpisodesOpensUnderHomeWithoutAPodcastsTab() {
    let navigation = NavigationModel(presentation: .shell, section: .library)

    WidgetTapRouter.apply(
      .latestEpisodes, to: navigation,
      context: WidgetTapContext(hasNowPlaying: true, homeFilter: .all, showsPodcastsTab: false))

    #expect(navigation.section == .home)
    #expect(navigation[pathFor: .home] == [.latestEpisodes])
    #expect(navigation[pathFor: .podcasts].isEmpty)
  }

  @MainActor @Test func aSmartListOpensOnThePodcastsTabOverTheExpandedPlayer() {
    let navigation = NavigationModel(presentation: .shell, section: .library)
    navigation.expandPlayer()
    navigation.presentSettings()

    WidgetTapRouter.apply(.smartList(id: 7), to: navigation, context: Self.context)

    #expect(navigation.section == .podcasts)
    #expect(navigation[pathFor: .podcasts] == [.smartList(id: 7)])
    #expect(navigation.playerPresentation == .collapsed)
    #expect(navigation.settingsPresentation == .dismissed)
  }

  @MainActor @Test func aSmartListOpensUnderHomeWithoutAPodcastsTab() {
    let navigation = NavigationModel(presentation: .shell, section: .library)

    WidgetTapRouter.apply(
      .smartList(id: 7), to: navigation,
      context: WidgetTapContext(hasNowPlaying: true, homeFilter: .all, showsPodcastsTab: false))

    #expect(navigation.section == .home)
    #expect(navigation[pathFor: .home] == [.smartList(id: 7)])
  }

  @MainActor @Test func nothingChangesNothing() {
    let navigation = NavigationModel(presentation: .shell, section: .library)
    navigation.navigate(to: .podcastShows)
    navigation.expandPlayer()
    let before = navigation.current

    WidgetTapRouter.apply(.none, to: navigation, context: Self.context)

    #expect(navigation.current == before)
    #expect(navigation.playerPresentation == .expanded)
    #expect(navigation.presentedEpisode == nil)
  }

  // MARK: - Holding a tap until the shell is mounted

  @MainActor @Test func aTapWaitsForTheLibraryShell() {
    let inbox = WidgetTapInbox()
    inbox.receive(.player)

    #expect(inbox.take(isLibraryShellMounted: false) == nil)
    #expect(inbox.take(isLibraryShellMounted: true) == .player)
  }

  /// `onOpenURL` and the mount trigger can both deliver a cold-launch tap.
  @MainActor @Test func aTapAppliesOnce() {
    let inbox = WidgetTapInbox()
    inbox.receive(.listeningStats)

    #expect(inbox.take(isLibraryShellMounted: true) == .listeningStats)
    #expect(inbox.take(isLibraryShellMounted: true) == nil)
  }

  @MainActor @Test func theLatestTapWins() {
    let inbox = WidgetTapInbox()
    inbox.receive(.player)
    inbox.receive(.item(token: "t2"))

    #expect(inbox.take(isLibraryShellMounted: true) == .item(token: "t2"))
  }

  @MainActor @Test func clearingDropsAHeldTap() {
    let inbox = WidgetTapInbox()
    inbox.receive(.player)
    inbox.clear()

    #expect(inbox.take(isLibraryShellMounted: true) == nil)
  }

  /// The sign-in callback shares the scheme; it must never reach navigation.
  @Test func theSignInCallbackIsNotAWidgetLink() throws {
    let url = try #require(URL(string: "whirr://oauth?code=x&state=y"))
    #expect(WidgetTapDestination(url: url) == nil)
  }
}
