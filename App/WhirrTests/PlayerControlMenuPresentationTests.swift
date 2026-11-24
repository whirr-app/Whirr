import AppModel
import Persistence
import PlayerCore
import Testing

@testable import Whirr

@Suite("Native player control menus")
struct PlayerControlMenuPresentationTests {

  /// Item actions sit with the item's identity, not with the playback controls. The bottom row
  /// keeps only controls that report their own state, so nothing there can represent More.
  @Test("secondary item actions live beside the title, not in the quick-action row")
  func secondaryActionsUseTheMetadataTrailingSlot() {
    #expect(PlayerOverflowMenuPresentation.placement == .metadataTrailing)
    #expect(
      PlayerQuickActionsPresentation.bottomActions(episodeID: nil)
        == [.sleepTimer, .playbackRate, .audioRoute, .upNext])
  }

  @Test("overflow menu offers a download before the progress actions and a removal after them")
  func overflowMenuActionOrder() {
    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .download, includesHistory: false, playbackStatus: .inProgress)
        == [.viewDetails, .download, .markAsFinished, .resetProgress])
    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .remove, includesHistory: false, playbackStatus: .inProgress)
        == [.viewDetails, .markAsFinished, .resetProgress, .deleteDownload])
    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .unavailable, includesHistory: false, playbackStatus: .inProgress)
        == [.viewDetails, .markAsFinished, .resetProgress, .deletingDownload])
  }

  @Test("overflow progress actions follow the shared three-state policy")
  func overflowProgressActionsFollowSharedPolicy() {
    func progressActions(_ status: ItemPlaybackStatus?) -> [PlayerOverflowMenuPresentation.Action] {
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .download, includesHistory: false, playbackStatus: status
      ).filter { $0 == .markAsFinished || $0 == .resetProgress }
    }

    #expect(progressActions(nil) == [.markAsFinished])
    #expect(progressActions(.inProgress) == [.markAsFinished, .resetProgress])
    #expect(progressActions(.finished) == [.resetProgress])
  }

  @Test("overflow menu never offers removal from Continue Listening")
  func overflowMenuSuppressesContinueListeningRemoval() {
    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .download,
        includesHistory: false,
        playbackStatus: .inProgress)
        == [.viewDetails, .download, .markAsFinished, .resetProgress])
  }

  /// Past sessions live on the item-detail History tab, which a Continue Listening tap skips. It
  /// sits directly under View Details, which opens the page that hosts it. The pair leads because
  /// neither changes anything.
  @Test("listening history follows View Details when it is offered")
  func historyFollowsViewDetailsInTheOverflowMenu() {
    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .download, includesHistory: true, playbackStatus: .inProgress)
        == [.viewDetails, .history, .download, .markAsFinished, .resetProgress])
    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .remove, includesHistory: true, playbackStatus: .inProgress)
        == [.viewDetails, .history, .markAsFinished, .resetProgress, .deleteDownload])
  }

  /// The companion PDF is "about this book" and changes nothing, so it closes the surface group:
  /// after History, before the download.
  @Test("a companion PDF follows History and precedes the download")
  func supplementJoinsTheSurfaceGroup() {
    let withHistory = PlayerOverflowMenuPresentation.actions(
      downloadAction: .remove, includesHistory: true, supplementCount: 2,
      playbackStatus: .inProgress)
    #expect(
      withHistory
        == [.viewDetails, .history, .viewSupplement, .markAsFinished, .resetProgress, .deleteDownload])
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.viewSupplement, in: withHistory) == false)
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.deleteDownload, in: withHistory))

    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .download, includesHistory: false, supplementCount: 1,
        playbackStatus: nil)
        == [.viewDetails, .viewSupplement, .download, .markAsFinished])
    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .download, includesHistory: true, supplementCount: 0,
        playbackStatus: nil)
        == [.viewDetails, .history, .download, .markAsFinished])
  }

  /// Transcript is a surface to read, so it joins View Details' group directly after it, and is
  /// offered only when the coordinator reports the loaded episode eligible.
  @Test("Transcript follows View Details when the episode is eligible, and is absent otherwise")
  func transcriptFollowsViewDetailsWhenOffered() {
    let offered = PlayerOverflowMenuPresentation.actions(
      downloadAction: .remove, includesHistory: false, includesTranscript: true,
      playbackStatus: .inProgress)
    #expect(offered == [.viewDetails, .transcript, .markAsFinished, .resetProgress, .deleteDownload])
    #expect(PlayerOverflowMenuPresentation.group(.transcript) == .surface)
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.transcript, in: offered) == false)
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.deleteDownload, in: offered))

    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .remove, includesHistory: false, playbackStatus: .inProgress
      ).contains(.transcript) == false)
  }

  /// Look Back is a surface to read too: after View Details, before History, and only when asked
  /// for, so every existing array above is unchanged by the default.
  @Test("Look Back follows View Details in the surface group when offered, and is absent otherwise")
  func lookBackFollowsViewDetailsWhenOffered() {
    let offered = PlayerOverflowMenuPresentation.actions(
      downloadAction: .download, includesHistory: true, includesLookBack: true,
      playbackStatus: .inProgress)
    #expect(offered == [.viewDetails, .lookBack, .history, .download, .markAsFinished, .resetProgress])
    #expect(PlayerOverflowMenuPresentation.group(.lookBack) == .surface)
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.lookBack, in: offered) == false)

    #expect(
      PlayerOverflowMenuPresentation.actions(
        downloadAction: .download, includesHistory: true, playbackStatus: .inProgress
      ).contains(.lookBack) == false)
  }

  /// Hidden rather than empty: the per-item sessions route answers for an item, and for a podcast
  /// that answer is an empty list unless an episode id is part of the query.
  @Test("history is hidden for a podcast episode, as chapters already is")
  func historyIsHiddenForAnEpisode() {
    #expect(PlayerQuickActionsPresentation.showsHistory(episodeID: nil))
    #expect(PlayerQuickActionsPresentation.showsHistory(episodeID: "ep-1") == false)
  }

  @Test("overflow separators follow the action's family, never its position")
  func overflowSeparatorsFollowActionGroups() {
    let withHistory = PlayerOverflowMenuPresentation.actions(
      downloadAction: .download, includesHistory: true, playbackStatus: .inProgress)

    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.viewDetails, in: withHistory) == false)
    // Both are surfaces to look at, so they stay one block.
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.history, in: withHistory) == false)
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.download, in: withHistory))
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.markAsFinished, in: withHistory))
    // Both write progress, so they stay one block.
    #expect(
      PlayerOverflowMenuPresentation.dividerPrecedes(.resetProgress, in: withHistory) == false)

    // Without history View Details still leads its group, so the download keeps its separator.
    let withoutHistory = PlayerOverflowMenuPresentation.actions(
      downloadAction: .download, includesHistory: false, playbackStatus: .inProgress)
    #expect(
      PlayerOverflowMenuPresentation.dividerPrecedes(.viewDetails, in: withoutHistory) == false)
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.download, in: withoutHistory))
    #expect(PlayerOverflowMenuPresentation.dividerPrecedes(.markAsFinished, in: withoutHistory))
  }

  /// The player is the one surface that can start a title without ever showing its page: a
  /// Continue Listening tap goes straight to playback. Unlike History it is offered for every
  /// scope, because both media kinds have a details surface to reach.
  @Test("View Details leads the overflow menu for every scope")
  func viewDetailsLeadsTheOverflowMenu() {
    for status: ItemPlaybackStatus? in [nil, .inProgress, .finished] {
      for includesHistory in [true, false] {
        for download: ItemContextMenuDownloadAction in [.download, .remove, .unavailable] {
          let actions = PlayerOverflowMenuPresentation.actions(
            downloadAction: download, includesHistory: includesHistory, playbackStatus: status)
          #expect(actions.first == .viewDetails)
          #expect(actions.filter { $0 == .viewDetails }.count == 1)
        }
      }
    }
  }

  /// The same shape as every item menu: the
  /// progress pair folds into one submenu, and the removal is the last row.
  @Test("the progress pair folds into a submenu and the removal sits last")
  func overflowSectionsFoldProgressAndEndWithTheRemoval() {
    let actions = PlayerOverflowMenuPresentation.actions(
      downloadAction: .remove, includesHistory: true, includesAddBookmark: true,
      includesLookBack: true, playbackStatus: .inProgress)
    #expect(
      PlayerOverflowMenuPresentation.sections(actions) == [
        [.action(.addBookmark)],
        [.action(.viewDetails), .action(.lookBack), .action(.history)],
        [.submenu(.progress, [.markAsFinished, .resetProgress])],
        [.action(.deleteDownload)],
      ])

    // A single progress entry stays a plain row.
    let finished = PlayerOverflowMenuPresentation.actions(
      downloadAction: .download, includesHistory: false, playbackStatus: .finished)
    #expect(
      PlayerOverflowMenuPresentation.sections(finished)
        == [[.action(.viewDetails)], [.action(.download)], [.action(.resetProgress)]])
  }

  /// Transcript and Look Back are frequent actions (owner constraint): never behind a submenu.
  @Test("Transcript and Look Back are always top-level rows")
  func transcriptAndLookBackNeverFold() {
    for includesTranscript in [true, false] {
      for status: ItemPlaybackStatus? in [nil, .inProgress, .finished] {
        let actions = PlayerOverflowMenuPresentation.actions(
          downloadAction: .remove, includesHistory: true, supplementCount: 1,
          includesAddBookmark: true, includesTranscript: includesTranscript,
          includesLookBack: includesTranscript == false, playbackStatus: status)
        let topLevel = PlayerOverflowMenuPresentation.sections(actions).joined()
        let surfaced: PlayerOverflowMenuPresentation.Entry =
          includesTranscript ? .action(.transcript) : .action(.lookBack)
        #expect(topLevel.contains(surfaced))
        #expect(
          topLevel.allSatisfy { entry in
            guard case .submenu(_, let members) = entry else { return true }
            return members.contains(.transcript) == false && members.contains(.lookBack) == false
          })
      }
    }
  }

  @Test("View Details and History are the same family, so no separator divides them")
  func viewDetailsSharesTheSurfaceGroupWithHistory() {
    #expect(PlayerOverflowMenuPresentation.group(.viewDetails) == .surface)
    #expect(PlayerOverflowMenuPresentation.group(.history) == .surface)
  }

  @Test("the overflow menu is offered for a podcast episode as well as an item")
  func overflowMenuIsOfferedForEveryScope() {
    #expect(PlayerQuickActionsPresentation.showsOverflowMenu(episodeID: nil))
    #expect(PlayerQuickActionsPresentation.showsOverflowMenu(episodeID: "ep-1"))
  }

  @Test("chapters is hidden outright for a podcast episode, not shown disabled")
  func chaptersIsHiddenForAnEpisode() {
    #expect(PlayerQuickActionsPresentation.showsChapters(episodeID: nil))
    #expect(PlayerQuickActionsPresentation.showsChapters(episodeID: "ep-1") == false)
  }

  /// Chapters live on the metadata chapter row, and More on the title's trailing edge. The
  /// `BottomAction` type has no case for either, so the bottom row cannot render them by mistake.
  /// Up Next is unconditional for both media types: Sleep · Speed · AirPlay · Up Next throughout.
  @Test("the bottom quick-action row is four playback controls for either media kind")
  func bottomActionsAreThePlaybackControlsOnly() {
    let audiobookActions = PlayerQuickActionsPresentation.bottomActions(episodeID: nil)
    let episodeActions = PlayerQuickActionsPresentation.bottomActions(episodeID: "ep-1")

    let expected: [PlayerQuickActionsPresentation.BottomAction] =
      [.sleepTimer, .playbackRate, .audioRoute, .upNext]
    #expect(audiobookActions == expected)
    #expect(episodeActions == expected)
    #expect(audiobookActions.firstIndex(of: .audioRoute) == 2)
    #expect(episodeActions.firstIndex(of: .audioRoute) == 2)
  }

  /// Up Next follows audio routing for an audiobook exactly as it does for an episode. Its label
  /// never grows a badge or a count, and it closes the row.
  @Test("both media types offer Up Next, in the same slot")
  func bothMediaTypesOfferUpNextInTheSameSlot() {
    #expect(
      PlayerQuickActionsPresentation.bottomActions(episodeID: nil).firstIndex(of: .upNext) == 3)
    #expect(
      PlayerQuickActionsPresentation.bottomActions(episodeID: "ep-1").firstIndex(of: .upNext) == 3)
  }

  @Test("playback-rate menu keeps preset order and includes a custom current speed")
  func playbackRateOptionsIncludeCurrentCustomRate() {
    let options = PlaybackRateMenuPresentation.options(
      encodedPresets: "0.75,1,1.5,2", currentRate: 1.35)

    #expect(options.map(\.rate) == [0.75, 1, 1.5, 2, 1.35])
    #expect(options.last?.isSelected == true)
  }

  @Test("playback-rate menu does not duplicate a selected preset")
  func playbackRateOptionsSelectExistingPreset() {
    let options = PlaybackRateMenuPresentation.options(
      encodedPresets: "0.75,1,1.5,2", currentRate: 1.5)

    #expect(options.map(\.rate) == [0.75, 1, 1.5, 2])
    #expect(options.filter(\.isSelected).map(\.rate) == [1.5])
  }

  /// The speed card lays presets out as equal-width buttons. Four fit across a phone at standard
  /// text sizes; past that the grid gains rows, balanced so no row is left nearly empty (six is
  /// 3 + 3, not 4 + 2). Accessibility text sizes drop to two columns so a label is never cut off.
  @Test(
    "speed card grid holds at most four columns and stays balanced",
    arguments: [
      (0, false, 0), (1, false, 1), (4, false, 4), (5, false, 3), (6, false, 3), (7, false, 4),
      (8, false, 4), (9, false, 3), (1, true, 1), (6, true, 2), (7, true, 2),
    ])
  func speedCardGridColumns(count: Int, isAccessibilitySize: Bool, expected: Int) {
    #expect(
      PlaybackRateMenuPresentation.gridColumnCount(
        optionCount: count, isAccessibilitySize: isAccessibilitySize) == expected)
  }

  /// Eight saved shortcuts is the cap; a ninth button appears only for a custom current speed, and
  /// it must be in the grid too, or the card could not show which speed is playing.
  @Test("a custom current speed joins the card's options as the selected one")
  func customCurrentSpeedIsOffered() {
    let presets: [Double] = (0..<8).map { 0.5 + Double($0) * 0.25 }
    let encoded = presets.map { "\($0)" }.joined(separator: ",")
    let options = PlaybackRateMenuPresentation.options(
      encodedPresets: encoded, currentRate: 1.35)
    #expect(options.count == 9)
    #expect(options.filter(\.isSelected).map(\.rate) == [1.35])
  }

  /// A title on screen but not loaded into the player has an idle player that reports 1×. Showing
  /// that rate would make a picked speed look ignored, so the card shows the title's own speed.
  @Test("the speed control shows the title's own speed unless it is the live item")
  func displayedRateFollowsTheTitleUnlessLive() {
    #expect(
      PlaybackRateMenuPresentation.displayedRate(
        isLiveItem: true, liveRate: 1.25, titleRate: 1.5) == 1.25)
    #expect(
      PlaybackRateMenuPresentation.displayedRate(
        isLiveItem: false, liveRate: 1, titleRate: 1.5) == 1.5)
  }

  @Test("sleep timer offers the completion option for the current media kind")
  func sleepTimerCompletionOptionFollowsTheCurrentMediaKind() {
    #expect(
      SleepTimerMenuPresentation.options(
        encodedPresets: "15,30", completion: nil)
        == [.minutes(15), .minutes(30)])
    #expect(
      SleepTimerMenuPresentation.options(
        encodedPresets: "15,30", completion: .chapter)
        == [.minutes(15), .minutes(30), .endOf(.chapter)])
    #expect(
      SleepTimerMenuPresentation.options(
        encodedPresets: "15,30", completion: .episode)
        == [.minutes(15), .minutes(30), .endOf(.episode)])
  }

  @Test("the item-boundary option is offered only for the matching live item")
  func sleepTimerCompletionRequiresTheLiveItem() {
    #expect(
      SleepTimerMenuPresentation.completion(
        isLiveItem: true, episodeID: "episode", liveItemHasChapters: false) == .episode)
    #expect(
      SleepTimerMenuPresentation.completion(
        isLiveItem: true, episodeID: nil, liveItemHasChapters: true) == .chapter)
    #expect(
      SleepTimerMenuPresentation.completion(
        isLiveItem: true, episodeID: nil, liveItemHasChapters: false) == nil)
    #expect(
      SleepTimerMenuPresentation.completion(
        isLiveItem: false, episodeID: "episode", liveItemHasChapters: true) == nil)
  }

  @Test("an item-boundary timer uses the current media kind in its active label")
  func sleepTimerCompletionLabelFollowsTheCurrentMediaKind() {
    let timer = SleepTimerState(mode: .endOfChapter(atPosition: 1_200))

    #expect(
      SleepTimerMenuPresentation.activeLabel(for: timer, completion: .chapter)
        == (compact: "Chapter", accessible: "Until end of chapter"))
    #expect(
      SleepTimerMenuPresentation.activeLabel(for: timer, completion: .episode)
        == (compact: "Episode", accessible: "Until end of episode"))
  }

  @Test("sleep timer offers Turn Off only while a timer is active")
  func turnOffFollowsTimerActivity() {
    #expect(SleepTimerMenuPresentation.showsTurnOff(for: .off) == false)
    #expect(
      SleepTimerMenuPresentation.showsTurnOff(
        for: SleepTimerState(mode: .countdown(remainingSeconds: 600))) == true)
    #expect(
      SleepTimerMenuPresentation.showsTurnOff(
        for: SleepTimerState(mode: .endOfChapter(atPosition: 1_200))) == true)
  }

  @Test("a running preset timer marks its own row, and never a row it was not set from")
  func selectionFollowsTheConfiguredChoice() {
    #expect(
      SleepTimerMenuPresentation.selectionID(mode: .off, completion: .chapter) == nil)
    #expect(
      SleepTimerMenuPresentation.selectionID(
        mode: .countdown(configuredSeconds: 1_200), completion: .chapter)
        == SleepTimerMenuPresentation.Option.minutes(20).id)
    #expect(
      SleepTimerMenuPresentation.selectionID(mode: .endOfChapter, completion: .chapter)
        == SleepTimerMenuPresentation.Option.endOf(.chapter).id)
    #expect(
      SleepTimerMenuPresentation.selectionID(mode: .endOfChapter, completion: .episode)
        == SleepTimerMenuPresentation.Option.endOf(.episode).id)
    // A boundary timer with no boundary row in the menu: nothing to mark.
    #expect(
      SleepTimerMenuPresentation.selectionID(mode: .endOfChapter, completion: nil) == nil)
  }

  @Test("a timer the menu cannot name marks nothing rather than the nearest preset")
  func selectionIsAbsentForUnnameableTimers() {
    // Extended, or otherwise not traceable to a choice.
    #expect(
      SleepTimerMenuPresentation.selectionID(
        mode: .countdown(configuredSeconds: nil), completion: .chapter) == nil)
    // A custom value that is not a whole number of minutes.
    #expect(
      SleepTimerMenuPresentation.selectionID(
        mode: .countdown(configuredSeconds: 450), completion: .chapter) == nil)
    #expect(
      SleepTimerMenuPresentation.selectionID(
        mode: .countdown(configuredSeconds: 0), completion: .chapter) == nil)
  }

  @Test("each menu row sets the timer its own label promises")
  func optionsMapToTheirIntents() {
    #expect(
      SleepTimerMenuPresentation.duration(for: .minutes(25)) == .custom(seconds: 1_500))
    #expect(SleepTimerMenuPresentation.duration(for: .endOf(.chapter)) == .endOfChapter)
    #expect(SleepTimerMenuPresentation.duration(for: .endOf(.episode)) == .endOfItem)
  }
}

/// Where the player's View Details entry goes. Both legs leave playback alone. A book collapses
/// the player to the mini bar rather than stopping it, and an episode's card is raised over the
/// player. These assertions cover destination and duplication only.
@Suite("Player details navigation")
struct PlayerDetailsNavigationPresentationTests {

  @Test("a book resolves to its pushed item-detail route")
  func bookResolvesToItemDetail() {
    #expect(
      PlayerDetailsNavigationPresentation.destination(itemID: "book-1", episodeID: nil)
        == .itemDetail(itemID: "book-1"))
  }

  /// Not the show page: the byline directly above this menu already opens that, and a second entry
  /// for it would name one destination twice.
  @Test("an episode resolves to its own card, not to the show the byline already opens")
  func episodeResolvesToItsCard() {
    #expect(
      PlayerDetailsNavigationPresentation.destination(itemID: "show-1", episodeID: "ep-1")
        == .episodeCard(
          NavigationModel.PodcastEpisodeRef(itemID: "show-1", episodeID: "ep-1")))
  }

  @Test("an empty identity has nowhere to go")
  func emptyIdentityResolvesToNothing() {
    #expect(PlayerDetailsNavigationPresentation.destination(itemID: "", episodeID: nil) == nil)
    // An empty episode id is a book identity that happened to carry one, not a nameless episode.
    #expect(
      PlayerDetailsNavigationPresentation.destination(itemID: "book-1", episodeID: "")
        == .itemDetail(itemID: "book-1"))
  }

  /// Open a book, press play, and the player rises over the very page this entry pushes. Pushing
  /// again would stack that page on itself, behind a back chevron to an identical view.
  @Test("a detail page already on top of the stack is not pushed a second time")
  func itemDetailOnTopIsNotPushedAgain() {
    let destination = PlayerDetailsNavigationPresentation.Destination.itemDetail(itemID: "book-1")

    #expect(
      PlayerDetailsNavigationPresentation.isAlreadyShowing(
        destination, path: [.itemDetail(itemID: "book-1")]))
    #expect(PlayerDetailsNavigationPresentation.isAlreadyShowing(destination, path: []) == false)
    #expect(
      PlayerDetailsNavigationPresentation.isAlreadyShowing(
        destination, path: [.itemDetail(itemID: "book-2")]) == false)
  }

  /// A detail page buried under later pushes is not what collapsing the player would reveal, so
  /// going there is a real navigation.
  @Test("a detail page beneath later pushes is still a destination")
  func itemDetailBelowTheTopIsStillPushed() {
    #expect(
      PlayerDetailsNavigationPresentation.isAlreadyShowing(
        .itemDetail(itemID: "book-1"),
        path: [.itemDetail(itemID: "book-1"), .authorName(name: "Matt Dinniman")]) == false)
  }

  /// The card is raised over the player, not revealed beneath it, so nothing under the player
  /// can duplicate it, whatever the stack holds.
  @Test("an episode card is never already showing")
  func episodeCardIsNeverAlreadyShowing() {
    let ref = NavigationModel.PodcastEpisodeRef(itemID: "show-1", episodeID: "ep-1")

    #expect(
      PlayerDetailsNavigationPresentation.isAlreadyShowing(.episodeCard(ref), path: []) == false)
    #expect(
      PlayerDetailsNavigationPresentation.isAlreadyShowing(
        .episodeCard(ref), path: [.podcastShow(itemID: "show-1")]) == false)
  }

  private static func book(_ id: String) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "book", title: "Platform Decay", author: "Martha Wells",
      durationSeconds: 3_600, category: .audiobook)
  }

  /// The page beneath the player must be complete on its first frame, so the push carries the
  /// player's own loaded summary the way every card tap does; without one it is the cold route.
  @Test("the pushed route carries the player's loaded summary as its seed")
  func routeIsSeededFromTheLoadedSummary() {
    let seed = Self.book("book-1")

    #expect(
      PlayerDetailsNavigationPresentation.route(itemID: "book-1", seed: seed)
        == .itemDetail(itemID: "book-1", seed: seed))
    #expect(
      PlayerDetailsNavigationPresentation.route(itemID: "book-1", seed: nil)
        == .itemDetail(itemID: "book-1", seed: nil))
    if case .itemDetail(_, let carried) = PlayerDetailsNavigationPresentation.route(
      itemID: "book-1", seed: seed)
    {
      #expect(carried == seed)
    } else {
      Issue.record("a book resolves to an item-detail route")
    }
  }

  /// The player fades only into a page that shares its subject and is already painted: a seeded
  /// push or the page it rose from. Everything else slides.
  @Test("a seeded or already-showing book page takes the dissolve; every other collapse slides")
  func collapseStyleFollowsTheDissolveTable() {
    let book = PlayerDetailsNavigationPresentation.Destination.itemDetail(itemID: "book-1")

    #expect(
      PlayerDetailsNavigationPresentation.collapseStyle(
        for: book, itemDetailPresentation: .push, isSeeded: true, isAlreadyShowing: false)
        == .dissolve)
    #expect(
      PlayerDetailsNavigationPresentation.collapseStyle(
        for: book, itemDetailPresentation: .push, isSeeded: false, isAlreadyShowing: true)
        == .dissolve)
    // An unseeded push lands on a spinner; fading onto it would be worse than the slide.
    #expect(
      PlayerDetailsNavigationPresentation.collapseStyle(
        for: book, itemDetailPresentation: .push, isSeeded: false, isAlreadyShowing: false)
        == .slide)
    // Regular width presents the page as a shell-level card that cannot rise until the player
    // has gone, so the collapse uncovers the section root, not the book.
    #expect(
      PlayerDetailsNavigationPresentation.collapseStyle(
        for: book, itemDetailPresentation: .card, isSeeded: true, isAlreadyShowing: false)
        == .slide)
    #expect(
      PlayerDetailsNavigationPresentation.collapseStyle(
        for: .episodeCard(NavigationModel.PodcastEpisodeRef(itemID: "show-1", episodeID: "ep-1")),
        itemDetailPresentation: .push, isSeeded: true, isAlreadyShowing: true)
        == .slide)
  }
}
