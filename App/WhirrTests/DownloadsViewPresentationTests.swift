import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite("Downloads presentation")
@MainActor
struct DownloadsViewPresentationTests {
  @Test("loading and empty downloads keep a non-intercepting overlay over the list")
  func statePlaceholdersStayOverTheMountedList() {
    let loading = DownloadsViewPresentation.placeholder(
      homeState: .loading, hasLoadedDownloadedItems: false, hasRows: false)
    #expect(loading?.allowsHitTesting == false)

    let empty = DownloadsViewPresentation.placeholder(
      homeState: .loaded, hasLoadedDownloadedItems: true, hasRows: false)
    #expect(empty?.allowsHitTesting == false)

    let emptyHome = DownloadsViewPresentation.placeholder(
      homeState: .empty, hasLoadedDownloadedItems: true, hasRows: true)
    #expect(emptyHome?.allowsHitTesting == false)

    #expect(
      DownloadsViewPresentation.placeholder(
        homeState: .loaded, hasLoadedDownloadedItems: true, hasRows: true) == nil)
  }

  @Test("a downloaded episode's published date uses the pinned GMT calendar")
  func episodeDetailUsesThePinnedGMTCalendar() {
    let episode = PodcastEpisodeSummary(
      id: "episode", title: "Episode", subtitle: nil, episodeDescription: nil, seasonNumber: nil,
      episodeNumber: nil, episodeType: nil, durationSeconds: 3_600, sizeBytes: nil,
      publishedAt: Date(timeIntervalSince1970: 1_718_494_200), progressSeconds: 0,
      isPlayed: false, isFinished: false, downloadStatus: .completed,
      isAvailableOnServer: true)

    #expect(DownloadsViewPresentation.episodeDetail(episode) == "Jun 15, 2024")
  }

  @Test("podcasts use the system disclosure interaction")
  func podcastDisclosure() {
    #expect(DownloadsViewPresentation.podcastExpansion == .systemDisclosure)
  }

  @Test("folder content preserves loading, empty, and unavailable states")
  func folderContentPreservesItsState() {
    // `.loading` with no episodes is the first frame of every folder, even one with downloads.
    // Reading the count alone would print "No downloaded episodes" under such a show. Settled
    // offline, error and partial states must keep their reason too.
    for state in PodcastShowModel.State.allCases {
      let content = DownloadsViewPresentation.episodeFolderContent(
        state: state, hasEpisodes: false)
      switch state {
      case .loading:
        #expect(content == .loading)
      case .empty, .loaded, .refreshing:
        #expect(content == .empty)
      case .staleOffline, .recoverableError, .partiallyDecoded:
        #expect(content == .unavailable(state))
      }
    }
  }

  @Test("a failed podcast episode load is not reported as an empty folder")
  func failedEpisodeLoadIsNotReportedAsEmpty() {
    for state in [
      PodcastShowModel.State.staleOffline,
      .recoverableError,
      .partiallyDecoded,
    ] {
      #expect(
        DownloadsViewPresentation.episodeFolderContent(state: state, hasEpisodes: false)
          == .unavailable(state))
    }
  }

  @Test("episodes win over every state, including one still loading or in error")
  func episodesWinOverState() {
    for state in PodcastShowModel.State.allCases {
      #expect(
        DownloadsViewPresentation.episodeFolderContent(state: state, hasEpisodes: true)
          == .episodes)
    }
  }

  @Test("a show's episode observation opens with its row, not with its first expansion")
  func episodeObservationWarmsOnRowAppearance() {
    // Opening it at expansion time leaves the disclosure animating against empty content, so the
    // first expand of a folder would not animate.
    #expect(DownloadsViewPresentation.episodeObservationWarmUp == .whenRowAppears)
  }

  @Test("destructive row actions live behind a deliberate trailing swipe")
  func rowDeletion() {
    #expect(DownloadsViewPresentation.deleteInteraction == .trailingSwipe)
    #expect(DownloadsViewPresentation.allowsFullSwipeToDelete == false)
    #expect(DownloadsViewPresentation.deleteActionTint == .destructiveRed)
  }

  @Test("the delete swipe button is red by statement and carries no destructive role")
  func swipeDeleteButtonIsTintedNotRoled() throws {
    // The scene tint is near-white, so an unstated swipe capsule would be white under a white
    // glyph. `.destructive` inside `swipeActions` collapses the row as the swipe closes, before the
    // confirmation is answered. That is both the snap-back and the vanished alert.
    #expect(DownloadsViewPresentation.swipeDeleteButtonRole == .none)

    let text = try Self.executableText(for: "DownloadsViewRows.swift")
    let helper = try #require(text.range(of: "func downloadDeleteSwipeAction"))
    let helperText = String(text[helper.lowerBound...])
    #expect(ViewSourceScan.occurrences(of: ["Button(action: action)"], in: helperText) == 1)
    #expect(
      ViewSourceScan.occurrences(of: ["Button(role: .destructive, action: action)"], in: helperText)
        == 1)
    #expect(ViewSourceScan.occurrences(of: [".tint(.red)"], in: helperText) == 1)
  }

  @Test("a confirmed removal leaves under a transaction the List can animate")
  func removalsAnimateFromMirroredMembership() {
    // A `List` animates a row diff only when the state change carries the transaction. These rows
    // are removed by a persistence observation, so the screen mirrors membership into its own
    // state under `withAnimation`. The first population, under the loading overlay, is not
    // animated.
    #expect(DownloadsViewPresentation.animatesRowMembershipChange(wasEmpty: true) == false)
    #expect(DownloadsViewPresentation.animatesRowMembershipChange(wasEmpty: false))
    #expect(
      DownloadsViewPresentation.rowRemovalMotion(reduceMotion: false)
        == HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: false).animation)
    #expect(
      DownloadsViewPresentation.rowRemovalMotion(reduceMotion: true)
        == HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: true).animation)
  }

  @Test("purge confirmation uses an unanchored alert hosted on the screen")
  func purgeConfirmation() {
    // A confirmation dialog anchors to its presenting view. Hosting it on the screen, which the
    // swipe-row teardown forces, parks it at the top of the window, away from the row.
    #expect(DownloadsViewPresentation.purgeConfirmation == .systemAlert)
    #expect(DownloadsViewPresentation.purgeConfirmationAnchor == .stableDownloadsScreen)
  }

  @Test("episode deletion confirms from the screen, not from the row that is torn down")
  func episodeDeleteConfirmationHost() {
    #expect(DownloadsViewPresentation.episodeDeleteConfirmationHost == .downloadsScreen)
  }

  @Test("dismissing a confirmation is not the same as cancelling it")
  func confirmationDismissalIsNotACancellation() {
    // An alert writes `false` to its `isPresented` binding on every dismissal, including the one
    // its Delete button causes, and may do so before that button's action runs. Treating that
    // write as a cancel withdraws the confirmation the user has just given.
    #expect(DownloadsViewPresentation.confirmationDismissal == .resolvedByItsButtons)
  }

  @Test("a podcast row's swipe action does not depend on its expansion state")
  func podcastSwipeActionIsExpansionIndependent() {
    // Expanding inserts the episode rows. If the parent row's swipe structure also changes in that
    // collection-view batch update, the planned and applied item counts can disagree, and the
    // update aborts with `Invalid_Number_Of_Items_In_Section`.
    #expect(DownloadsViewPresentation.podcastDeleteActionVisibility == .always)
    #expect(DownloadsViewPresentation.podcastDeleteActionPlacement == .disclosureLabel)
    #expect(DownloadsViewPresentation.installsPodcastDeleteSwipeAction(isExpanded: false))
    #expect(DownloadsViewPresentation.installsPodcastDeleteSwipeAction(isExpanded: true))
  }

  @Test("device downloads use the shared source-neutral copy")
  func deviceDownloadsUseSourceNeutralPresentation() {
    // Same eyebrow · title · "kind · size" shape as a server podcast's row. The author sits above
    // the title when there is one. No "Podcast" eyebrow, which would duplicate the badge.
    #expect(RSSDownloadsViewPresentation.feedEyebrow(author: "Host") == "Host")
    #expect(RSSDownloadsViewPresentation.feedEyebrow(author: "") == nil)
    #expect(RSSDownloadsViewPresentation.feedEyebrow(author: nil) == nil)
    #expect(
      RSSDownloadsViewPresentation.feedMetadata(totalBytes: 51_500_000)
        == "Podcast · \(StorageCopy.itemSizeDetail(totalBytes: 51_500_000, removedEpisodeBytes: 0))")
    #expect(
      RSSDownloadsViewPresentation.feedDeleteAction(title: "A Show")
        == "Remove downloads for A Show")
    #expect(RSSDownloadsViewPresentation.episodeDeleteTitle(title: "Episode") == "Remove “Episode”?")
    #expect(
      RSSDownloadsViewPresentation.episodeDeleteMessage
        == "This removes the downloaded episode from this device.")
    #expect(
      RSSDownloadsViewPresentation.episodeDeleteMessage
        == DownloadsViewPresentation.episodeDeleteMessage)
  }

  @Test("device feeds never enter the item block; RSSDownloadsView is their only renderer")
  func absItemIDsExcludeDeviceFeeds() {
    // Storage lists device feeds as `rss:` rows so the totals cover the whole device. The Home
    // model's downloaded section carries the same feeds under the same ids, so intersect them
    // only with the source in mind. Ignoring the source draws every feed twice, as an item card
    // and as its RSS row.
    let rows = [
      StorageModel.ItemRow(itemId: "abs-book", title: "Book"),
      StorageModel.ItemRow(itemId: "rss:41", title: "Feed", source: .rss),
      StorageModel.ItemRow(itemId: "abs-podcast", title: "Show", source: .abs),
    ]
    #expect(
      DownloadsViewPresentation.absItemIDs(from: rows) == ["abs-book", "abs-podcast"])
    #expect(DownloadsViewPresentation.absItemIDs(from: []).isEmpty)
  }

  @Test("merged downloads retain source identity and hide dormant RSS rows")
  func mergedDownloadsRespectNativeVisibility() {
    #expect(
      DownloadsViewPresentation.mergedRows(
        absItemIDs: ["abs-book", "abs-podcast"], rssFeedIDs: [41, 79],
        nativeSubscriptionsEnabled: true)
        == [
          .abs(itemID: "abs-book"),
          .abs(itemID: "abs-podcast"),
          .rss(feedID: 41),
          .rss(feedID: 79),
        ])
    #expect(
      DownloadsViewPresentation.mergedRows(
        absItemIDs: ["abs-book"], rssFeedIDs: [41],
        nativeSubscriptionsEnabled: false)
        == [.abs(itemID: "abs-book")])
    #expect(
      DownloadsViewPresentation.mergedRows(
        absItemIDs: [], rssFeedIDs: [41], nativeSubscriptionsEnabled: false
      )
      .isEmpty)
  }

  @Test("selection identities are source qualified and parent selections deduplicate children")
  func selectionPlanPrunesStaleRowsAndDuplicateParentChildren() {
    let item = DownloadsViewPresentation.SelectionID.absItem("same")
    let child = DownloadsViewPresentation.SelectionID.absEpisode(itemID: "same", episodeID: "ep")
    let rssChild = DownloadsViewPresentation.SelectionID.rssEpisode(feedID: 7, episodeID: "same")
    let eligible: Set<DownloadsViewPresentation.SelectionID> = [item, child, rssChild]

    let plan = DownloadsViewPresentation.selectionPlan(
      selected: [item, child, rssChild, .rssFeed(99)], eligible: eligible)

    #expect(plan.absItemIDs == ["same"])
    #expect(plan.absEpisodeIDs.isEmpty)
    #expect(plan.rssEpisodeIDs.count == 1)
    #expect(plan.rssFeedIDs.isEmpty)
  }

  private static func executableText(for filename: String) throws -> String {
    let source = try #require(
      try ViewSourceScan.sources().first { $0.lastPathComponent == filename })
    return try ViewSourceScan.executableText(of: source)
  }
}
