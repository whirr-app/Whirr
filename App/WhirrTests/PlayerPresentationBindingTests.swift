import AppModel
import DesignSystem
import Persistence
import SwiftUI
import TestSupport
import Testing

@testable import Whirr

/// Pure logic behind `LibraryShellView`'s `.sheet(isPresented:)` binding and the
/// `.tabViewBottomAccessory` gate. Both are tested here without constructing a view.
@Suite struct PlayerPresentationBindingTests {

  // MARK: - PlayerPresentationBinding

  @MainActor
  @Test func setTrueExpandsThePlayer() {
    let navigation = NavigationModel()
    let binding = PlayerPresentationBinding(navigation: navigation)

    binding.set(true)

    #expect(navigation.playerPresentation == .expanded)
  }

  @MainActor
  @Test func setFalseCollapsesThePlayer() {
    let navigation = NavigationModel()
    navigation.expandPlayer()
    let binding = PlayerPresentationBinding(navigation: navigation)

    binding.set(false)

    #expect(navigation.playerPresentation == .collapsed)
  }

  @MainActor
  @Test func getMirrorsThePlayerPresentation() {
    let navigation = NavigationModel()
    let binding = PlayerPresentationBinding(navigation: navigation)

    #expect(binding.get == false)

    navigation.expandPlayer()
    #expect(binding.get == true)

    navigation.collapsePlayer()
    #expect(binding.get == false)
  }

  // MARK: - Accessory presentation

  @Test func accessoryPresenceUsesTheStableIdentityAcrossItsLifecycle() {
    // No playback has ever been retained.
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(nowPlayingIdentity: nil, isSelecting: false)
        == false)
    // Live playback.
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(
        nowPlayingIdentity: .podcastEpisode(itemID: "show", episodeID: "live-episode"),
        isSelecting: false))
    // Playback stopped, with its last identity retained.
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(
        nowPlayingIdentity: .audiobook(itemID: "stopped-book"), isSelecting: false))
    // Cold launch, with only the retained identity restored.
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(
        nowPlayingIdentity: .podcastEpisode(itemID: "show", episodeID: "retained-episode"),
        isSelecting: false))
    // A changed identity remains present and follows the new item.
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(
        nowPlayingIdentity: .audiobook(itemID: "changed-book"), isSelecting: false))
  }

  /// A selection screen's bulk actions sit in the bottom bar, which the accessory would otherwise
  /// cover. The tab bar hides itself in edit mode, but the accessory is not part of that toolbar.
  @Test func accessoryIsAbsentWhileAScreenIsSelecting() {
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(
        nowPlayingIdentity: .podcastEpisode(itemID: "show", episodeID: "live-episode"),
        isSelecting: true) == false)
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(
        nowPlayingIdentity: .audiobook(itemID: "retained-book"), isSelecting: true) == false)
    // Selection does not conjure an accessory where there is nothing to show either.
    #expect(
      MiniPlayerAccessoryPresentation.isPresented(nowPlayingIdentity: nil, isSelecting: true)
        == false)
  }

  // MARK: - Accessory presence animation

  /// The system owns the bar's insertion and removal, and it only animates them when the enabled
  /// flag changes inside a transaction. A finished title clears `nowPlayingIdentity` from a
  /// database observation with no transaction of its own, so the change must supply one.
  @Test func aPlaybackDrivenPresenceChangeWhileCollapsedAnimates() {
    #expect(
      MiniPlayerAccessoryPresentation.animatesChange(
        selectionChanged: false, isPlayerExpanded: false))
  }

  /// The expanded page covers the bar, so a playback-driven change lands behind it: the bar must
  /// already be gone when the page slides away, and animating it there would show it moving out
  /// from under the dismissing page.
  @Test func aPlaybackDrivenPresenceChangeUnderTheExpandedPlayerDoesNotAnimate() {
    #expect(
      MiniPlayerAccessoryPresentation.animatesChange(
        selectionChanged: false, isPlayerExpanded: true) == false)
  }

  /// Multiselect swaps the bottom bar for bulk actions. That chrome swap keeps its existing
  /// unanimated behaviour, whichever way the accessory moves.
  @Test func aSelectionDrivenPresenceChangeDoesNotAnimate() {
    #expect(
      MiniPlayerAccessoryPresentation.animatesChange(
        selectionChanged: true, isPlayerExpanded: false) == false)
    #expect(
      MiniPlayerAccessoryPresentation.animatesChange(
        selectionChanged: true, isPlayerExpanded: true) == false)
  }

  @Test func nativeAccessoryPlacementMapsToTheMatchingMiniPlayerLayout() {
    #expect(MiniPlayerAccessoryPresentation.layout(for: .inline) == MiniPlayerLayout.inline)
    #expect(MiniPlayerAccessoryPresentation.layout(for: .expanded) == MiniPlayerLayout.expanded)
    #expect(MiniPlayerAccessoryPresentation.layout(for: nil) == MiniPlayerLayout.expanded)
  }

  @Test func accessoryContentIsCappedOnlyAtRegularWidth() {
    #expect(MiniPlayerAccessoryPresentation.contentMaxWidth(for: .compact) == nil)
    #expect(MiniPlayerAccessoryPresentation.contentMaxWidth(for: nil) == nil)
    #expect(
      MiniPlayerAccessoryPresentation.contentMaxWidth(for: .regular)
        == MiniPlayerAccessoryPresentation.regularWidthContentMaxWidth)
  }

  @Test func accessoryRegularWidthCapGivesTheTitleRoomBeyondAPhoneColumn() {
    // The row's fixed furniture: cover, three 44pt controls, the two row gaps and the horizontal
    // padding. The title column is what is left, and it must be roughly twice the ~230pt a
    // phone column cap leaves, or ordinary titles scroll.
    let furniture =
      PlayerMetric.miniPlayerCoverSize + 3 * PlayerMetric.miniPlayerPlayPauseSize
      + 4 * WhirrSpacing.small
    #expect(MiniPlayerAccessoryPresentation.regularWidthContentMaxWidth - furniture >= 440)
  }

  @Test func accessoryRegularWidthControlsFollowTheSizeClassUntilTheBarIsMeasured() {
    #expect(MiniPlayerAccessoryPresentation.showsRegularWidthControls(for: .regular, barWidth: nil))
    #expect(
      MiniPlayerAccessoryPresentation.showsRegularWidthControls(for: .compact, barWidth: nil)
        == false)
    #expect(
      MiniPlayerAccessoryPresentation.showsRegularWidthControls(for: nil, barWidth: nil) == false)
  }

  /// A half-open iPhone Duo keeps a regular-width window but gives the accessory only one panel,
  /// about 347pt. The speed and sleep-timer controls there leave the title a few dozen points.
  @Test func accessoryRegularWidthControlsGiveWayInANarrowBar() {
    #expect(
      MiniPlayerAccessoryPresentation.showsRegularWidthControls(for: .regular, barWidth: 347)
        == false)
    let minimum = MiniPlayerAccessoryPresentation.regularWidthControlsMinimumBarWidth
    #expect(
      MiniPlayerAccessoryPresentation.showsRegularWidthControls(
        for: .regular, barWidth: minimum - 1) == false)
    #expect(
      MiniPlayerAccessoryPresentation.showsRegularWidthControls(for: .regular, barWidth: minimum))
    // A wide bar never brings them to a compact window.
    #expect(
      MiniPlayerAccessoryPresentation.showsRegularWidthControls(for: .compact, barWidth: 900)
        == false)
  }

  @Test func accessoryRegularWidthControlsKeepAPhoneColumnTitle() {
    // Cover, the three transport controls, the speed and sleep-timer controls, and the row gaps:
    // what remains at the minimum must still be a phone column's title.
    let furniture =
      PlayerMetric.miniPlayerCoverSize + 5 * PlayerMetric.miniPlayerPlayPauseSize
      + 4 * WhirrSpacing.small
    #expect(MiniPlayerAccessoryPresentation.regularWidthControlsMinimumBarWidth - furniture >= 230)
    // Narrower than every full-width regular window, so iPad and the open Duo keep the controls.
    #expect(MiniPlayerAccessoryPresentation.regularWidthControlsMinimumBarWidth < 600)
  }

  @Test func accessoryTitleMarqueeIsEnabled() {
    #expect(MiniPlayerAccessoryPresentation.isTitleMarqueeEnabled)
  }

  // MARK: - Item id resolution

  @Test func displayedItemIDUsesTheLiveIdentity() {
    #expect(
      MiniPlayerAccessoryPresentation.displayedItemID(
        nowPlayingIdentity: .podcastEpisode(itemID: "active", episodeID: "episode")) == "active")
  }

  @Test func displayedItemIDUsesTheStoppedRetainedIdentity() {
    #expect(
      MiniPlayerAccessoryPresentation.displayedItemID(
        nowPlayingIdentity: .audiobook(itemID: "retained")) == "retained")
  }

  @Test func displayedItemIDIsNilWhenThereIsNoIdentity() {
    #expect(MiniPlayerAccessoryPresentation.displayedItemID(nowPlayingIdentity: nil) == nil)
  }

  @Test func displayedItemIDFollowsAnIdentityChange() {
    #expect(
      MiniPlayerAccessoryPresentation.displayedItemID(
        nowPlayingIdentity: .podcastEpisode(itemID: "new-show", episodeID: "new-episode"))
        == "new-show")
  }

  @Test func displayedEpisodeIDTracksTheActiveEpisodeAndFallsBackToTheRetainedEpisode() {
    #expect(
      MiniPlayerAccessoryPresentation.displayedEpisodeID(
        activeItemID: "show", activeEpisodeID: "active-episode",
        displayedItem: Self.bookmark(id: "show", episodeID: "retained-episode"))
        == "active-episode")
    #expect(
      MiniPlayerAccessoryPresentation.displayedEpisodeID(
        activeItemID: nil, activeEpisodeID: nil,
        displayedItem: Self.bookmark(id: "show", episodeID: "retained-episode"))
        == "retained-episode")
  }

  @Test func activeAudiobookDoesNotInheritARetainedPodcastEpisodeID() {
    #expect(
      MiniPlayerAccessoryPresentation.displayedEpisodeID(
        activeItemID: "book", activeEpisodeID: nil,
        displayedItem: Self.bookmark(id: "show", episodeID: "retained-episode"))
        == nil)
  }

  // MARK: - Expanded-player identity window

  @Test func renderedIdentityStaysCommittedWhileQueueIsPresented() throws {
    var state = ExpandedPlayerPresentationState()
    let original = try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a")
    let next = try Self.podcastIdentity(itemID: "show-b", episodeID: "episode-b")
    state.stage(identity: original)
    state.commitPending()
    state.freeze()

    state.follow(liveIdentity: next)

    #expect(state.committed?.identity == original)
  }

  @Test func reconcilesToLiveIdentityOnQueueDismissal() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let next = try Self.podcastIdentity(itemID: "show-b", episodeID: "episode-b")
    let seed = PlayerMetadataSeed(identity: next, title: "Episode B", author: "Show B")
    state.freeze()
    state.stage(identity: next, metadataSeed: seed)

    state.reconcileFromLive(next)

    #expect(state.committed == PlayerPresentationEntry(identity: next, metadataSeed: seed))
    #expect(state.isFrozen == false)
  }

  @Test func doesNotMixThePreviousEpisodeWithTheNewItem() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let next = try #require(ListeningIdentity.audiobook(itemID: "book-b"))
    let seed = PlayerMetadataSeed(identity: next, title: "Book B", author: "Author B")
    state.freeze()
    state.stage(identity: next, metadataSeed: seed)

    state.reconcileFromLive(next)

    #expect(state.committed?.identity == next)
    #expect(state.committed?.identity.itemID == "book-b")
    #expect(state.committed?.identity.episodeID == nil)
  }

  @Test func autoAdvanceWhileQueueIsOpenCommitsTheLiveIdentityOnDismissal() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let advanced = try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-b")
    state.freeze()

    state.follow(liveIdentity: advanced)
    #expect(state.committed?.identity.episodeID == "episode-a")

    state.reconcileFromLive(advanced)

    #expect(state.committed?.identity == advanced)
  }

  @Test func latePlayNowSuccessAfterDismissalIsFollowedNotDropped() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let target = try Self.podcastIdentity(itemID: "show-b", episodeID: "episode-b")
    let seed = PlayerMetadataSeed(identity: target, title: "Episode B", author: "Show B")
    state.freeze()
    state.stage(identity: target, metadataSeed: seed)

    // The queue goes away before the duplicate/late start publishes its identity.
    state.reconcileFromLive(
      try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    state.follow(liveIdentity: target)

    #expect(state.committed?.identity == target)
    #expect(state.committed?.metadataSeed == nil)
  }

  @Test func mismatchedSeedIsDiscardedAtReconcile() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let live = try #require(ListeningIdentity.audiobook(itemID: "book-b"))
    let mismatchedSeed = PlayerMetadataSeed(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-b"),
      title: "Wrong Episode", author: "Wrong Show")
    state.freeze()
    state.stage(identity: live, metadataSeed: mismatchedSeed)

    state.reconcileFromLive(live)

    #expect(state.committed?.identity == live)
    #expect(state.committed?.metadataSeed == nil)
  }

  /// The bar's tap snapshots with its seed, then the shell's `playerPresentation` observer
  /// snapshots again with none. The second must not strip the seed the page's first frame needs.
  @Test func unseededSnapshotKeepsTheSeedOfTheSameIdentity() throws {
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-a"))
    let seed = PlayerMetadataSeed(identity: book, title: "Book A", author: "Author")
    var state = ExpandedPlayerPresentationState()

    state.snapshot(identity: book, metadataSeed: seed)
    state.snapshot(identity: book)

    #expect(state.committed == PlayerPresentationEntry(identity: book, metadataSeed: seed))
    #expect(state.pending == nil)
  }

  @Test func snapshotOfAnotherIdentityDropsTheEarlierSeed() throws {
    let bookA = try #require(ListeningIdentity.audiobook(itemID: "book-a"))
    let bookB = try #require(ListeningIdentity.audiobook(itemID: "book-b"))
    var state = ExpandedPlayerPresentationState()
    state.snapshot(
      identity: bookA, metadataSeed: PlayerMetadataSeed(identity: bookA, title: "A", author: nil))

    state.snapshot(identity: bookB)

    #expect(state.committed == PlayerPresentationEntry(identity: bookB))
  }

  @Test func snapshotIgnoresASeedForAnotherIdentity() throws {
    let bookA = try #require(ListeningIdentity.audiobook(itemID: "book-a"))
    let bookB = try #require(ListeningIdentity.audiobook(itemID: "book-b"))
    var state = ExpandedPlayerPresentationState()

    state.snapshot(
      identity: bookB, metadataSeed: PlayerMetadataSeed(identity: bookA, title: "A", author: nil))

    #expect(state.committed == PlayerPresentationEntry(identity: bookB))
  }

  /// Playback cleared because the retained title finished and is no longer presented. Rendering
  /// `nil` here would leave an empty cover under a transparent modal, so the shell slides the
  /// player down instead. The committed entry is held through the slide and cleared by the
  /// dismissal's `reset()`.
  @Test func clearingPlaybackCollapsesTheExpandedPlayer() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let committed = state.committed

    let outcome = state.follow(liveIdentity: nil)

    #expect(outcome == .collapse)
    #expect(state.committed == committed)
  }

  @Test func clearingPlaybackWhileQueueIsPresentedLeavesTheCommittedEntry() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let committed = state.committed
    state.freeze()

    let outcome = state.follow(liveIdentity: nil)

    #expect(outcome == .followed)
    #expect(state.committed == committed)
    #expect(state.isFrozen)
  }

  @Test func queueDismissalWithNoLiveIdentityCollapsesTheExpandedPlayer() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let committed = state.committed
    state.freeze()

    let outcome = state.reconcileFromLive(nil)

    #expect(outcome == .collapse)
    #expect(state.committed == committed)
    #expect(state.isFrozen == false)
  }

  @Test func liveIdentityWhileQueueIsPresentedIsNotFollowed() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let next = try Self.podcastIdentity(itemID: "show-b", episodeID: "episode-b")
    let committed = state.committed
    state.freeze()

    let outcome = state.follow(liveIdentity: next)

    #expect(outcome == .followed)
    #expect(state.committed == committed)
  }

  @Test func liveIdentityIsFollowedWhenQueueIsNotPresented() throws {
    var state = Self.committedState(
      identity: try Self.podcastIdentity(itemID: "show-a", episodeID: "episode-a"))
    let next = try Self.podcastIdentity(itemID: "show-b", episodeID: "episode-b")

    let outcome = state.follow(liveIdentity: next)

    #expect(outcome == .followed)
    #expect(state.committed == PlayerPresentationEntry(identity: next))
  }

  // MARK: - ExpandedPlayerPresentationModel

  /// The shell holds this reference in `@State`, so a mutation must reach observers of `state`
  /// rather than rewriting a value the shell's own body depends on.
  @MainActor
  @Test func snapshotThroughTheModelNotifiesStateObservers() throws {
    let model = ExpandedPlayerPresentationModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-a"))
    let notified = Locked(false)
    withObservationTracking {
      _ = model.state.committed
    } onChange: {
      notified.withValue { $0 = true }
    }

    model.state.snapshot(identity: book)

    #expect(notified.value)
    #expect(model.state.committed?.identity == book)
  }

  @MainActor
  @Test func resetThroughTheModelClearsTheCommittedEntry() throws {
    let model = ExpandedPlayerPresentationModel()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-a"))
    model.state.snapshot(identity: book)

    model.state.reset()

    #expect(model.state == ExpandedPlayerPresentationState())
  }

  private static func bookmark(id: String = "abc123", episodeID: String? = nil) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: id, episodeID: episodeID, title: "Title \(id)", author: "Author",
      durationSeconds: 100, positionSeconds: 10, isFinished: false)
  }

  private static func podcastIdentity(
    itemID: String, episodeID: String
  ) throws -> ListeningIdentity {
    try #require(ListeningIdentity.podcastEpisode(itemID: itemID, episodeID: episodeID))
  }

  private static func committedState(identity: ListeningIdentity) -> ExpandedPlayerPresentationState {
    var state = ExpandedPlayerPresentationState()
    state.stage(identity: identity)
    state.commitPending()
    return state
  }
}
