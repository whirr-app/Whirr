import Persistence
import Testing

@testable import AppModel

/// Root layout, the navigation budget, list capacity and feedback.
@Suite struct CarPlayPresentationTests {
  // MARK: - Root layout

  @Test func fourTabsWhenTheCarAllowsThem() {
    #expect(CarPlayRootLayout(maximumTabCount: 4) == .tabs(CarPlayTab.allCases))
    #expect(CarPlayRootLayout(maximumTabCount: 5) == .tabs(CarPlayTab.allCases))
  }

  @Test(arguments: [0, 1, 3])
  func fewerPermittedTabsUseOneRootList(maximum: Int) {
    #expect(CarPlayRootLayout(maximumTabCount: maximum) == .list(CarPlayTab.allCases))
  }

  // MARK: - Navigation budget

  @Test func deepestTabRouteLeavesNowPlayingAtLevelThree() throws {
    var navigation = CarPlayNavigation()
    #expect(navigation.show(.list(.showEpisodes(itemID: "show"))) == [.push(.list(.showEpisodes(itemID: "show")))])
    #expect(navigation.show(.nowPlaying) == [.push(.nowPlaying)])
    #expect(navigation.show(.chapters) == [.push(.chapters)])
    #expect(navigation.depth == 4)
  }

  @Test func deepestRootListRouteEndsAtLevelFive() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.tab(.podcasts))
    _ = navigation.show(.list(.showEpisodes(itemID: "show")))
    _ = navigation.show(.nowPlaying)
    #expect(navigation.depth == 4)
    #expect(navigation.show(.upNext) == [.push(.upNext)])
    #expect(navigation.depth == CarPlayNavigation.maximumDepth)
  }

  @Test func browseListThatWouldPushNowPlayingPastLevelFourIsRefused() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.tab(.podcasts))
    _ = navigation.show(.list(.podcastShows))
    #expect(navigation.show(.list(.showEpisodes(itemID: "show"))) == nil)
    #expect(navigation.depth == 3)
  }

  @Test func showingTheTopScreenAgainPushesNothing() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.nowPlaying)
    #expect(navigation.show(.nowPlaying) == [])
    #expect(navigation.depth == 2)
  }

  @Test func chapterSelectionReturnsToTheExistingNowPlaying() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.nowPlaying)
    _ = navigation.show(.chapters)
    #expect(navigation.show(.nowPlaying) == [.pop(to: .nowPlaying)])
    #expect(navigation.stack == [.root, .nowPlaying])
  }

  @Test func upNextReplacesChaptersAboveNowPlaying() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.nowPlaying)
    _ = navigation.show(.chapters)
    #expect(navigation.show(.upNext) == [.pop(to: .nowPlaying), .push(.upNext)])
    #expect(navigation.stack == [.root, .nowPlaying, .upNext])
  }

  @Test func chaptersAndUpNextNeedNowPlayingBeneathThem() {
    var navigation = CarPlayNavigation()
    #expect(navigation.show(.chapters) == nil)
    #expect(navigation.show(.upNext) == nil)
  }

  @Test func browsingFromAboveNowPlayingIsRefused() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.nowPlaying)
    #expect(navigation.show(.list(.audiobooks)) == nil)
  }

  @Test func systemOpenedNowPlayingIsTrackedOnce() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.list(.audiobooks))
    navigation.appeared(.nowPlaying)
    navigation.appeared(.nowPlaying)
    #expect(navigation.stack == [.root, .list(.audiobooks), .nowPlaying])
    #expect(navigation.show(.chapters) == [.push(.chapters)])
  }

  @Test func backButtonIsFollowed() {
    var navigation = CarPlayNavigation()
    _ = navigation.show(.list(.audiobooks))
    _ = navigation.show(.nowPlaying)
    navigation.appeared(.list(.audiobooks))
    #expect(navigation.stack == [.root, .list(.audiobooks)])
    navigation.reset()
    #expect(navigation.stack == [.root])
  }

  // MARK: - List capacity

  @Test func pageSizeLeavesRoomForBothPageControls() {
    #expect(CarPlayListLayout.pageSize(maximumItemCount: 12, productLimit: 40) == 10)
    #expect(CarPlayListLayout.pageSize(maximumItemCount: 500, productLimit: 40) == 40)
  }

  @Test func tooSmallAListDoesNotPage() {
    #expect(CarPlayListLayout.pageSize(maximumItemCount: 5, productLimit: 40) == nil)
  }

  @Test func pageControlsAreCountedAgainstTheItemLimit() {
    let layout = CarPlayListLayout(
      rows: Self.rows(10), hasPrevious: true, hasNext: true, maximumItemCount: 12)
    #expect(layout.rows.count == 10)
    #expect(layout.showsPrevious)
    #expect(layout.showsNext)
    #expect(layout.isTruncated == false)
    #expect(layout.itemCount == 12)
  }

  @Test func listWithoutRoomForControlsShowsABoundedPrefixAndSaysSo() {
    let layout = CarPlayListLayout(rows: Self.rows(10), hasPrevious: false, hasNext: true, maximumItemCount: 5)
    #expect(layout.rows.map(\.id) == Self.rows(5).map(\.id))
    #expect(layout.showsNext == false)
    #expect(layout.isTruncated)
  }

  @Test func observedListLongerThanTheCarAllowsIsTruncated() {
    let layout = CarPlayListLayout(rows: Self.rows(20), hasPrevious: false, hasNext: false, maximumItemCount: 12)
    #expect(layout.rows.count == 12)
    #expect(layout.isTruncated)
  }

  @Test func zeroCapacityShowsNothing() {
    let layout = CarPlayListLayout(rows: Self.rows(3), hasPrevious: false, hasNext: false, maximumItemCount: 0)
    #expect(layout.rows.isEmpty)
    #expect(layout.isTruncated)
  }

  // MARK: - Feedback

  @Test func startedSelectionShowsNowPlaying() {
    #expect(CarPlayFeedback(CarPlaySelectionOutcome.started) == .showNowPlaying)
  }

  @Test(arguments: [CarPlaySelectionOutcome.superseded, .cancelled, .failed(.cancelled)])
  func replacedOrCancelledSelectionShowsNothing(outcome: CarPlaySelectionOutcome) {
    #expect(CarPlayFeedback(outcome) == .none)
  }

  @Test func staleRowReloadsItsListWithoutAnAlert() {
    #expect(CarPlayFeedback(.failed(.staleGeneration)) == .reload)
  }

  @Test func failedStartOffersRetry() throws {
    guard case .alert(let alert) = CarPlayFeedback(.failed(.preparationFailed)) else {
      Issue.record("expected an alert")
      return
    }
    #expect(alert.canRetry)
    #expect(alert.titleVariants.isEmpty == false)
  }

  @Test(arguments: [
    CarPlayPlaybackRejection.accountUnavailable, .invalidSelection, .nothingToResume,
  ])
  func failureThatRetryCannotFixOffersOnlyDismiss(rejection: CarPlayPlaybackRejection) {
    guard case .alert(let alert) = CarPlayFeedback(.failed(rejection)) else {
      Issue.record("expected an alert")
      return
    }
    #expect(alert.canRetry == false)
  }

  @Test func lateFailureOffersRetryOnlyWhenRecoverable() {
    #expect(CarPlayFeedback(CarPlayLateFailure.failed(isRecoverable: true)).alert?.canRetry == true)
    #expect(CarPlayFeedback(CarPlayLateFailure.failed(isRecoverable: false)).alert?.canRetry == false)
    #expect(CarPlayFeedback(CarPlayLateFailure.stalled).alert?.canRetry == true)
  }

  @Test func alertTitlesRunLongestFirstAndCarryNoPayload() {
    for rejection in [CarPlayPlaybackRejection.preparationFailed, .accountUnavailable, .nothingToResume] {
      let titles = CarPlayFeedback(.failed(rejection)).alert?.titleVariants ?? []
      #expect(titles == titles.sorted { $0.count > $1.count })
    }
  }

  // MARK: - Status

  @Test func everyRootStateButReadyHasAMessage() {
    #expect(CarPlayRootState.ready.message == nil)
    for state in [CarPlayRootState.starting, .unlockPhone, .signedOut, .unavailable] {
      #expect(state.message != nil)
    }
  }

  @Test func everyRouteSaysWhatAnEmptyListMeans() {
    let routes: [CarPlayBrowseRoute] = [
      .continueListening, .upNext, .recentBooks, .audiobooks, .podcastShows, .showEpisodes(itemID: "a"),
      .downloads,
    ]
    #expect(Set(routes.map(\.emptyMessage)).count == routes.count)
  }

  private static func rows(_ count: Int) -> [CarPlayBrowseRow] {
    (0..<count).map {
      CarPlayBrowseRow(id: "row\($0)", identity: nil, title: "Row \($0)", subtitle: nil, artwork: .none)
    }
  }
}
