import AppModel
import Foundation
import Persistence
import SyncEngine

/// The root's merged Your Shows section: which shows it previews, in what order, when it is
/// reachable, and what each show tile says about itself.
nonisolated extension PodcastsViewPresentation {
  /// The merged Your Shows section shows a bounded preview, not the all-shows page's complete
  /// grid: four full rows of the compact two-column grid, so the root is not a second copy of it.
  static let previewLimit = 8

  /// The merged root section's one heading, and the name a server-sourced tile carries in place
  /// of a second heading. The latter is spoken by `ShowTileSourceMark` and titles the host's
  /// server source page; it is not drawn on the tile.
  static let showsSectionTitle = "Your Shows"
  static let serverProvenanceLabel = PodcastSourceMark.serverLabel

  /// Takes the full `shows` arrays, not the pre-capped `preview(limit:)`, which would under-fill
  /// after the collision filter below. Both Alphabetical merges by one shared key; any other
  /// combination concatenates native then server, each in its own order, never re-sorted.
  static func mergedShowsPreview(
    native: [ItemSummary], nativeMode: NativePodcastShowSortMode,
    server: [ItemSummary], serverMode: PodcastShowSortMode,
    limit: Int
  ) -> [ItemSummary] {
    let cappedLimit = max(0, limit)
    guard cappedLimit > 0 else { return [] }

    let activeNativeFingerprints = Set(
      native.compactMap { PodcastFeedIdentity.validatedFingerprint($0.podcastFeedFingerprint) })
    let filteredServer = server.filter { show in
      guard let fingerprint = PodcastFeedIdentity.validatedFingerprint(show.podcastFeedFingerprint)
      else { return true }
      return activeNativeFingerprints.contains(fingerprint) == false
    }

    let candidates: [ItemSummary]
    if nativeMode == .alphabetical, serverMode == .alphabetical {
      // Sort the concatenation, not the pre-sorted arrays: the shared key strips a leading article
      // that native order does not, so a natively sorted array may not be sorted by it ("A Great
      // Show" before "Best Show" unstripped, after it once "A " is gone). The concatenation index
      // is an explicit tiebreak (not sort stability): native stays ahead of server on a
      // cross-source tie, and equal-keyed rows keep their source order.
      let combined = native + filteredServer
      let decorated = combined.enumerated().map { entry in
        (
          offset: entry.offset, element: entry.element,
          key: Self.mergedAlphabeticalKey(entry.element)
        )
      }
      candidates = decorated.sorted { lhs, rhs in
        if lhs.key != rhs.key { return lhs.key < rhs.key }
        return lhs.offset < rhs.offset
      }.map(\.element)
    } else {
      candidates = native + filteredServer
    }
    return Array(candidates.prefix(cappedLimit))
  }

  /// Case-insensitive on top of `ItemSortTitle.derive`'s article stripping: native's own SQL order
  /// is `COLLATE NOCASE`, server's is not, so folding case here is what keeps a same-titled pair
  /// from either source landing at the same position regardless of which one supplied it. This
  /// is a display-only key and need not reproduce either source's exact SQL collation.
  private static func mergedAlphabeticalKey(_ show: ItemSummary) -> String {
    ItemSortTitle.derive(from: show.title).lowercased()
  }

  /// The two catalogue projections are owned by different stores, but the root presents them as
  /// one collection. These helpers are the one place where the shell's availability gates are
  /// applied; the root never hides a row based on a view-local heuristic (in particular, it does
  /// not inspect an episode count).
  static func visibleNativeShows(
    _ shows: [ItemSummary], nativeSubscriptionsEnabled: Bool
  ) -> [ItemSummary] {
    nativeSubscriptionsEnabled ? shows : []
  }

  static func visibleServerShows(
    _ shows: [ItemSummary], hasIncludedPodcastLibrary: Bool
  ) -> [ItemSummary] {
    hasIncludedPodcastLibrary ? shows : []
  }

  static func showsSectionShows(
    nativeShows: [ItemSummary], nativeMode: NativePodcastShowSortMode,
    serverShows: [ItemSummary], serverMode: PodcastShowSortMode,
    nativeSubscriptionsEnabled: Bool, hasIncludedPodcastLibrary: Bool,
    limit: Int = Int.max
  ) -> [ItemSummary] {
    mergedShowsPreview(
      native: visibleNativeShows(
        nativeShows, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled),
      nativeMode: nativeMode,
      server: visibleServerShows(
        serverShows, hasIncludedPodcastLibrary: hasIncludedPodcastLibrary),
      serverMode: serverMode,
      limit: limit)
  }

  static func showsSectionIsReachable(
    nativeShows: [ItemSummary], nativeMode: NativePodcastShowSortMode,
    serverShows: [ItemSummary], serverMode: PodcastShowSortMode,
    nativeSubscriptionsEnabled: Bool, hasIncludedPodcastLibrary: Bool
  ) -> Bool {
    showsSectionShows(
      nativeShows: nativeShows, nativeMode: nativeMode,
      serverShows: serverShows, serverMode: serverMode,
      nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
      hasIncludedPodcastLibrary: hasIncludedPodcastLibrary
    ).isEmpty == false
  }

  /// The root's source-neutral catalogue status. `content` wins over a slow or failed sibling so a
  /// stale/offline source cannot blank a collection that already has rows to show. A partial
  /// snapshot with no rows still reports loading: its projection is not complete yet.
  nonisolated enum ShowsSectionStatus: Equatable, Sendable {
    case loading
    case content
    case empty
    case error
  }

  static func showsSectionStatus(
    nativeShows: [ItemSummary], nativeState: NativePodcastShowsModel.State,
    serverShows: [ItemSummary], serverState: PodcastShowsModel.State,
    nativeSubscriptionsEnabled: Bool, hasIncludedPodcastLibrary: Bool
  ) -> ShowsSectionStatus {
    let visibleNative = visibleNativeShows(
      nativeShows, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled)
    let visibleServer = visibleServerShows(
      serverShows, hasIncludedPodcastLibrary: hasIncludedPodcastLibrary)
    if visibleNative.isEmpty == false || visibleServer.isEmpty == false {
      return .content
    }

    let nativeLoading = nativeSubscriptionsEnabled && nativeState == .loading
    let serverLoading = hasIncludedPodcastLibrary && Self.serverStateIsLoading(serverState)
    if nativeLoading || serverLoading { return .loading }

    if hasIncludedPodcastLibrary, serverState == .error { return .error }
    return .empty
  }

  static func serverStateIsLoading(_ state: PodcastShowsModel.State) -> Bool {
    switch state {
    case .loading:
      true
    case .partiallySynced(let snapshot):
      snapshot.shows.isEmpty
    case .loaded, .empty, .error, .staleOffline:
      false
    }
  }

  nonisolated struct EmptyStateContent: Equatable {
    let title: String
    let message: String
    let systemImage: String
    let actionLabel: String?
  }

  /// The CTA is present only while native subscriptions are enabled. Downloads never offers a CTA:
  /// that filter is filled by downloading an episode from either source, not by following a feed.
  /// Empty libraries surface importing through Add Podcast only when direct feeds are available.
  static func emptyState(
    for filter: Filter, nativeSubscriptionsEnabled: Bool
  ) -> EmptyStateContent {
    switch filter {
    case .all:
      EmptyStateContent(
        title: "No Podcasts Yet",
        message: nativeSubscriptionsEnabled
          ? "Add a podcast or import subscriptions from another app."
          : "Your podcasts will appear here.",
        systemImage: "antenna.radiowaves.left.and.right",
        actionLabel: nativeSubscriptionsEnabled ? addPodcastActionLabel : nil)
    case .yourShows:
      EmptyStateContent(
        title: "No Shows Yet",
        message: nativeSubscriptionsEnabled
          ? "Add a podcast or import subscriptions from another app."
          : "Your shows will appear here.",
        systemImage: "antenna.radiowaves.left.and.right",
        actionLabel: nativeSubscriptionsEnabled ? addPodcastActionLabel : nil)
    case .downloaded:
      EmptyStateContent(
        title: "No Downloads Yet",
        message: "Downloaded podcast episodes will appear here.",
        systemImage: "arrow.down.circle", actionLabel: nil)
    }
  }

  static func showsServerSection(
    hasIncludedPodcastLibrary: Bool, serverShows: [ItemSummary]
  ) -> Bool {
    hasIncludedPodcastLibrary && serverShows.isEmpty == false
  }

  /// The Followed heading is a live navigation link the moment there is anywhere to navigate to
  /// (even a single show, and even at or under `previewLimit`) because the all-shows page is
  /// also how a user reaches Edit mode, and rearrangement must stay reachable at any collection
  /// size. No shows means the root's empty-state handling owns the screen and no empty Followed
  /// link is drawn.
  static func showsHeadingIsReachable(in state: PodcastShowsModel.State) -> Bool {
    shows(in: state).isEmpty == false
  }

  /// Read by the heading's `.accessibilityHint`. Names both what the destination shows and what
  /// it lets you do, since the same push is also the only way to reach the all-shows page's Edit
  /// mode.
  static let showsHeadingAccessibilityHint = "Shows all podcasts and editing controls."

  /// The row under a capped grid. Your Shows is the root's last section, so by the time a reader
  /// reaches the end of the preview its heading (the only other route to the rest) has scrolled
  /// away, and a grid ending on a full row reads as the whole collection. The count says
  /// otherwise. Nil whenever nothing is hidden, including under the Shows chip, which lists all.
  static func showsFooterTitle(totalCount: Int, shownCount: Int) -> String? {
    guard totalCount > shownCount else { return nil }
    return "All \(totalCount) Shows"
  }

  /// The author line is reserved the same way, which leaves the view one question to answer: is
  /// there an author worth drawing? A feed that pads its publisher field with whitespace, or sends
  /// an empty one, means "no author" exactly as a missing field does.
  static func showTileAuthor(_ author: String?) -> String? {
    guard let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines),
      trimmed.isEmpty == false
    else {
      return nil
    }
    return trimmed
  }

  /// Where the title and author lines are reserved on every tile, the credential-recovery line
  /// under the author is not: it is empty until a feed stops authenticating, so reserving it
  /// unconditionally would add a blank caption line to every tile in every grid. It is reserved
  /// only while some show in the same grid carries the notice, which keeps that grid's tiles one
  /// height without charging every other grid.
  enum ShowTileAttentionRow: Equatable, Sendable {
    case omitted
    case reserved
    case shown
  }

  static func showTileAttentionRow(
    needsAttention: Bool, gridNeedsAttention: Bool
  ) -> ShowTileAttentionRow {
    if needsAttention { return .shown }
    return gridNeedsAttention ? .reserved : .omitted
  }

  /// A native show source has no server item id to test, so this is purely a
  /// fact about the show, reusing `PodcastSourceIdentity`'s `rss:`-namespace decode rather than
  /// a second source tag.
  static func showTileIsServerSourced(_ show: ItemSummary) -> Bool {
    PodcastSourceIdentity(itemId: show.serverItemId)?.absItemId != nil
  }

  /// Provenance is a mark on the cover, not a caption line, which would grow every tile; only the
  /// exception carries it. The label is spoken, never drawn: the mark is decorative and the tile
  /// combines into one utterance. Defined in AppModel, shared with Home's shelves.
  typealias ShowTileSourceMark = PodcastSourceMark

  /// Nil unless the tile is the marked exception and the grid it sits in raises the question at
  /// all. A single-source grid answers it in its own title, and the root grid answers it the same
  /// way whenever native subscriptions are off, so badging every tile there would say nothing.
  static func showTileSourceMark(
    isServerSourced: Bool, gridMixesSources: Bool
  ) -> ShowTileSourceMark? {
    isServerSourced && gridMixesSources ? .server : nil
  }

  /// A grid mixes sources only when it holds both kinds. Taken as the grid's resolved facts rather
  /// than re-derived per tile, so every tile in one grid agrees about which grid it is in.
  static func gridMixesSources(tilesAreServerSourced: [Bool]) -> Bool {
    tilesAreServerSourced.contains(true) && tilesAreServerSourced.contains(false)
  }
}
