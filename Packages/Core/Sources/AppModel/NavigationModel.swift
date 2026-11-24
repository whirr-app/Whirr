import Foundation
import Observation
import Persistence

/// Presentation data already held by an author/series row. Separate from the route's identity: a
/// restored deep link resolves without it, while an in-app tap can paint the name and cached books
/// synchronously.
public struct AuthorSeriesDestinationSeed: Sendable, Equatable {
  public let entity: AuthorSeriesEntity
  public let items: [ItemSummary]

  public init(entity: AuthorSeriesEntity, items: [ItemSummary] = []) {
    self.entity = entity
    self.items = items
  }
}

/// The one navigation model for the shell (ARCHITECTURE.md §6: "one navigation model in
/// AppModel, deep-linkable, testable").
///
/// A section is a place you are: the shell's top-level tabs, mutually exclusive. A route is a
/// place you pushed to; each section owns its own stack, so back pops within a section. The
/// setup/login gate is not a route but a presentation the whole shell is behind.
@MainActor
@Observable
public final class NavigationModel {

  /// The shell's top-level destinations. `CaseIterable` so tests and the tab bar enumerate the
  /// same list, and neither can drift from the other.
  public enum Section: String, Sendable, Hashable, CaseIterable {
    /// The app's landing screen and the default `section` below.
    case home
    case library
    /// Episode-led podcast discovery and continuation. Podcast shows remain browsable in Library.
    case podcasts
    case search
    case settings
  }

  /// Whether the account gate or the shell is on screen. Setup and login are not destinations
  /// within the shell, so they never sit in a section's path beside an item detail.
  public enum Presentation: Sendable, Equatable {
    case setup
    case shell
    /// A previously-confirmed account removal survived to this launch and has not yet completed
    /// both verification sweeps. Gates the whole shell (login/setup included) until
    /// `RootModel`'s launch-time resume finishes or fails.
    case removalPending
  }

  /// The global mini-/full-screen player's own presentation, separate from `Presentation`'s
  /// account gate and from every section's path. Expanding the player must never look like
  /// navigating anywhere.
  public enum PlayerPresentation: Sendable, Equatable {
    case collapsed
    case expanded
  }

  /// How the expanded player leaves, not whether it has. Not a third `PlayerPresentation` case, so
  /// every `== .collapsed` site stays true the moment the player is asked to go; only the UIKit
  /// bridge, which owns the transition's phases, reads it.
  public enum PlayerCollapseStyle: Sendable, Equatable {
    /// The page moves away to uncover somewhere else. The default, and the only style an
    /// interactive pull-down ever uses.
    case slide
    /// The page fades into a near-identical page already painted beneath it: a book's own detail
    /// page, which shares the player's cover, title, and wash.
    case dissolve
  }

  /// Settings' own presentation: raised over whatever section you are on from that section's
  /// toolbar, never navigated to. It keeps its `Section.settings` path (and therefore its
  /// Storage/Resolution Center stack and every `settings/...` deep-link token). Selecting it as
  /// the current section would leave the tab bar with nothing selected and no way back out, so
  /// `navigate(to:)` routes settings destinations here instead.
  public enum SettingsPresentation: Sendable, Equatable {
    case dismissed
    case presented
  }

  /// Whether item detail is pushed onto the current section or raised as a shell-level card. The
  /// shell supplies this because AppModel has no size-class dependency.
  public enum ItemDetailPresentation: Sendable, Equatable {
    case push
    case card
  }

  /// A podcast episode's own sheet-presented card, identified rather than pushed. Not a `Route`:
  /// it never enters a section's path or the back stack, and mints no deep-link token.
  /// `Identifiable` so a shell-level `.sheet(item:)` can bind to it directly.
  public struct PodcastEpisodeRef: Equatable, Sendable, Hashable, Identifiable {
    public let itemID: String
    public let episodeID: String
    /// The smart list this card was opened from, so its Play starts the episode within
    /// the list. Presentation context, not identity: like `ItemDetailRef.seed` it is ignored by
    /// `==` and `hash(into:)`, so the same episode opened from a list and from elsewhere is one
    /// card.
    public let listContext: SmartListContext?

    public init(itemID: String, episodeID: String, listContext: SmartListContext? = nil) {
      self.itemID = itemID
      self.episodeID = episodeID
      self.listContext = listContext
    }

    public var id: String { "\(itemID)#\(episodeID)" }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.itemID == rhs.itemID && lhs.episodeID == rhs.episodeID
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(itemID)
      hasher.combine(episodeID)
    }
  }

  /// A smart list an episode card was opened from.
  public struct SmartListContext: Equatable, Sendable, Hashable {
    public let listID: Int64
    public let name: String

    public init(listID: Int64, name: String) {
      self.listID = listID
      self.name = name
    }
  }

  /// An item detail's shell-level card, identified rather than pushed. The summary is seed data
  /// for the first paint; the server item id remains the card's identity just as it does for the
  /// corresponding `Route`.
  public struct ItemDetailRef: Equatable, Sendable, Hashable, Identifiable {
    public let itemID: String
    public let seed: ItemSummary?

    public init(itemID: String, seed: ItemSummary? = nil) {
      self.itemID = itemID
      self.seed = seed
    }

    public var id: String { itemID }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.itemID == rhs.itemID
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(itemID)
    }
  }

  public private(set) var presentation: Presentation
  public var section: Section
  public private(set) var playerPresentation: PlayerPresentation = .collapsed
  /// How the most recent collapse was asked to run. Written before `playerPresentation` flips so
  /// an observer reacting to the flip reads the style in the same update; reset to `.slide` by
  /// `expandPlayer()` so a style chosen for one collapse cannot leak into the next.
  public private(set) var playerCollapseStyle: PlayerCollapseStyle = .slide
  public private(set) var settingsPresentation: SettingsPresentation = .dismissed
  public private(set) var itemDetailPresentation: ItemDetailPresentation = .push
  /// The card currently up, or `nil` when none is. A shell-level `.sheet(item:)` binds straight to
  /// this, like `settingsPresentation` above it.
  public private(set) var presentedEpisode: PodcastEpisodeRef?
  /// The item-detail card currently up, or `nil` when none is. A shell-level `.sheet(item:)` binds
  /// straight to this, so the detail route can keep its ordinary push vocabulary.
  public private(set) var presentedItemDetail: ItemDetailRef?
  private var paths: [Section: [Route]]

  /// The App target binds `NavigationStack(path:)` straight through this, so SwiftUI writing a
  /// shorter array back (system chevron, interactive swipe-back) is authoritative. The setter
  /// accepts it rather than trying to reconcile.
  public subscript(pathFor section: Section) -> [Route] {
    get { paths[section] ?? [] }
    set { paths[section] = newValue }
  }

  /// Where the user currently is, as a deep-linkable value.
  public var current: Destination {
    Destination(section: section, path: self[pathFor: section])
  }

  public init(presentation: Presentation = .setup, section: Section = .home) {
    self.presentation = presentation
    self.section = section
    self.paths = [:]
  }

  /// Leave the account gate. Idempotent, and does not touch `section`/paths so a
  /// re-entry (foreground, re-resolve) never yanks the user out of where they were.
  public func enterShell() {
    presentation = .shell
  }

  /// Re-enters the setup gate without changing the shell's saved navigation state. Used only for
  /// an authenticated account whose durable library-selection mode is still `pending`.
  public func enterSetup() {
    presentation = .setup
  }

  /// Raises the removal-pending gate. Called once, at launch, when
  /// `AccountLifecycle.isRemovalPending()` reports `true`. Neither `resolveLibraryIfAuthenticated`
  /// nor a fresh setup/login attempt may leave this presentation until the resume that follows
  /// either succeeds (`resetForLogout()` clears it back to `.setup`) or the caller retries.
  public func enterRemovalPendingGate() {
    presentation = .removalPending
  }

  /// Applies the shell's local width policy. Returning to push presentation must drop an open
  /// card immediately; otherwise a compact host would have no surface capable of dismissing it.
  public func setItemDetailPresentation(_ presentation: ItemDetailPresentation) {
    itemDetailPresentation = presentation
    if presentation == .push {
      presentedItemDetail = nil
    }
  }

  /// Push onto the current section's stack. Clears `presentedEpisode` first: pushing a route
  /// from the episode card (its own show line, or the not-found fallback) must not leave the
  /// card covering the destination it just pushed to.
  public func navigate(to route: Route) {
    presentedEpisode = nil

    if case .itemDetail(let itemID, let seed) = route,
      itemDetailPresentation == .card
    {
      presentedItemDetail = ItemDetailRef(itemID: itemID, seed: seed)
      return
    }

    presentedItemDetail = nil
    self[pathFor: section].append(route)
  }

  /// Deep-link entry: select a section and replace its stack wholesale. A settings destination is
  /// the exception: it raises settings over the current section, as settings has no tab to return
  /// from. Also clears `presentedEpisode` and `presentedItemDetail`, as `navigate(to: Route)` does.
  /// A terminal item-detail route follows the same card policy, so a restored regular-width link
  /// leaves no duplicate detail route behind the card.
  public func navigate(to destination: Destination) {
    presentedEpisode = nil

    let path: [Route]
    if itemDetailPresentation == .card,
      let last = destination.path.last,
      case .itemDetail(let itemID, let seed) = last
    {
      presentedItemDetail = ItemDetailRef(itemID: itemID, seed: seed)
      path = Array(destination.path.dropLast())
    } else {
      presentedItemDetail = nil
      path = destination.path
    }

    self[pathFor: destination.section] = path
    if destination.section == .settings {
      settingsPresentation = .presented
    } else {
      section = destination.section
      // Dismissal leaves the old settings path alone until the next ordinary presentation resets
      // it. The path just installed above belongs to the destination's own section, which this
      // branch never touches.
      dismissSettings()
    }
  }

  /// Shows the Search section at its root, replacing only its own stale stack. This is a new
  /// navigation intent, so it also dismisses any episode card that was covering the shell.
  public func showSearchRoot() {
    navigate(to: Destination(section: .search))
  }

  /// No-op at a section root, since a section is not something you can pop out of.
  public func pop() {
    guard !self[pathFor: section].isEmpty else { return }
    self[pathFor: section].removeLast()
  }

  /// Expands the global player over whatever section/route is currently showing. Independent of
  /// `presentation`/`section`/every section's path. It may be called from behind the setup gate
  /// too, though nothing in the shell does.
  public func expandPlayer() {
    playerCollapseStyle = .slide
    playerPresentation = .expanded
  }

  /// Collapses the global player back to its mini-bar presentation. `style` describes the shape of
  /// this one collapse (`PlayerCollapseStyle`); callers that are leaving for somewhere else take
  /// the default.
  public func collapsePlayer(style: PlayerCollapseStyle = .slide) {
    playerCollapseStyle = style
    playerPresentation = .collapsed
  }

  /// Raises settings over the current section. A new ordinary presentation from `.dismissed`
  /// resets the settings stack before showing it, so it always opens at its root.
  public func presentSettings() {
    if settingsPresentation == .dismissed, !self[pathFor: .settings].isEmpty {
      paths[.settings] = []
    }
    settingsPresentation = .presented
  }

  /// Drops the settings presentation. The Done button and the sheet's interactive swipe-down are
  /// indistinguishable here, as with `collapsePlayer()`.
  /// The settings path stays intact through dismissal so a pushed route does not pop during the
  /// animation; the next ordinary `presentSettings()` resets it before reopening.
  public func dismissSettings() {
    settingsPresentation = .dismissed
  }

  /// Raises the episode card over whatever section/route is currently showing. The two cards share
  /// one modal slot, so this drops an open item-detail card rather than stacking on it.
  public func presentEpisode(_ ref: PodcastEpisodeRef) {
    presentedItemDetail = nil
    presentedEpisode = ref
  }

  /// Installs both halves of a notification's route: the show push and, for a live
  /// episode, its shell-level card. A notification is an explicit request to reveal that route,
  /// so it collapses only the player's presentation first; playback itself continues. The
  /// resolver has already downgraded deleted content before this method is called.
  public func navigate(to notification: RSSNotificationResolvedDestination) {
    collapsePlayer()
    switch notification {
    case .episode(let feedID, let identityKey):
      guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else { return }
      navigate(to: Destination(section: .podcasts, path: [.podcastShow(itemID: itemID)]))
      presentEpisode(.init(itemID: itemID, episodeID: identityKey))
    case .show(let feedID):
      guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else { return }
      navigate(
        to: Destination(
          section: .podcasts,
          path: [.podcastShow(itemID: itemID)]))
    case .latest:
      navigate(to: Destination(section: .podcasts, path: [.latestEpisodes]))
    case .podcastsRoot:
      navigate(to: Destination(section: .podcasts))
    }
  }

  /// Drops the episode card. The swipe-down and any programmatic dismissal (not-found fallback,
  /// show line) are indistinguishable here, as with `dismissSettings()`.
  public func dismissEpisode() {
    presentedEpisode = nil
  }

  /// Drops the item-detail card. An interactive dismissal and a programmatic one share this path.
  public func dismissItemDetail() {
    presentedItemDetail = nil
  }

  /// Takes over where another graph's shell was: the selected section and every section's stack.
  /// For a graph rebuilt for the same account (an endpoint switch), where every route still
  /// resolves. Whatever was raised over the shell (settings, a card, the expanded player) is
  /// not adopted: those surfaces hold models built from the outgoing graph, and the
  /// account gate (`presentation`) is this graph's own decision.
  public func adoptLocation(from other: NavigationModel) {
    section = other.section
    paths = other.paths
  }

  /// Logout removes every account-owned state, so no stale path, section, presentation, or
  /// expanded player may survive it.
  public func resetForLogout() {
    presentation = .setup
    section = .home
    paths.removeAll()
    playerCollapseStyle = .slide
    playerPresentation = .collapsed
    settingsPresentation = .dismissed
    presentedEpisode = nil
    presentedItemDetail = nil
  }
}
