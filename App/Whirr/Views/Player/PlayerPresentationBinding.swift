import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

/// Pure get/set pair behind `LibraryShellView`'s expanded-player
/// `.fullScreenCover(isPresented:)` binding (ARCHITECTURE.md D28). `NavigationModel.playerPresentation`
/// is `private(set)`, so this forms the `Binding<Bool>` the cover needs. A plain struct rather than
/// a `Binding<Bool>` so `set`/`get` can be asserted without constructing a SwiftUI view.
@MainActor
struct PlayerPresentationBinding {
  let navigation: NavigationModel

  var get: Bool { navigation.playerPresentation == .expanded }

  func set(_ isPresented: Bool) {
    if isPresented {
      navigation.expandPlayer()
    } else {
      // A full-screen cover has no system swipe-down, so this arrives from the page's own chrome
      // drag or the Close action (ARCHITECTURE.md D28), and is the same as any other collapse.
      navigation.collapsePlayer()
    }
  }
}

/// Queue-row or mini-player metadata that may paint before the matching item-detail observation
/// arrives. The identity belongs to the seed so a late or duplicated Play Now task can never lend
/// one item's title to another item's player page.
struct PlayerMetadataSeed: Equatable, Sendable {
  let identity: ListeningIdentity
  let title: String
  let author: String?
  /// The cover's provider source and revision, as the mini player already keys its cover, so the
  /// page draws the same cover from its first frame and the open's cover flight can match it.
  var artworkSource: ArtworkSource? = nil
  var artworkRevision: ArtworkRevision? = nil
  /// The episode's own image, when it has one: what `PlayerArtworkResolution` draws first.
  var episodeArtworkSource: ArtworkSource? = nil
}

/// The one snapshot the expanded player renders. Keeping the identity and its optional seed in
/// the same value prevents an item id from one playback state being paired with an episode id from
/// another one during a queue transition.
struct PlayerPresentationEntry: Equatable, Sendable {
  let identity: ListeningIdentity
  let metadataSeed: PlayerMetadataSeed?

  init(identity: ListeningIdentity, metadataSeed: PlayerMetadataSeed? = nil) {
    self.identity = identity
    self.metadataSeed = metadataSeed
  }
}

/// What the shell does with an expanded player when the live identity changes. The state owns the
/// decision; `NavigationModel.collapsePlayer(style:)` is the effect.
enum ExpandedPlayerFollowOutcome: Equatable, Sendable {
  /// The committed entry is correct: followed a live identity, reconciled one, or left standing
  /// because the queue's presentation window froze it.
  case followed
  /// Playback cleared while the player was expanded: the title finished and is no longer presented.
  /// The shell slides the player down instead of rendering an empty cover.
  case collapse
}

/// Pure state for the expanded player's committed identity.
///
/// `committed` is what the cover renders. `pending` is never rendered: it holds a queue Play Now
/// seed until the queue sheet finishes dismissing, when `reconcileFromLive(_:)` picks the live
/// identity and accepts the seed only for it. While frozen, `follow(liveIdentity:)` ignores live
/// changes. A live identity of `nil` outside that window means playback cleared, which both
/// follow points report as `.collapse` rather than committing an empty entry.
struct ExpandedPlayerPresentationState: Equatable, Sendable {
  private(set) var committed: PlayerPresentationEntry?
  private(set) var pending: PlayerPresentationEntry?
  private(set) var isFrozen = false

  /// Stages an entry without changing what is currently rendered.
  mutating func stage(_ entry: PlayerPresentationEntry) {
    pending = entry
  }

  /// Convenience form used by the shell's cover-open snapshot and the queue seed callback.
  mutating func stage(
    identity: ListeningIdentity, metadataSeed: PlayerMetadataSeed? = nil
  ) {
    stage(PlayerPresentationEntry(identity: identity, metadataSeed: metadataSeed))
  }

  /// Commits the cover-open snapshot at once. A seed is kept only for `identity`. Without one, the
  /// seed already committed for that identity stays, because the shell snapshots again when the
  /// presentation flips to expanded, after the bar's seeded tap and before the page's first frame.
  mutating func snapshot(identity: ListeningIdentity, metadataSeed: PlayerMetadataSeed? = nil) {
    let retained = committed?.identity == identity ? committed?.metadataSeed : nil
    let seed = metadataSeed?.identity == identity ? metadataSeed : retained
    stage(identity: identity, metadataSeed: seed)
    commitPending()
  }

  /// Commits the staged cover-open entry. Queue seeds wait for `reconcileFromLive(_:)` instead, so
  /// a task that happens to finish first can never select the identity.
  mutating func commitPending() {
    guard let pending else { return }
    committed = pending
    self.pending = nil
    isFrozen = false
  }

  /// Makes the committed entry ignore live identity changes until the queue sheet's native
  /// dismissal callback arrives.
  mutating func freeze() {
    isFrozen = true
  }

  /// Follows live playback whenever the queue is not in its presentation/dismissal window. A live
  /// identity of `nil` means the retained title finished and is no longer presented: keep the page
  /// painted for the slide down (the dismissal's `reset()` clears it) rather than rendering nothing.
  @discardableResult
  mutating func follow(liveIdentity: ListeningIdentity?) -> ExpandedPlayerFollowOutcome {
    guard isFrozen == false else { return .followed }
    // A seed not reconciled at the native dismissal boundary is stale. A late Play Now completion
    // arrives as a live identity change, not as a pending value choosing the page.
    pending = nil
    guard let liveIdentity else { return .collapse }
    committed = PlayerPresentationEntry(identity: liveIdentity)
    return .followed
  }

  /// Reconciles from the live playback identity after the queue sheet is fully gone. A seed is
  /// display-only and survives this boundary only when it names that exact live identity. With no
  /// live identity the player must leave, so this reports `.collapse` and keeps the committed entry
  /// painted until the dismissal completes.
  @discardableResult
  mutating func reconcileFromLive(
    _ liveIdentity: ListeningIdentity?
  ) -> ExpandedPlayerFollowOutcome {
    guard let liveIdentity else {
      pending = nil
      isFrozen = false
      return .collapse
    }
    let seed: PlayerMetadataSeed? = {
      guard let candidate = pending?.metadataSeed, candidate.identity == liveIdentity else {
        return nil
      }
      return candidate
    }()
    committed = PlayerPresentationEntry(identity: liveIdentity, metadataSeed: seed)
    pending = nil
    isFrozen = false
    return .followed
  }

  /// Clears the cover snapshot after the full-screen presentation has completed its dismissal.
  mutating func reset() {
    committed = nil
    pending = nil
    isFrozen = false
  }
}

/// Observable holder for `ExpandedPlayerPresentationState`, kept in `LibraryShellView`'s `@State`.
///
/// A reference, so a mutation (the cover-open snapshot, the dismissal reset) invalidates only the
/// bodies that read `state` (the presentation chain and the mini player's seed). As a value
/// `@State` it would re-evaluate the shell body, the `TabView` and every visited tab.
@MainActor
@Observable
final class ExpandedPlayerPresentationModel {
  var state = ExpandedPlayerPresentationState()
}

/// Whether the shell's `.tabViewBottomAccessory` should be attached at all, and which item the
/// mini-player/expanded-player should show (ARCHITECTURE.md §6). An unconditional accessory
/// reserves its strip even when its view renders nothing, so `LibraryShellView` must gate the
/// modifier itself on `isPresented`. Presence and item selection use
/// `PlaybackModel.nowPlayingIdentity`, not the position-bearing retained bookmark.
enum MiniPlayerAccessoryPresentation {
  /// The mini-player title scrolls like the system players' do. `MarqueeText` scrolls with an
  /// animated offset: driving it with `KeyframeAnimator` re-ran the title's layout every frame
  /// inside the accessory's glass host and added scroll stalls on Home and Podcasts.
  static let isTitleMarqueeEnabled = true

  /// True when there is a live session, or a retained "last played" item still worth showing
  /// (`nowPlayingIdentity` suppresses equal assignments when only the retained position changes).
  /// A finished retained title is not presented: once its bookmark is finished,
  /// `nowPlayingIdentity` is `nil`, so a done title never keeps the bar. `isSelecting` overrides it:
  /// multiselect puts bulk actions in the bottom bar and the accessory, attached to the `TabView`,
  /// would cover them (`SelectionChromeModel`).
  static func isPresented(nowPlayingIdentity: ListeningIdentity?, isSelecting: Bool) -> Bool {
    nowPlayingIdentity != nil && !isSelecting
  }

  /// Whether a change in `isPresented` should be applied inside an animation transaction.
  ///
  /// The system owns the accessory's insertion and removal (`tabViewBottomAccessory(isEnabled:)`),
  /// and it animates them only when the enabled flag changes inside a transaction. A plain write —
  /// what a finished title's cleared identity used to make from a database observation with no
  /// transaction of its own — removes the bar between frames. Two changes must stay unanimated: a
  /// playback change under the expanded page, because the page is covering the bar and the bar must
  /// already be gone when the page slides away; and a selection change, which swaps the bottom bar
  /// for bulk-action chrome and keeps that swap's existing unanimated behaviour.
  static func animatesChange(selectionChanged: Bool, isPlayerExpanded: Bool) -> Bool {
    !selectionChanged && !isPlayerExpanded
  }

  /// The widest the mini-player's content may draw, or `nil` for no cap. The system accessory
  /// takes every point offered, which at regular width runs the full window with a thousand
  /// points of glass between cover and transport. A phone-column cap (as Apple Music uses) shrinks
  /// the title column to ~230pt, so ordinary titles scroll with room to spare.
  static func contentMaxWidth(for horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat? {
    horizontalSizeClass == .regular ? regularWidthContentMaxWidth : nil
  }

  /// About half a 13-inch landscape window and most of an 11-inch portrait one, leaving a title
  /// column of ~530pt before the regular-width speed and sleep-timer controls, ~380pt with both.
  /// On the narrowest regular-width windows (iPad mini portrait, Split View) the offered width is
  /// already below this, so the bar fills it.
  static let regularWidthContentMaxWidth: CGFloat = 760

  /// Whether the bar carries the chapter subtitle and the speed and sleep-timer controls. Only a
  /// regular-width bar has room for them; at compact width the title column is already the
  /// tightest in the row. The window's size class is not enough on its own: a half-open iPhone Duo
  /// keeps a regular-width window but the system gives the accessory one panel, so the bar's own
  /// measured width decides once it is known.
  static func showsRegularWidthControls(
    for horizontalSizeClass: UserInterfaceSizeClass?, barWidth: CGFloat?
  ) -> Bool {
    guard horizontalSizeClass == .regular else { return false }
    guard let barWidth, barWidth.isFinite else { return true }
    return barWidth >= regularWidthControlsMinimumBarWidth
  }

  /// The narrowest bar that keeps a phone column's ~230pt title beside the cover, the transport,
  /// and the speed and sleep-timer controls. Below it the bar drops to the compact arrangement.
  static let regularWidthControlsMinimumBarWidth: CGFloat = 560

  /// Apple asks bottom-accessory content to adapt to this environment value. `nil` (an undefined or
  /// non-bottom-bar host) is treated as expanded so no functionality is lost.
  static func layout(for placement: TabViewBottomAccessoryPlacement?) -> MiniPlayerLayout {
    guard let placement else { return .expanded }
    switch placement {
    case .inline:
      return .inline
    case .expanded:
      return .expanded
    @unknown default:
      return .expanded
    }
  }

  /// The item id the mini-player/expanded-player should display. Mirrors `isPresented`, so a caller
  /// that shows content only when this is non-`nil` agrees with the accessory gate.
  static func displayedItemID(nowPlayingIdentity: ListeningIdentity?) -> String? {
    nowPlayingIdentity?.itemID
  }

  /// The episode paired with `displayedItemID`. An active item owns the answer even when its
  /// episode is `nil` (an audiobook), so a retained podcast cannot leak its episode identity into
  /// a newly active audiobook.
  static func displayedEpisodeID(
    activeItemID: String?, activeEpisodeID: String?, displayedItem: PlaybackBookmark?
  ) -> String? {
    activeItemID == nil ? displayedItem?.episodeID : activeEpisodeID
  }
}
