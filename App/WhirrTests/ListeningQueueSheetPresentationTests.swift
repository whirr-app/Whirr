import AppModel
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// The queue sheet inherits `.tint(Color.primary)` and an ambient dark presentation from the
/// expanded player that presents it. Anything inside it that relies on a default tint resolves
/// against the wrong appearance. The source facts about the sheet (edits keyed by row, no
/// notification-weight haptic) are in `Scripts/source-rules/up-next.toml`.
@Suite("Listening queue sheet swipe and feedback composition")
struct ListeningQueueSheetCompositionTests {
  @Test("two chapter rows of one book have distinct accessibility identifiers")
  func rowIdentifierCarriesTheRow() throws {
    let book = try #require(ListeningIdentity.audiobook(itemID: "book"))
    let episode = try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "e"))

    #expect(
      PlayerAccessibilityID.queueRow(identity: book, rowID: 1)
        != PlayerAccessibilityID.queueRow(identity: book, rowID: 2))
    #expect(PlayerAccessibilityID.queueRow(identity: book, rowID: 1) == "player.queue.book.row.1")
    #expect(
      PlayerAccessibilityID.queueRow(identity: episode, rowID: 3)
        == "player.queue.show.episode.e.row.3")
  }

  /// WCAG 2.5.7: a swipe is a dragging movement, so removal needs a route that is not one. The
  /// removal goes into the list the row's ellipsis button and long press already raise, last, where
  /// a destructive entry belongs. It carries the swipe's own label and hint, so the two routes
  /// cannot describe the same removal differently.
  @Test("queue removal is also present in the row's own action list")
  func removeActionHasContextMenuAlternative() {
    let action = ListeningQueueSheetPresentation.removeContextAction

    #expect(action.label == ListeningQueueSheetPresentation.removeLabel)
    #expect(action.hint == ListeningQueueSheetPresentation.removeHint)
    #expect(action.role == .destructive)
    #expect(action.isEnabled)

    for category in [ItemMediaCategory.audiobook, .ebook, .podcast] {
      let listed = ListeningQueueSheetPresentation.rowContextActions(for: category)
      #expect(listed.map(\.id) == ["play-now", "open-item", "remove-from-up-next"])
      #expect(listed.filter { $0.role == .destructive } == [action])
    }
  }
}

/// The player-owned queue sheet's presentation policy: which content state the sheet renders,
/// whether Clear is offered, what a Play Now tap does with the result, how a list move becomes a
/// queue position, and the exact copy. No view is constructed in this suite, as in
/// `ListeningQueuePresentationTests`.
@Suite("Listening queue sheet presentation")
struct ListeningQueueSheetPresentationTests {

  // MARK: - Open

  @Test("opening a queued episode raises its card rather than its show")
  @MainActor func openingAnEpisodeRaisesItsCard() throws {
    let identity = try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "ep"))
    #expect(
      ListeningQueueSheetPresentation.openDestination(identity: identity, category: .podcast)
        == .episodeCard(NavigationModel.PodcastEpisodeRef(itemID: "show", episodeID: "ep")))
  }

  @Test("opening a queued book still pushes its detail page")
  @MainActor func openingABookPushesItsDetail() throws {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book"))
    #expect(
      ListeningQueueSheetPresentation.openDestination(identity: identity, category: .audiobook)
        == .route(.itemDetail(itemID: "book")))
  }

  // MARK: - Content states

  @Test("a queue still loading renders the loading state")
  func loadingState() {
    #expect(
      ListeningQueueSheetPresentation.content(state: .loading, offersUndo: false) == .loading)
  }

  @Test("an empty queue with no live undo renders the ordinary empty state")
  func emptyState() {
    #expect(ListeningQueueSheetPresentation.content(state: .empty, offersUndo: false) == .empty)
  }

  @Test("an emptied queue with a live undo offer renders the cleared state instead")
  func clearedState() {
    #expect(ListeningQueueSheetPresentation.content(state: .empty, offersUndo: true) == .cleared)
  }

  @Test("a populated queue renders rows, never the cleared banner")
  func loadedState() {
    #expect(ListeningQueueSheetPresentation.content(state: .loaded, offersUndo: false) == .rows)
    #expect(
      ListeningQueueSheetPresentation.content(state: .loaded, offersUndo: true) == .rows,
      "a restored queue shows its rows again, not the banner that offered the restore")
  }

  // MARK: - Clear availability

  @Test("Clear Up Next is offered only while the queue actually has rows")
  func clearIsOfferedOnlyWhenNonEmpty() {
    #expect(ListeningQueueSheetPresentation.showsClearAction(state: .loaded))
    #expect(ListeningQueueSheetPresentation.showsClearAction(state: .empty) == false)
    #expect(ListeningQueueSheetPresentation.showsClearAction(state: .loading) == false)
  }

  // MARK: - Play Now

  @Test("a successful start dismisses the sheet back to the still-expanded player")
  func successfulStartDismisses() throws {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book"))
    #expect(
      ListeningQueueSheetPresentation.playNowOutcome(
        requested: identity,
        nowPlaying: identity,
        startFailureMessage: nil) == .dismiss)
  }

  @Test("a failed start leaves the sheet open so the row stays visible beneath the shared alert")
  func failedStartStays() throws {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book"))
    #expect(
      ListeningQueueSheetPresentation.playNowOutcome(
        requested: identity,
        nowPlaying: nil,
        startFailureMessage: "Couldn't start playback.") == .stay)
  }

  @Test("a start that landed on some other identity never dismisses this row's sheet")
  func startOfADifferentIdentityStays() throws {
    let requested = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "ep-1"))
    let nowPlaying = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "ep-2"))
    #expect(
      ListeningQueueSheetPresentation.playNowOutcome(
        requested: requested,
        nowPlaying: nowPlaying,
        startFailureMessage: nil) == .stay)
  }

  @Test("a successful native RSS start dismisses for the exact third identity")
  func successfulNativeRSSStartDismisses() throws {
    let identity = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "native"))
    #expect(
      ListeningQueueSheetPresentation.playNowOutcome(
        requested: identity, nowPlaying: identity, startFailureMessage: nil) == .dismiss)
  }

  @Test("a start that reported a failure never dismisses even if the identity matches")
  func failureMessageAlwaysStays() throws {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book"))
    #expect(
      ListeningQueueSheetPresentation.playNowOutcome(
        requested: identity,
        nowPlaying: identity,
        startFailureMessage: "Couldn't start playback.") == .stay)
  }

  // MARK: - Play Now, Then Resume

  @Test("the swap is offered after Play Now, naming the title it will resume")
  func swapIsOfferedWhileSomethingElsePlays() throws {
    let listed = ListeningQueueSheetPresentation.rowContextActions(
      for: .podcast, displacedTitle: "As You Wake, Break the Shell")

    #expect(listed.map(\.id) == ["play-now", "play-now-then-resume", "open-item", "remove-from-up-next"])
    let swap = try #require(listed.first { $0.id == "play-now-then-resume" })
    #expect(swap.label == "Play Now, Then Resume")
    #expect(swap.hint == "Plays this now, then resumes As You Wake, Break the Shell where you left off.")
  }

  @Test("the swap names what is playing, and nothing when the row is itself playing or nothing is")
  func displacedTitleFollowsNowPlaying() throws {
    let book = try #require(ListeningIdentity.audiobook(itemID: "book"))
    let episode = try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "e"))
    let bookmark = PlaybackBookmark(
      serverItemId: "book", episodeID: nil, episodeTitle: nil, showTitle: nil, title: "The Book",
      author: nil, durationSeconds: 100, positionSeconds: 10, isFinished: false)
    let episodeBookmark = PlaybackBookmark(
      serverItemId: "show", episodeID: "e", episodeTitle: "The Episode", showTitle: "The Show",
      title: "The Show", author: nil, durationSeconds: 100, positionSeconds: 10, isFinished: false)

    #expect(
      ListeningQueueSheetPresentation.displacedTitle(
        row: episode, nowPlaying: book, displayed: bookmark) == "The Book")
    #expect(
      ListeningQueueSheetPresentation.displacedTitle(
        row: book, nowPlaying: episode, displayed: episodeBookmark) == "The Episode")
    #expect(
      ListeningQueueSheetPresentation.displacedTitle(
        row: book, nowPlaying: book, displayed: bookmark) == nil)
    #expect(
      ListeningQueueSheetPresentation.displacedTitle(
        row: episode, nowPlaying: nil, displayed: bookmark) == nil)
  }

  // MARK: - Reorder

  @Test("a downward list move accounts for the row's own removal")
  func downwardMoveDropsOneIndex() {
    #expect(ListeningQueueSheetPresentation.moveDestination(from: 0, to: 2) == 1)
  }

  @Test("an upward list move lands on the destination index unchanged")
  func upwardMoveKeepsIndex() {
    #expect(ListeningQueueSheetPresentation.moveDestination(from: 2, to: 0) == 0)
  }

  @Test("a move that resolves back onto the row's own position is not a mutation")
  func noOpMoveIsRejected() {
    #expect(ListeningQueueSheetPresentation.moveDestination(from: 1, to: 1) == nil)
    #expect(ListeningQueueSheetPresentation.moveDestination(from: 1, to: 2) == nil)
  }

  // MARK: - Presentation behavior

  @Test("tapping Up Next raises the sheet rather than navigating and collapsing the player")
  func upNextRaisesTheSheet() {
    #expect(ListeningQueueSheetPresentation.upNextActivation == .presentSheet)
  }

  /// Opening Up Next never changes `NavigationModel.section` or any section path.
  @MainActor
  @Test("opening and closing the queue mutates no navigation section or path")
  func openingAndClosingTheQueueLeavesNavigationAlone() {
    let navigation = NavigationModel()
    navigation.section = .podcasts
    navigation.navigate(to: .podcastShows)
    navigation.expandPlayer()
    let destination = navigation.current
    let libraryPath = navigation[pathFor: .library]

    var isPresented = false
    ListeningQueueSheetPresentation.openQueue(&isPresented)
    #expect(isPresented)
    #expect(navigation.current == destination)
    #expect(navigation[pathFor: .library] == libraryPath)
    #expect(navigation.playerPresentation == .expanded)

    ListeningQueueSheetPresentation.closeQueue(&isPresented)
    #expect(isPresented == false)
    #expect(navigation.current == destination)
    #expect(navigation[pathFor: .library] == libraryPath)
    #expect(
      navigation.playerPresentation == .expanded,
      "closing the queue must leave the player expanded")
  }

  // MARK: - Copy and accessibility

  @Test("the cleared banner reuses the model's own copy")
  func clearedCopy() {
    #expect(ListeningQueueSheetPresentation.clearedTitle == ListeningQueueCopy.cleared)
  }

  @Test("Clear announces that it does not stop what is playing now")
  func clearAnnouncesItDoesNotStopPlayback() {
    #expect(ListeningQueueSheetPresentation.clearHint.contains("Does not stop"))
  }
}

/// The same policy driven by a real `ListeningQueueModel` over fake storage and an injected clock.
/// The sheet's rendered state is checked against the command state the model owns, not against a
/// restatement of it.
@Suite("Listening queue sheet clear and undo")
struct ListeningQueueSheetClearUndoTests {

  @MainActor
  @Test("a fresh clear renders the cleared banner and restores the exact order inside ten seconds")
  func clearRendersBannerAndUndoRestoresOrder() async throws {
    let reading = FakeQueueReading()
    let store = FakeListeningQueueStoring()
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000))
    let model = ListeningQueueModel(reading: reading, storing: store, clock: clock)
    let rows = [try Self.book(1, position: 0), try Self.episode(2, position: 1)]

    reading.push(rows)
    await waitUntil { model.items.count == 2 }
    #expect(sheetContent(model) == .rows)

    await model.clear()
    reading.push([])
    await waitUntil { model.items.isEmpty }
    #expect(sheetContent(model) == .cleared)

    clock.advance(by: ListeningQueueModel.clearUndoLifetime - 1)
    await model.undoClear()
    reading.push(rows)
    await waitUntil { model.items.count == 2 }

    #expect(store.restoreCount == 1)
    #expect(model.items.map(\.identity) == rows.map(\.identity))
    #expect(sheetContent(model) == .rows)
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("an expired undo offer falls back to the ordinary empty state")
  func expiredUndoFallsBackToEmpty() async {
    let reading = FakeQueueReading()
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000))
    let model = ListeningQueueModel(
      reading: reading, storing: FakeListeningQueueStoring(), clock: clock)
    reading.push([])
    await waitUntil { model.state == .empty }

    await model.clear()
    #expect(sheetContent(model) == .cleared)

    clock.advance(by: ListeningQueueModel.clearUndoLifetime)
    #expect(sheetContent(model) == .empty, "the offer expires at exactly the named lifetime")
  }

  @MainActor
  @Test("an intervening queue mutation makes the undo offer stale and hides the banner")
  func interveningMutationHidesTheBanner() async throws {
    let reading = FakeQueueReading()
    let model = ListeningQueueModel(reading: reading, storing: FakeListeningQueueStoring())
    reading.push([])
    await waitUntil { model.state == .empty }

    await model.clear()
    #expect(sheetContent(model) == .cleared)

    let identity = try #require(ListeningIdentity.audiobook(itemID: "book"))
    await model.append(identity: identity)
    #expect(sheetContent(model) == .empty)
  }

  @MainActor
  @Test("a failed clear offers no undo and surfaces the bounded error instead")
  func failedClearSurfacesAnError() async throws {
    let reading = FakeQueueReading()
    let store = FakeListeningQueueStoring()
    store.failNext(ListeningQueueStoreError.itemNotFound)
    let model = ListeningQueueModel(reading: reading, storing: store)
    reading.push([try Self.book(1, position: 0)])
    await waitUntil { model.items.count == 1 }

    await model.clear()

    #expect(model.canUndoClear == false)
    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)
    #expect(sheetContent(model) == .rows, "a failed clear leaves the queue exactly as it was")
  }

  @MainActor
  private func sheetContent(_ model: ListeningQueueModel) -> ListeningQueueSheetPresentation.Content {
    ListeningQueueSheetPresentation.content(state: model.state, offersUndo: model.canUndoClear)
  }

  private static func book(_ id: Int64, position: Int) throws -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: position,
      identity: try #require(ListeningIdentity.audiobook(itemID: "book-\(id)")),
      primaryTitle: "Book \(id)", secondaryTitle: "Author", category: .audiobook,
      isTombstone: false)
  }

  private static func episode(_ id: Int64, position: Int) throws -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: position,
      identity: try #require(
        ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-\(id)")),
      primaryTitle: "Episode \(id)", secondaryTitle: "Show", category: .podcast,
      isTombstone: false)
  }
}

private final class FakeQueueReading: ListeningQueueReading, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<[ListeningQueueItem]>.Continuation?

  func observeQueue() -> AsyncStream<[ListeningQueueItem]> {
    AsyncStream { continuation in
      lock.withLock { self.continuation = continuation }
    }
  }

  func push(_ items: [ListeningQueueItem]) {
    lock.withLock { continuation }?.yield(items)
  }
}

extension FakeListeningQueueStoring {
  fileprivate var restoreCount: Int { calls.filter { $0 == .restore }.count }
}
