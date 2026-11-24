import AppModel
import Persistence
import SwiftUI

/// Pure presentation derivation for `PodcastsView`, which composes three independently-loading
/// models. Kept out of the view and out of any one model so the "which state wins" decisions can
/// be tested without rendering.
nonisolated enum PodcastsViewPresentation {
  enum Filter: String, CaseIterable, Equatable {
    case all
    case yourShows
    case downloaded

    /// What VoiceOver announces for the chip strip as a whole.
    static let title = "Podcast Filter"

    /// One word each: the chips have to sit on one line without scrolling at the default text
    /// size, and the section headings underneath already say the long form.
    var label: String {
      switch self {
      case .all: "All"
      case .yourShows: "Shows"
      case .downloaded: "Downloads"
      }
    }
  }

  /// The New Episode Notifications offer keeps out of Downloads, where an empty state can be due
  /// while shows are followed and would cover it.
  static func showsNotificationOffer(for filter: Filter) -> Bool {
    switch filter {
    case .all, .yourShows: true
    case .downloaded: false
    }
  }

  /// The motion a filter change hands to the sections underneath. Apply it to the stack's content
  /// inside the scroll view, not the scroll view: on the container it also animates the scroll
  /// view's geometry, parking the page in overscroll when a change lands as a pull-to-refresh
  /// closes. Same curve as Home's Continue Listening dismissal.
  static func filterChangeMotion(reduceMotion: Bool) -> Animation {
    HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: reduceMotion).animation
  }

  /// Continue Listening on Podcasts is Home's shelf with the podcast filter applied, so it is
  /// built as the same section Home renders. An empty list has no section at all.
  static func continueListeningSection(_ items: [HomeItem]) -> HomeViewPresentation.Section? {
    guard items.isEmpty == false else { return nil }
    return HomeViewPresentation.Section(
      kind: .continueListening, title: HomeCopy.continueListeningTitle, content: .items(items))
  }

  // MARK: - All layout sections (hide and reorder)

  /// The All layout's sections in the reader's order with the hidden ones removed. A stale or
  /// junk preference can only reorder, never drop, a section (`PodcastsRootSectionOrder`).
  static func visibleRootSections(
    hiddenSections: String, sectionOrder: String
  ) -> [PodcastsRootSection] {
    let hidden = PodcastsRootSectionVisibility.hidden(in: hiddenSections)
    return PodcastsRootSectionOrder.ordered(in: sectionOrder).filter { hidden.contains($0) == false }
  }

  /// Settings label for a section, matching the heading it draws on the page.
  static func rootSectionTitle(_ section: PodcastsRootSection) -> String {
    switch section {
    case .continueListening: HomeCopy.continueListeningTitle
    case .latestEpisodes: HomeCopy.latestEpisodesTitle
    case .smartLists: SmartListsPresentation.sectionTitle
    case .yourShows: showsSectionTitle
    }
  }

  /// A section draws only when it is visible and has something to show; an empty section has no
  /// heading, as before. Not `hasContent`: that decides the placeholder and counts hidden
  /// sections too, so a reader who hid everything is not told they follow nothing.
  static func drawnRootSections(
    visible: [PodcastsRootSection],
    hasContinueListening: Bool,
    hasLatestEpisodes: Bool,
    hasSmartLists: Bool,
    showsSectionIsReachable: Bool
  ) -> [PodcastsRootSection] {
    visible.filter { section in
      switch section {
      case .continueListening: hasContinueListening
      case .latestEpisodes: hasLatestEpisodes
      case .smartLists: hasSmartLists
      case .yourShows: showsSectionIsReachable
      }
    }
  }

  static let sectionsEntryTitle = "Podcasts Sections"
  static let sectionsSettingsTitle = "Podcast Sections"
  static let sectionsEntryAccessibilityID = "podcasts.customizeSectionsLink"
  static let sectionRowAccessibilityIDPrefix = "podcasts.sectionRow."

  /// A show tile opened from Downloads lands on that show's downloaded episodes, the same deep link
  /// Home and Library use for a downloaded podcast; every other filter opens the full show.
  static func showTileEpisodeFilter(for filter: Filter) -> PodcastEpisodeFilter {
    filter == .downloaded ? .downloaded : .all
  }

  /// The Downloads filter is one source-neutral grid. Native shows keep the followed-show order
  /// and lead server shows, matching All and Shows; each source is filtered, never re-sorted.
  static func downloadedShows(
    serverShows: [ItemSummary], nativeShows: [ItemSummary],
    downloadedServerIDs: Set<String>, downloadedNativeFeedIDs: Set<Int64>
  ) -> [ItemSummary] {
    let downloadedNativeShows = nativeShows.filter { show in
      guard let feedID = PodcastSourceIdentity(itemId: show.serverItemId)?.rssFeedId else {
        return false
      }
      return downloadedNativeFeedIDs.contains(feedID)
    }
    return downloadedNativeShows
      + serverShows.filter { downloadedServerIDs.contains($0.serverItemId) }
  }

  /// One wash per parent show, even when several episodes belong to it. The root draws the list
  /// only under `.all`; the filter check lives here so the bulk trigger is testable.
  static func latestEpisodeWashItemIDs(
    for filter: Filter, episodes: [HomePodcastEpisode]
  ) -> [String] {
    latestEpisodeWashSubjects(for: filter, episodes: episodes).itemIDs
  }

  /// One subject per show in the list, each carrying its show's artwork source, so the page's
  /// bulk request colours device-owned shows as well as server ones.
  static func latestEpisodeWashSubjects(
    for filter: Filter, episodes: [HomePodcastEpisode]
  ) -> [EditorialWashSubject] {
    guard filter == .all else { return [] }

    var seen = Set<String>()
    return latestEpisodePreview(episodes).compactMap { episode in
      seen.insert(episode.itemID).inserted ? episode.washSubject : nil
    }
  }

  static func isPlaying(
    episode: HomePodcastEpisode,
    nowPlaying: ListeningIdentity?,
    isPlaybackActive: Bool
  ) -> Bool {
    // Go through the policy: `ListeningIdentity.podcastEpisode` returns `nil` for a native feed's
    // `rss:` item id, which would never match a playing feed episode and would match a `nil`
    // now-playing identity instead.
    guard isPlaybackActive, let nowPlaying else { return false }
    return nowPlaying
      == ListeningQueueActionPolicy.identity(
        itemID: episode.itemID, episodeID: episode.episodeID, category: .podcast)
  }

  /// Every state that carries a cached snapshot renders it, settled or not: a still-syncing or
  /// stale-offline library is still one you can pick a show from. Delegates to
  /// `PodcastShowsViewPresentation.shows(in:)` so the root and the all-shows page share one
  /// ordering rule.
  static func shows(in state: PodcastShowsModel.State) -> [ItemSummary] {
    PodcastShowsViewPresentation.shows(in: state)
  }

  /// Every control the Podcasts root installs in its own navigation bar, by label.
  ///
  /// No Up Next control: Up Next belongs to Now Playing, and a root toolbar button would look like
  /// a lightweight Liquid Glass affordance while pushing a whole page. Declared so a control added
  /// to the root's toolbar has to pass through `theRootInstallsNoQueueToolbarControl` first.
  static let addPodcastActionLabel = "Add Podcast"
  static let rootToolbarItems: [String] = [addPodcastActionLabel]

  /// Shared by the Podcasts tab's latest-episode row and `HomeMoreView`'s podcast episode row,
  /// whose tap opens one specific episode, not its show.
  static let episodeRowAccessibilityHint = "Opens the episode."

  /// Latest-episodes rows exclude finished episodes but can still be part-played. The caller
  /// resolves raw progress, and the row reaches the same swipe policy as a show-screen row. The
  /// root menu offers Download without server-availability data, so the episode is treated as
  /// server-available and the request/alert path reports a missing file.
  static func swipeButtons(
    deviceAction: ItemContextMenuDownloadAction,
    itemID: String,
    episodeID: String,
    playbackStatus: ItemPlaybackStatus?,
    nowPlaying: ListeningIdentity?,
    isPlaybackIntended: Bool
  ) -> (leading: [PodcastEpisodeSwipeButton], trailing: [PodcastEpisodeSwipeButton])? {
    // Go through the policy: `ListeningIdentity.podcastEpisode` accepts only the ABS namespace, so
    // a native feed's `rss:` item id resolves to `nil`, which reads as "not queueable" and
    // withdraws the leading edge from every native-feed row whenever the player holds an identity.
    let identity = ListeningQueueActionPolicy.identity(
      itemID: itemID, episodeID: episodeID, category: .podcast)
    let actions = PodcastEpisodeSwipeActions.actions(
      deviceAction: deviceAction,
      isAvailableOnServer: true,
      playbackStatus: playbackStatus,
      identity: identity,
      nowPlaying: nowPlaying,
      isPlaybackIntended: isPlaybackIntended)
    return PodcastShowViewPresentation.swipeButtons(for: actions)
  }
}
