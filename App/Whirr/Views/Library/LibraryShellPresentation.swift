import ABSApi
import AppModel
import Foundation
import Observation
import Persistence

/// The shell-level editorial work gate: a pure level calculation over the current presentation
/// bindings. Any active presentation suspends work; release waits for that presentation's
/// `onDismiss`, after its dismissal animation completes.
enum EditorialSuspensionPolicy {
  static func suspended(
    settingsPresented: Bool,
    episodePresented: Bool,
    itemDetailPresented: Bool,
    playerPresented: Bool
  ) -> Bool {
    settingsPresented || episodePresented || itemDetailPresented || playerPresented
  }
}

enum LibraryShellPresentation {
  static let settingsSystemImage = "gearshape"

  /// ADR 0008: item detail is pushed at compact width and raised as a centred card at regular
  /// width. The shell resolves its window's size class and hands the answer to `NavigationModel`,
  /// which cannot read one. That keeps `navigate(to: .itemDetail)` the single call-site vocabulary.
  static func itemDetailPresentation(
    isRegularWidth: Bool
  ) -> NavigationModel.ItemDetailPresentation {
    isRegularWidth ? .card : .push
  }

  /// Item selection defers navigation two ways: podcasts only yield once so the search field's
  /// focus resignation can commit, while books wait out the palette-preparation budget.
  enum SelectionNavigationScheduling: Equatable {
    case afterCurrentTransaction
    case afterPalettePreparation
  }

  static func selectionNavigationScheduling(
    for category: ItemMediaCategory
  ) -> SelectionNavigationScheduling {
    switch category {
    case .podcast:
      return .afterCurrentTransaction
    case .audiobook, .ebook:
      return .afterPalettePreparation
    }
  }

  /// `CaseIterable` in the order `rootToolbar` declares its items: inboard to outboard, Select,
  /// funnel, Add Podcast, then the gear. Select is inboard of the filter and the gear keeps the
  /// outside edge. Every section's `rootToolbarTrailingOrder` must be a subsequence of this (see
  /// `toolbarOrdersAreExpressibleByTheShell`).
  enum RootToolbarTrailingItem: Equatable, Hashable, CaseIterable {
    case select
    case filter
    case addFeed
    case settings
  }

  /// Decides what the trailing group holds and in what order. `rootToolbar` builds straight from
  /// this, so no section declares its own controls separately.
  ///
  /// The funnel is always inboard of the gear: Settings is the one control every section shares,
  /// so it holds the outside edge and the per-section control sits beside it.
  static func rootToolbarTrailingOrder(
    in section: NavigationModel.Section,
    nativeSubscriptionsEnabled: Bool,
    isSelecting: Bool
  ) -> [RootToolbarTrailingItem] {
    guard !isSelecting, showsSettingsShortcut(in: section) else { return [] }
    switch section {
    case .library: return [.select, .filter, .settings]
    case .search: return [.filter, .settings]
    // Add Podcast is a per-section control, so it is placed here rather than from inside
    // `PodcastsView`. Inboard of the gear, as above.
    case .podcasts: return nativeSubscriptionsEnabled ? [.addFeed, .settings] : [.settings]
    case .home, .settings: return [.settings]
    }
  }

  /// Whether a root keeps its title at large size in the bar rather than as a collapsing large
  /// title. The collapse relays out the whole navigation bar each time a fling crosses the top of
  /// the page; on device that layout preceded every Podcasts scroll hitch, and a shorter page
  /// crosses the top more often. Library matches so the three shelf roots sit at one level.
  /// Search shows no title at all (`hidesRootTitle`).
  static func usesInlineLargeTitle(in section: NavigationModel.Section) -> Bool {
    switch section {
    case .home, .library, .podcasts: true
    case .search, .settings: false
    }
  }

  /// Whether a root shows no title in its bar. Tapping the Search tab activates its field, and an
  /// active search hides the bar's title, so a title there would flash for a frame or two on every
  /// visit. The field and the selected tab already name the screen.
  static func hidesRootTitle(in section: NavigationModel.Section) -> Bool {
    section == .search
  }

  /// Whether Library's Select control is present: only Titles offers selection. Derived from the
  /// shell's browse mode so it is right on the first frame of a pop back; a flag set from
  /// appearance callbacks would drop the control for the whole swipe.
  static func showsSelectionEntry(in mode: LibraryBrowsePresentation.Mode) -> Bool {
    mode == .titles
  }

  /// SwiftUI receives four structurally similar `NavigationStack`s from the shared section
  /// builder. Each gets the same durable identity as its tab so an outgoing stack is never reused
  /// as the incoming tab for a frame while the system coordinates the tab transition.
  static func navigationStackIdentity(
    for section: NavigationModel.Section
  ) -> NavigationModel.Section {
    section
  }

  /// Settings is raised from a content root's toolbar, so the shortcut appears on every section
  /// except the one it opens. The settings stack is built through the same `section(_:)` helper
  /// and must not offer a gear that reopens what you are already inside.
  static func showsSettingsShortcut(in section: NavigationModel.Section) -> Bool {
    section != .settings
  }

  /// Selection knows the destination's full artwork identity before SwiftUI mounts it. Building
  /// the key here keeps the tap-time request identical to `ItemDetailView`'s hero request, so both
  /// subscribers join one pipeline operation rather than loading two variants.
  static func detailArtworkPreflightKey(
    for route: NavigationModel.Route,
    source: ArtworkSource?,
    displayScale: CGFloat
  ) -> ArtworkKey? {
    switch route {
    case .itemDetail(let itemID, let seed):
      guard itemID.isEmpty == false, let source else { return nil }
      // The seed is the tapped row, so it carries the revision the hero keys by. A seedless route
      // (a deep link) has none; its preflight is unversioned and the hero re-keys once the item
      // loads.
      return ArtworkKey(
        source: source,
        itemID: itemID,
        variant: DetailArtwork.variant(
          itemID: itemID, revision: seed?.artworkRevision ?? .unversioned,
          displayScale: Double(displayScale)),
        revision: seed?.artworkRevision ?? .unversioned)

    case .podcastShow(let itemID, _, let seed):
      // A seedless route has no provider identity yet; guessing an account-scoped key would
      // preflight the wrong namespace for an RSS show.
      guard itemID.isEmpty == false, seed != nil, let source else { return nil }
      return ArtworkKey(
        source: source,
        itemID: itemID,
        variant: .homeCard(
          displaySize: Double(HomeView.cardCoverSize), displayScale: Double(displayScale)),
        revision: seed?.artworkRevision ?? .unversioned)

    default:
      return nil
    }
  }
}

/// A monotonic counter, so repeated taps (same section value) still register as changes. Library
/// alone needs it: its `.searchable` drawer sits above where the system's reselect scroll stops,
/// while Home and Podcasts keep their filter row at offset zero and a second scroll would race.
struct LibraryReselectRequests: Equatable {
  private(set) var count = 0

  /// Separate from `record` so the caller can skip the `mutating` call entirely. Calling a
  /// mutating method on `@State` writes the box back whether or not the value changed, and that
  /// write invalidates the shell on every tab switch, not just a Library reselect.
  static func isReselect(
    _ selection: NavigationModel.Section,
    current: NavigationModel.Section
  ) -> Bool {
    selection == .library && selection == current
  }

  mutating func record(
    _ selection: NavigationModel.Section,
    current: NavigationModel.Section
  ) {
    guard Self.isReselect(selection, current: current) else { return }
    count += 1
  }
}

/// The `TabView`'s selection, reached through a key path on one long-lived object.
///
/// A `Binding(get:set:)` built in the shell's body is a new location each evaluation, re-evaluating
/// `TabView` and every visited tab; `Bindable(relay).selection` is stable. The closures are
/// refreshed per body evaluation and not observed.
@MainActor
@Observable
final class LibraryTabSelectionRelay {
  @ObservationIgnored var read: () -> NavigationModel.Section = { .home }
  @ObservationIgnored var write: (NavigationModel.Section) -> Void = { _ in }

  var selection: NavigationModel.Section {
    get { read() }
    set { write(newValue) }
  }
}

/// Shell-owned subscriber for the exact detail artwork operation. Separate from the bounded
/// palette/navigation task so starting a transfer never extends navigation's one-frame palette
/// budget. Replacing a selection cancels this subscriber only;
/// `ArtworkImagePipeline` keeps shared work alive when the mounted destination is still waiting.
@MainActor
final class LibrarySelectionArtworkPreflight {
  private var task: Task<Void, Never>?
  private var itemID: String?

  func start(
    key: ArtworkKey?,
    operation: @escaping @Sendable (ArtworkKey) async -> Void
  ) {
    task?.cancel()
    task = nil
    itemID = key?.itemID
    guard let key else { return }
    task = Task(priority: .userInitiated) {
      await operation(key)
    }
  }

  /// Cancels the preflight when the destination goes away, so the pipeline's pre-decode checkpoint
  /// fires instead of finishing for nobody. Matched on item: a push from a detail screen
  /// disappears the covered one, which is not the new destination going away.
  func destinationDisappeared(itemID: String) {
    guard self.itemID == itemID else { return }
    task?.cancel()
    task = nil
    self.itemID = nil
  }
}

/// Pure get/set pair behind `LibraryShellView`'s settings `.sheet(isPresented:)` binding, as
/// `PlayerPresentationBinding` is for the expanded player. `NavigationModel`'s presentation is
/// `private(set)`, so this forms the `Binding<Bool>`; a plain struct lets both directions be
/// asserted without constructing a view.
@MainActor
struct SettingsPresentationBinding {
  let navigation: NavigationModel

  var get: Bool { navigation.settingsPresentation == .presented }

  func set(_ isPresented: Bool) {
    if isPresented {
      navigation.presentSettings()
    } else {
      // Also the path a system swipe-down dismissal takes, indistinguishable from Done here.
      navigation.dismissSettings()
    }
  }
}
