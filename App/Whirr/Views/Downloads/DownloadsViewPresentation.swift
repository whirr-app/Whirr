import AppModel
import CoreGraphics
import Persistence
import SwiftUI

/// Interaction policy for download rows. Keeping this separate from the view makes the choice of
/// native disclosure and swipe-only deletion explicit and testable.
enum DownloadsViewPresentation {
  /// Stable, source-qualified identities for native List selection.  Raw episode IDs are only
  /// unique inside a show, and RSS feed IDs are numeric, so keeping the source and parent in the
  /// identity prevents a child row from selecting an unrelated server row.
  enum SelectionID: Hashable, Sendable {
    case absItem(String)
    case absEpisode(itemID: String, episodeID: String)
    case rssFeed(Int64)
    case rssEpisode(feedID: Int64, episodeID: String)
  }

  struct SelectionPlan: Equatable, Sendable {
    var absItemIDs: Set<String>
    var absEpisodeIDs: Set<AbsEpisodeID>
    var rssFeedIDs: Set<Int64>
    var rssEpisodeIDs: Set<RSSEpisodeID>

    struct AbsEpisodeID: Hashable, Sendable {
      let itemID: String
      let episodeID: String
    }

    struct RSSEpisodeID: Hashable, Sendable {
      let feedID: Int64
      let episodeID: String
    }

    var isEmpty: Bool {
      absItemIDs.isEmpty && absEpisodeIDs.isEmpty && rssFeedIDs.isEmpty && rssEpisodeIDs.isEmpty
    }
  }

  /// Builds the exact work a confirmed selection action may perform.  Eligibility is checked from
  /// the current visible IDs immediately before confirmation; a selected parent owns all of its
  /// children, so selecting both never purges the same download twice.
  static func selectionPlan(
    selected: Set<SelectionID>, eligible: Set<SelectionID>
  ) -> SelectionPlan {
    let selected = selected.intersection(eligible)
    let absItems = Set(
      selected.compactMap { id -> String? in
        guard case .absItem(let itemID) = id else { return nil }
        return itemID
      })
    let rssFeeds = Set(
      selected.compactMap { id -> Int64? in
        guard case .rssFeed(let feedID) = id else { return nil }
        return feedID
      })
    let absEpisodes = Set(
      selected.compactMap { id -> SelectionPlan.AbsEpisodeID? in
        guard case .absEpisode(let itemID, let episodeID) = id, absItems.contains(itemID) == false else {
          return nil
        }
        return .init(itemID: itemID, episodeID: episodeID)
      })
    let rssEpisodes = Set(
      selected.compactMap { id -> SelectionPlan.RSSEpisodeID? in
        guard case .rssEpisode(let feedID, let episodeID) = id, rssFeeds.contains(feedID) == false else {
          return nil
        }
        return .init(feedID: feedID, episodeID: episodeID)
      })
    return SelectionPlan(
      absItemIDs: absItems, absEpisodeIDs: absEpisodes,
      rssFeedIDs: rssFeeds, rssEpisodeIDs: rssEpisodes)
  }

  /// The top-level rows contributed by each download source. RSS rows stay in persistence while
  /// native subscriptions are disabled, but are dormant presentation data until the preference is
  /// enabled again.
  nonisolated enum Row: Equatable {
    case abs(itemID: String)
    case rss(feedID: Int64)
  }

  /// The storage rows that belong in the item block. Storage lists device feeds as `rss:` rows
  /// so its totals cover the whole device, and the Home model's downloaded section carries the
  /// same feeds under the same ids. An intersection that ignores source would admit every feed
  /// into the item block and draw it a second time, but `RSSDownloadsView` is the only renderer
  /// a feed may have on this screen.
  static func absItemIDs(from rows: [StorageModel.ItemRow]) -> [String] {
    rows.filter { $0.source == .abs }.map(\.itemId)
  }

  static func mergedRows(
    absItemIDs: [String],
    rssFeedIDs: [Int64],
    nativeSubscriptionsEnabled: Bool
  ) -> [Row] {
    absItemIDs.map(Row.abs)
      + (nativeSubscriptionsEnabled ? rssFeedIDs.map(Row.rss) : [])
  }

  nonisolated enum Placeholder: Equatable {
    case loading
    case empty

    var allowsHitTesting: Bool { false }
  }

  /// Downloads has two independent readiness inputs. Keeping the precedence here makes the view
  /// keep one `List` mounted without duplicating the loading/empty decision in its row builder.
  static func placeholder(
    homeState: HomeMoreModel.State,
    hasLoadedDownloadedItems: Bool,
    hasRows: Bool
  ) -> Placeholder? {
    guard homeState != .loading, hasLoadedDownloadedItems else { return .loading }
    guard homeState != .empty, hasRows else { return .empty }
    return nil
  }

  enum PodcastExpansion: Equatable {
    case systemDisclosure
  }

  /// What an expanded show's folder renders.
  nonisolated enum EpisodeFolderContent: Equatable {
    case loading
    case episodes
    case empty
    case unavailable(PodcastShowModel.State)
  }

  /// A `PodcastShowModel` starts at `.loading` with no episodes and is filled by an observation
  /// yield, so "has no episodes" and "has not answered yet" are the same value on the first frame.
  /// The episode count alone would report an empty folder, and that one-line placeholder would set
  /// the disclosure animation's target height, which the real rows then abandon by arriving
  /// outside the animation. `state` separates the two.
  static func episodeFolderContent(
    state: PodcastShowModel.State,
    hasEpisodes: Bool
  ) -> EpisodeFolderContent {
    if hasEpisodes { return .episodes }
    // `.loading` is the pre-first-yield state. Settled failures keep their reason instead of being
    // presented as a genuinely empty folder.
    switch state {
    case .loading:
      return .loading
    case .staleOffline, .recoverableError, .partiallyDecoded:
      return .unavailable(state)
    case .empty, .loaded, .refreshing:
      return .empty
    }
  }

  /// When a show's episode observation is opened.
  ///
  /// On the row's appearance, not first expansion, which would leave the content empty as the
  /// expansion animates (see `episodeFolderContent`). Only shows with downloads are listed, so
  /// open observations stay few.
  enum EpisodeObservationWarmUp: Equatable {
    case whenRowAppears
  }

  static let episodeObservationWarmUp: EpisodeObservationWarmUp = .whenRowAppears

  enum DeleteInteraction: Equatable {
    case trailingSwipe
  }

  enum PodcastDeleteActionVisibility: Equatable {
    case always
  }

  enum PodcastDeleteActionPlacement: Equatable {
    case disclosureLabel
  }

  enum DeleteActionTint: Equatable {
    case destructiveRed
  }

  /// An alert, not a confirmation dialog. A dialog anchors to its presenter, and these
  /// confirmations must be presented from the screen because the swipe action tears its own row
  /// down as it closes, taking any presenter mounted on that row with it. A dialog anchored to the
  /// screen root parks at the top of the window, away from its row. An alert is unanchored, so it
  /// survives the teardown.
  enum PurgeConfirmation: Equatable {
    case systemAlert
  }

  enum PurgeConfirmationAnchor: Equatable {
    case stableDownloadsScreen
  }

  /// Where every confirmation that `StorageModel` does not stage is mounted (a server episode's,
  /// a device feed's, a device episode's). Not the row that asked for it: a modifier applied to a
  /// multi-row group inside the `List` applies to each row, so one pending deletion makes every
  /// row present the same confirmation at once and they cancel each other out.
  enum EpisodeDeleteConfirmationHost: Equatable {
    case downloadsScreen
  }

  /// The `ButtonRole` of the delete swipe button: none. Inside `swipeActions`, SwiftUI reads
  /// `.destructive` as permission to delete the row and collapses it as the swipe closes, before
  /// the confirmation is answered. An explicit red tint carries the warning instead (as in
  /// `PodcastEpisodeSwipeButtons`); the context-menu twin keeps the role, which only colours it.
  enum SwipeDeleteButtonRole: Equatable {
    case none
  }

  /// What a `false` write to a confirmation's `isPresented` binding means here.
  ///
  /// Not a cancellation: an alert writes `false` on every dismissal, including its Delete button's
  /// and possibly first, so treating that as a cancel would leave `StorageModel.confirmPurge`
  /// nothing staged. Only the buttons resolve the staged state, synchronously.
  enum ConfirmationDismissal: Equatable {
    case resolvedByItsButtons
  }

  static let podcastExpansion: PodcastExpansion = .systemDisclosure
  static let episodeContentLeadingInset: CGFloat = 0
  static let podcastDeleteActionVisibility: PodcastDeleteActionVisibility = .always
  static let podcastDeleteActionPlacement: PodcastDeleteActionPlacement = .disclosureLabel
  static let episodeDeleteConfirmationHost: EpisodeDeleteConfirmationHost = .downloadsScreen
  static let swipeDeleteButtonRole: SwipeDeleteButtonRole = .none
  static let confirmationDismissal: ConfirmationDismissal = .resolvedByItsButtons
  static let deleteInteraction: DeleteInteraction = .trailingSwipe

  /// Always `true`, and a function of `isExpanded` so the pin is visible: expanding a show inserts
  /// its episode rows, and the parent row's swipe structure must not change in that same batch
  /// update. The action lives on the disclosure label so it stays installed without being
  /// inherited by the disclosed episode rows.
  static func installsPodcastDeleteSwipeAction(isExpanded: Bool) -> Bool {
    podcastDeleteActionVisibility == .always || isExpanded == false
  }
  static let allowsFullSwipeToDelete = false
  static let deleteActionTitle = MediaActionCopy.removeSwipeTitle
  static let deleteActionSystemImage = MediaActionCopy.removeDownload.systemImage
  static let deleteActionTint: DeleteActionTint = .destructiveRed
  static let purgeConfirmation: PurgeConfirmation = .systemAlert
  static let purgeConfirmationAnchor: PurgeConfirmationAnchor = .stableDownloadsScreen

  static let episodeDeleteMessage = "This removes the downloaded episode from this device."

  static func episodeDeleteTitle(title: String) -> String {
    "Remove “\(title)”?"
  }

  /// The episode row's second line. The published date uses the pinned POSIX/GMT convention every
  /// absolute episode date surface shares, so one instant renders one day here too.
  static func episodeDetail(_ episode: PodcastEpisodeSummary) -> String {
    var parts: [String] = []
    if let publishedAt = episode.publishedAt {
      parts.append(PodcastCopy.podcastPublishedDate(publishedAt))
    }
    if let sizeBytes = episode.sizeBytes {
      parts.append(
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
    }
    if parts.isEmpty, let duration = episode.durationSeconds {
      parts.append(PodcastCopy.duration(seconds: duration))
    }
    return parts.joined(separator: " · ")
  }

  /// The motion a confirmed removal leaves with. Removals arrive from a persistence observation,
  /// and a `List` animates a diff only when the causing change carries the transaction
  /// (`PodcastsViewPresentation.filterChangeMotion`), so the screen mirrors row membership into its
  /// own state inside `withAnimation` of this. The first population is exempt.
  nonisolated static func rowRemovalMotion(reduceMotion: Bool) -> Animation {
    HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: reduceMotion).animation
  }

  nonisolated static func animatesRowMembershipChange(wasEmpty: Bool) -> Bool {
    wasEmpty == false
  }
}
