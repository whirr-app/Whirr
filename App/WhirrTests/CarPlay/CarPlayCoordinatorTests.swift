import AppModel
import CarPlay
import Persistence
import PlayerCore
import TestSupport
import Testing

@testable import Whirr

/// One car scene's templates and navigation, over a fake stack and real templates. Nothing here
/// renders. What the car draws is checked on a CarPlay screen.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CarPlayCoordinatorTests {
  private let world = CarPlayTestWorld()
  private let interface = FakeCarPlayInterface()
  private let nowPlaying = FakeCarPlayNowPlaying()
  private let coordinator: CarPlayCoordinator

  init() {
    coordinator = CarPlayCoordinator(
      environment: world.environment, interface: interface, nowPlaying: nowPlaying)
  }

  private func tab(_ tab: CarPlayTab) throws -> CPListTemplate {
    let bar = try #require(interface.root as? CPTabBarTemplate)
    let index = try #require(CarPlayTab.allCases.firstIndex(of: tab))
    return try #require(bar.templates[index] as? CPListTemplate)
  }

  /// The car reports the template it has just shown.
  private func settle() throws { coordinator.appeared(try #require(interface.top)) }

  // MARK: - Root

  @Test(arguments: [CarPlayRootState.starting, .unlockPhone, .signedOut, .unavailable])
  func notReadyShowsAStatusRootSynchronouslyAndStartsNothingElse(state: CarPlayRootState) throws {
    world.rootState = state
    coordinator.connect()

    let root = try #require(interface.root as? CPListTemplate)
    #expect(root.emptyViewTitleVariants == [try #require(state.message).title])
    #expect(root.listItems.isEmpty)
    #expect(world.startCount == 1)
    #expect(world.performed.isEmpty)
  }

  @Test func readyShowsOneTabPerDestination() throws {
    coordinator.connect()

    let bar = try #require(interface.root as? CPTabBarTemplate)
    #expect(bar.templates.map(\.tabTitle) == CarPlayTab.allCases.map(\.title))
    #expect(interface.rootCount == 1)
    #expect(world.performed.isEmpty)
  }

  @Test func carWithoutEnoughTabsGetsARootListOfDestinations() async throws {
    world.limits.maximumTabCount = 3
    coordinator.connect()

    let root = try #require(interface.root as? CPListTemplate)
    #expect(root.texts == CarPlayTab.allCases.map(\.title))

    // An author's books would be a level too deep under a root list, so Books offers neither.
    CarPlayCompletionCounter().tap(root.item(CarPlayTab.books.title))
    #expect(try #require(interface.topList).texts == ["All Books"])
    interface.pop(to: root)
    coordinator.appeared(root)

    world.pages[.downloads] = [CarPlayTestWorld.book("a")]
    let counter = CarPlayCompletionCounter()
    counter.tap(root.item(CarPlayTab.downloads.title))
    #expect(counter.count == 1)
    let downloads = try #require(interface.topList)
    #expect(downloads !== root)
    await waitUntil("downloads listed") { downloads.texts == ["Book a"] }
  }

  @Test func becomingReadyReplacesTheStatusRoot() async throws {
    world.rootState = .starting
    coordinator.connect()
    world.rootState = .ready

    await waitUntil("tabs shown") { interface.root is CPTabBarTemplate }
    #expect(interface.rootCount == 2)
  }

  @Test func connectingTwiceBuildsOneRoot() {
    coordinator.connect()
    coordinator.connect()
    #expect(interface.rootCount == 1)
    #expect(world.startCount == 1)
  }

  // MARK: - Lists

  @Test func continueTabOffersResumeThenTheShelf() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a"), CarPlayTestWorld.book("b")]
    coordinator.connect()

    #expect(try tab(.continueListening).texts == ["Resume", "Book a", "Book b"])

    world.snapshots[.continueListening] = [CarPlayTestWorld.book("b")]
    let list = try tab(.continueListening)
    await waitUntil("shelf updated") { list.texts == ["Resume", "Book b"] }
  }

  @Test func unchangedRowKeepsItsItemWhenTheListChanges() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a")]
    coordinator.connect()
    let list = try tab(.continueListening)
    let before = try #require(list.item("Book a"))

    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a"), CarPlayTestWorld.book("b")]
    await waitUntil("row added") { list.texts.count == 3 }
    #expect(list.item("Book a") === before)
  }

  @Test func listLongerThanTheCarAllowsIsCutAndSaysSo() throws {
    world.limits.maximumItemCount = 4
    world.snapshots[.continueListening] = (1...9).map { CarPlayTestWorld.book("\($0)") }
    coordinator.connect()

    let list = try tab(.continueListening)
    #expect(list.listItems.count == 4)
    #expect(list.sections.last?.header == CarPlayListContent.truncatedHeader)
  }

  @Test func podcastsTabIsReadAPageAtATime() async throws {
    world.pages[.podcastShows] = [CarPlayTestWorld.show("s")]
    coordinator.connect()

    let list = try tab(.podcasts)
    await waitUntil("shows listed") { list.texts == ["Show s"] }
    #expect(world.pageRequests.contains(.podcastShows))
  }

  @Test func showRowOpensItsEpisodesAndGoingBackReleasesThem() async throws {
    world.pages[.podcastShows] = [CarPlayTestWorld.show("s")]
    world.pages[.showEpisodes(itemID: "s")] = [CarPlayTestWorld.book("e")]
    coordinator.connect()
    let shows = try tab(.podcasts)
    await waitUntil("shows listed") { shows.texts == ["Show s"] }

    let counter = CarPlayCompletionCounter()
    counter.tap(shows.item("Show s"))
    await waitUntil("episodes pushed") { interface.pushed.count == 1 }
    #expect(counter.count == 1)
    let episodes = try #require(interface.topList)
    #expect(episodes.texts == ["Book e"])

    // Back, then in again: a new template and a new read, not the one that was left.
    interface.pop(to: try #require(interface.root))
    coordinator.appeared(shows)
    counter.tap(shows.item("Show s"))
    await waitUntil("episodes pushed again") { interface.pushed.count == 1 }
    #expect(interface.topList !== episodes)
    #expect(world.pageRequests.filter { $0 == .showEpisodes(itemID: "s") }.count == 2)
  }

  @Test func aListIsHeldBackUntilItsFirstPageIsRead() async throws {
    let route = CarPlayBrowseRoute.showEpisodes(itemID: "s")
    world.pages[.podcastShows] = [CarPlayTestWorld.show("s")]
    world.pages[route] = [CarPlayTestWorld.book("e")]
    world.heldRoutes = [route]
    coordinator.connect()
    let shows = try tab(.podcasts)
    await waitUntil("shows listed") { shows.texts == ["Show s"] }

    let counter = CarPlayCompletionCounter()
    counter.tap(shows.item("Show s"))
    await waitUntil("episodes being read") { world.hasWaitingPage }
    // The car keeps its spinner on the row: nothing is pushed and the tap is unanswered.
    #expect(interface.pushed.isEmpty)
    #expect(counter.count == 0)

    world.releasePages()
    await waitUntil("tap answered") { counter.count == 1 }
    #expect(try #require(interface.topList).texts == ["Book e"])
  }

  @Test func aListReadAfterTheListenerMovedOnIsNotPushed() async throws {
    let route = CarPlayBrowseRoute.showEpisodes(itemID: "s")
    world.pages[.podcastShows] = [CarPlayTestWorld.show("s")]
    world.heldRoutes = [route]
    coordinator.connect()
    let shows = try tab(.podcasts)
    coordinator.appeared(shows)
    await waitUntil("shows listed") { shows.texts == ["Show s"] }
    let counter = CarPlayCompletionCounter()
    counter.tap(shows.item("Show s"))
    await waitUntil("episodes being read") { world.hasWaitingPage }

    coordinator.appeared(try tab(.books))
    world.releasePages()
    await waitUntil("tap answered") { counter.count == 1 }
    #expect(interface.pushed.isEmpty)
  }

  @Test func disconnectAnswersATapWhoseListIsStillBeingRead() async throws {
    world.pages[.podcastShows] = [CarPlayTestWorld.show("s")]
    world.heldRoutes = [.showEpisodes(itemID: "s")]
    coordinator.connect()
    let shows = try tab(.podcasts)
    await waitUntil("shows listed") { shows.texts == ["Show s"] }
    let counter = CarPlayCompletionCounter()
    counter.tap(shows.item("Show s"))
    await waitUntil("episodes being read") { world.hasWaitingPage }

    coordinator.disconnect()
    await waitUntil("tap answered") { counter.count == 1 }
    world.releasePages()
    await awaitQuiescence("late page ignored") { "\(counter.count)|\(interface.pushed.count)" }
    #expect(counter.count == 1)
    #expect(interface.pushed.isEmpty)
  }

  @Test func booksTabLeadsToAuthorsThenAnAuthorsBooksThenNowPlaying() async throws {
    world.pages[.authors] = [CarPlayTestWorld.author("Ann Lee")]
    world.pages[.authorBooks(name: "Ann Lee")] = [CarPlayTestWorld.book("a")]
    coordinator.connect()
    let books = try tab(.books)
    coordinator.appeared(books)
    #expect(books.texts == ["All Books", "Authors", "Series"])

    let counter = CarPlayCompletionCounter()
    counter.tap(books.item("Authors"))
    await waitUntil("authors pushed") { interface.pushed.count == 1 }
    let authors = try #require(interface.topList)
    #expect(authors.title == "Authors")
    #expect(authors.texts == ["Ann Lee"])
    #expect(authors.item("Ann Lee")?.detailText == "2 books")

    counter.tap(authors.item("Ann Lee"))
    await waitUntil("the author's books pushed") { interface.pushed.count == 2 }
    let theirs = try #require(interface.topList)
    #expect(theirs.title == "Ann Lee")

    counter.tap(theirs.item("Book a"))
    await waitUntil("Now Playing opened") { interface.top === nowPlaying.template }
    #expect(interface.pushed.count == 3)
    #expect(counter.count == 3)
  }

  @Test func podcastsTabLeadsWithNewEpisodesAndShowsHowFarEachIs() async throws {
    world.snapshots[.latestEpisodes] = [
      CarPlayTestWorld.episode("new"), CarPlayTestWorld.episode("started", progress: 0.25),
    ]
    world.pages[.podcastShows] = [CarPlayTestWorld.show("s")]
    coordinator.connect()

    let list = try tab(.podcasts)
    await waitUntil("shows listed") { list.texts.contains("Show s") }
    #expect(list.texts == ["Episode new", "Episode started", "Show s"])
    #expect(
      list.sections.map(\.header) == [CarPlayListContent.latestEpisodesHeader, CarPlayListContent.showsHeader])
    #expect(list.item("Episode new")?.playbackProgress == 0)
    #expect(list.item("Episode started")?.playbackProgress == 0.25)

    let counter = CarPlayCompletionCounter()
    counter.tap(list.item("Episode started"))
    await waitUntil("tap answered") { counter.count == 1 }
    let started = try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "started"))
    #expect(world.performed == [.play(started)])
  }

  // MARK: - Selection

  @Test func tappingARowStartsItOnceAndOpensNowPlaying() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a")]
    world.holdsStarts = true
    coordinator.connect()
    let counter = CarPlayCompletionCounter()
    let row = try tab(.continueListening).item("Book a")

    counter.tap(row)
    counter.tap(row)
    await waitUntil("start performed") { world.hasWaitingStart }
    #expect(counter.count == 0)
    #expect(interface.pushed.isEmpty)

    world.finishStart(.accepted)
    await waitUntil("both taps answered") { counter.count == 2 }
    #expect(world.performed == [.play(try #require(ListeningIdentity.audiobook(itemID: "a")))])
    #expect(interface.pushed.count == 1)
    #expect(interface.top === nowPlaying.template)
  }

  @Test func resumeRowResumesTheLastTitle() async throws {
    coordinator.connect()
    let counter = CarPlayCompletionCounter()
    counter.tap(try tab(.continueListening).item("Resume"))

    await waitUntil("tap answered") { counter.count == 1 }
    #expect(world.performed == [.resumeLastPlayed])
    #expect(interface.top === nowPlaying.template)
  }

  @Test func failedStartSaysSoAndCanBeRetried() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a")]
    world.startResult = .rejected(.preparationFailed)
    coordinator.connect()
    let counter = CarPlayCompletionCounter()
    counter.tap(try tab(.continueListening).item("Book a"))

    await waitUntil("alert presented") { interface.alerts.count == 1 }
    #expect(counter.count == 1)
    #expect(interface.pushed.isEmpty)

    let alert = try #require(interface.alerts.first)
    let retry = try #require(alert.actions.first { $0.title == "Try Again" })
    world.startResult = .accepted
    retry.handler(retry)
    await waitUntil("retried start opened Now Playing") { interface.top === nowPlaying.template }
    #expect(world.performed.count == 2)
    #expect(interface.dismissCount == 1)
  }

  @Test func disconnectAnswersAPendingTapAndShowsNothing() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a")]
    world.holdsStarts = true
    coordinator.connect()
    let counter = CarPlayCompletionCounter()
    counter.tap(try tab(.continueListening).item("Book a"))
    await waitUntil("start performed") { world.hasWaitingStart }

    coordinator.disconnect()
    await waitUntil("tap answered") { counter.count == 1 }
    #expect(nowPlaying.isDetached)

    world.finishStart(.accepted)
    await awaitQuiescence("late start ignored") {
      "\(counter.count)|\(interface.pushed.count)|\(interface.alerts.count)"
    }
    #expect(counter.count == 1)
    #expect(interface.pushed.isEmpty)
    #expect(interface.alerts.isEmpty)
  }

  @Test func accountChangeRebuildsTheRootAndDropsTheOldAccountsRows() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a")]
    world.holdsStarts = true
    coordinator.connect()
    let old = try tab(.continueListening)
    let counter = CarPlayCompletionCounter()
    counter.tap(old.item("Book a"))
    await waitUntil("start performed") { world.hasWaitingStart }

    world.snapshots[.continueListening] = [CarPlayTestWorld.book("z")]
    world.generation = 2
    await waitUntil("root rebuilt") { interface.rootCount == 2 }
    await waitUntil("old tap answered") { counter.count == 1 }
    #expect(try tab(.continueListening) !== old)
    #expect(try tab(.continueListening).texts == ["Resume", "Book z"])

    // The old account's start finishing late opens nothing under the new one.
    world.finishStart(.accepted)
    await awaitQuiescence("late start ignored") { "\(interface.pushed.count)" }
    #expect(interface.pushed.isEmpty)
  }

  @Test func signingOutReplacesTheBrowserWithAStatusRoot() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a")]
    coordinator.connect()
    world.rootState = .signedOut

    await waitUntil("status shown") { interface.root is CPListTemplate }
    #expect((interface.root as? CPListTemplate)?.listItems.isEmpty == true)
  }

  // MARK: - Now Playing

  @Test func nothingLoadedOffersNoNowPlayingButtons() {
    coordinator.connect()
    #expect(nowPlaying.buttons == CarPlayNowPlayingButtons())
  }

  @Test func chapteredBookOffersChaptersAndATapSeeksAndReturns() async throws {
    world.player = try CarPlayTestWorld.chapteredBook()
    coordinator.connect()
    #expect(nowPlaying.buttons.showsChapters)
    #expect(nowPlaying.buttons.showsRate)

    // Chapters sits on Now Playing. Without it there is nowhere to put the list.
    nowPlaying.onChapters?()
    #expect(interface.pushed.isEmpty)

    interface.push(nowPlaying.template)
    coordinator.appeared(nowPlaying.template)
    nowPlaying.onChapters?()
    let chapters = try #require(interface.topList)
    #expect(chapters.texts == ["Opening", "Middle", "Closing"])
    #expect(chapters.listItems.map(\.isPlaying) == [false, true, false])

    let counter = CarPlayCompletionCounter()
    counter.tap(chapters.item("Closing"))
    #expect(counter.count == 1)
    #expect(world.selectedChapters == [2])
    #expect(interface.top === nowPlaying.template)
  }

  @Test func chapterListFollowsTheCurrentChapter() async throws {
    world.player = try CarPlayTestWorld.chapteredBook()
    coordinator.connect()
    interface.push(nowPlaying.template)
    coordinator.appeared(nowPlaying.template)
    nowPlaying.onChapters?()
    let chapters = try #require(interface.topList)

    world.player = try CarPlayTestWorld.chapteredBook(position: 250)
    await waitUntil("current chapter moved") { chapters.listItems.map(\.isPlaying) == [false, false, true] }
  }

  @Test func rateButtonSetsTheNextPreset() async throws {
    world.player = try CarPlayTestWorld.chapteredBook()
    coordinator.connect()
    nowPlaying.onRate?()
    #expect(world.rates == [1.5])

    world.rate = 2
    await waitUntil("rate observed") {
      nowPlaying.onRate?()
      return world.rates.last == 1
    }
  }

  @Test func upNextIsOfferedOnlyWhileTheQueueHasRows() async throws {
    coordinator.connect()
    #expect(nowPlaying.buttons.showsUpNext == false)

    world.snapshots[.upNext] = [CarPlayTestWorld.book("q")]
    await waitUntil("Up Next offered") { nowPlaying.buttons.showsUpNext }

    interface.push(nowPlaying.template)
    coordinator.appeared(nowPlaying.template)
    nowPlaying.onUpNext?()
    #expect(try #require(interface.topList).texts == ["Book q"])
  }

  // MARK: - Thumbnails and teardown

  @Test func onlyTheVisibleListAsksForArtworkAndItIsKeyedToTheGraph() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a", artwork: .item(id: "a", updatedAt: nil))]
    world.snapshots[.recentBooks] = [CarPlayTestWorld.book("b", artwork: .item(id: "b", updatedAt: nil))]
    coordinator.connect()

    await waitUntil("thumbnail requested") { world.artworkKeys.isEmpty == false }
    await awaitQuiescence("no further requests") { "\(world.artworkKeys.count)" }
    #expect(
      world.artworkKeys == [
        CarPlayArtworkKey(
          generation: 1, reference: .item(id: "a", updatedAt: nil), pixelSize: 90, isDark: false)
      ])

    coordinator.appeared(try tab(.books))
    await waitUntil("books thumbnail requested") { world.artworkKeys.count == 2 }
    #expect(world.artworkKeys.last?.reference == .item(id: "b", updatedAt: nil))
  }

  @Test func repeatedConnectAndDisconnectLeavesNothingBehind() async throws {
    world.snapshots[.continueListening] = [CarPlayTestWorld.book("a")]
    for round in 1...3 {
      coordinator.connect()
      #expect(interface.rootCount == round)
      #expect(try tab(.continueListening).texts == ["Resume", "Book a"])
      coordinator.disconnect()
    }
    let roots = interface.rootCount

    // A disconnected scene stops following the runtime or the player.
    world.generation = 2
    world.player = try CarPlayTestWorld.chapteredBook()
    await awaitQuiescence("nothing follows a disconnected scene") { "\(interface.rootCount)" }
    #expect(interface.rootCount == roots)
    #expect(nowPlaying.buttons == CarPlayNowPlayingButtons())
  }

  @Test func coordinatorIsReleasedAfterDisconnect() async throws {
    weak var released: CarPlayCoordinator?
    do {
      let scoped = CarPlayCoordinator(environment: world.environment, interface: interface, nowPlaying: nowPlaying)
      released = scoped
      scoped.connect()
      scoped.disconnect()
    }
    await waitUntil("coordinator released") { released == nil }
  }
}
