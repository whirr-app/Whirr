import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The vertical rhythm and page margin shared by the Home and Podcasts browse roots. Keeping both
/// screens on the same values prevents their otherwise-equivalent filter and first-shelf layouts
/// drifting apart, and keeps the Continue Listening rail they share starting at one x position.
nonisolated enum HomePodcastsBrowseLayout {
  static let filterRowTopSpacing: CGFloat = WhirrSpacing.medium
  static let filterBottomSpacing: CGFloat = WhirrSpacing.small
  static let firstShelfTopSpacing: CGFloat = WhirrSpacing.medium
  static let interShelfTopSpacing: CGFloat = WhirrSpacing.large
  static let headerToContentSpacing: CGFloat = WhirrSpacing.small

  static var filterToFirstShelfSpacing: CGFloat {
    filterBottomSpacing + firstShelfTopSpacing
  }

  static func shelfTopSpacing(isFirst: Bool) -> CGFloat {
    isFirst ? firstShelfTopSpacing : interShelfTopSpacing
  }

  /// The widest a browse page's content runs before it centres instead. Set by the Podcasts root's
  /// two episode reading-measure columns, which is where the page first stops gaining anything from
  /// more width; Home adopts it so both roots centre at the same window width.
  static let pageMaxWidth: CGFloat = PodcastsViewPresentation.pageMaxWidth

  /// The horizontal margin for every regular-width section of a browse root. On any width up to
  /// `maxContentWidth` plus its own margins (every iPad in every orientation, full screen) this
  /// is just `baseInset`, so the page runs edge to edge. Only a window wider than that, such as a
  /// large Stage Manager scene, grows the inset to centre the page. Compact and invalid
  /// measurements fall back to `baseInset`, the same convention `boundedRowHorizontalInset` uses.
  static func pageInset(
    availableWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?,
    maxContentWidth: CGFloat = pageMaxWidth,
    baseInset: CGFloat = WhirrSpacing.medium
  ) -> CGFloat {
    guard horizontalSizeClass == .regular, availableWidth.isFinite, availableWidth > 0 else {
      return baseInset
    }
    return baseInset + max(0, (availableWidth - 2 * baseInset - maxContentWidth) / 2)
  }
}

/// Pure presentation derivation for `HomeView`: which sections are visible and in what order, and
/// how one `HomeItem` maps onto `HomeCardView`'s parameters. `HomeView` only reads what this enum
/// produces and never recomputes a fraction, caption or badge mapping itself.
nonisolated enum HomeViewPresentation {
  /// The measured geometry of one Home shelf. Regular shelves derive capacity and card width from
  /// the viewport; compact shelves keep a minimum-sized card and scroll. No item count: sparse
  /// shelves keep full-shelf geometry.
  nonisolated struct ShelfLayout: Equatable, Sendable {
    /// Optional limits are passed to the card's text views. Removing both limits at accessibility
    /// sizes lets the title and subtitle wrap instead of truncating essential text.
    nonisolated struct TextPolicy: Equatable, Sendable {
      let titleLineLimit: Int?
      let subtitleLineLimit: Int?
    }

    static let standardCoverMinimumWidth: CGFloat = 140
    static let accessibilityCoverMinimumWidth: CGFloat = 200
    static let interCardSpacing: CGFloat = WhirrSpacing.small
    /// The card's own inset on each side. Equal to `interCardSpacing` by value and separate by
    /// meaning: this is what converts a cover minimum into the outer width the tile occupies, the
    /// convention `TileMinimumConventionTests` holds every browse surface to.
    static let cardContentPadding: CGFloat = WhirrSpacing.small

    let minimumCoverWidth: CGFloat
    let outerCardWidth: CGFloat
    let capacity: Int?
    let cardWidth: CGFloat
    let textPolicy: TextPolicy

    static func minimumCoverWidth(isAccessibilitySize: Bool) -> CGFloat {
      isAccessibilitySize ? accessibilityCoverMinimumWidth : standardCoverMinimumWidth
    }

    static func resolve(
      horizontalSizeClass: UserInterfaceSizeClass?,
      availableWidth: CGFloat,
      isAccessibilitySize: Bool
    ) -> Self {
      let minimumCoverWidth = Self.minimumCoverWidth(isAccessibilitySize: isAccessibilitySize)
      let outerCardWidth = minimumCoverWidth + 2 * cardContentPadding
      let textPolicy = TextPolicy(
        titleLineLimit: isAccessibilitySize ? nil : 2,
        subtitleLineLimit: isAccessibilitySize ? nil : 1)

      guard horizontalSizeClass == .regular else {
        return Self(
          minimumCoverWidth: minimumCoverWidth,
          outerCardWidth: outerCardWidth,
          capacity: nil,
          cardWidth: outerCardWidth,
          textPolicy: textPolicy)
      }

      let capacity = AdaptiveListLayout.columnCount(
        forContentWidth: availableWidth,
        minimumTileWidth: outerCardWidth,
        spacing: interCardSpacing)
      let measuredCardWidth = AdaptiveListLayout.tileWidth(
        forContentWidth: availableWidth,
        columns: capacity,
        spacing: interCardSpacing)
      let safeAvailableWidth = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 0

      return Self(
        minimumCoverWidth: minimumCoverWidth,
        outerCardWidth: outerCardWidth,
        capacity: capacity,
        // Before the first measurement a regular shelf has no usable width, and a zero-width card
        // would draw nothing. It holds the minimum card until layout reports a width; a measured
        // width narrower than the minimum is a genuinely narrow pane and is honoured.
        cardWidth: safeAvailableWidth > 0 ? min(measuredCardWidth, safeAvailableWidth) : outerCardWidth,
        textPolicy: textPolicy)
    }

    /// The cover drawn inside a resolved card. The card's two insets are the whole difference, so
    /// the view never does this arithmetic itself.
    var drawnCoverWidth: CGFloat {
      max(0, cardWidth - 2 * Self.cardContentPadding)
    }
  }

  /// The width a shelf's cards can share: the measured shelf viewport less the inset on each
  /// edge. An unmeasured or invalid viewport has no usable width.
  static func shelfContentWidth(viewportWidth: CGFloat, horizontalInset: CGFloat) -> CGFloat {
    guard viewportWidth.isFinite, viewportWidth > 0 else { return 0 }
    return max(0, viewportWidth - 2 * horizontalInset)
  }

  /// A cleared Continue Listening card shrinks and fades out while its neighbours spring in to
  /// close the gap, as the system does when a row leaves a collection. Reduce Motion keeps the
  /// cross-fade but drops the shrink. Keeping the decision here makes it testable without
  /// rendering the view.
  nonisolated enum ContinueListeningDismissalMotion: Sendable, Equatable {
    case springAway
    case fade

    /// The scale a leaving card shrinks to. 1 means no scaling (Reduce Motion's fade only).
    var removalScale: CGFloat {
      switch self {
      case .springAway: 0.86
      case .fade: 1
      }
    }

    var animation: Animation {
      switch self {
      case .springAway: .snappy(duration: 0.35)
      case .fade: .easeOut(duration: 0.2)
      }
    }
  }

  /// `nonisolated` because `PodcastsViewPresentation`, itself a `nonisolated` enum, derives its
  /// filter-change motion from this, and the motion policy needs no main-actor state.
  nonisolated static func continueListeningDismissalMotion(reduceMotion: Bool)
    -> ContinueListeningDismissalMotion
  {
    reduceMotion ? .fade : .springAway
  }

  /// What a state with no shelves to show puts over the scroll surface. Not a scroll element:
  /// sized to fill it would set the scroll view's own content height, and a content height derived
  /// from the container is self-sustaining. One drag collapses the large title, which grows the
  /// container, which grows the content, which holds the title collapsed.
  nonisolated enum Placeholder: Equatable {
    case loading
    case empty
  }

  /// How long `.loading` must persist before the overlay placeholder shows, so a launch whose
  /// observations land promptly shows no spinner. The readiness barrier is all-or-nothing across
  /// up to eight sources, so crossing it is routine.
  static let loadingPlaceholderDelay: Duration = .milliseconds(350)

  /// `hasWaitedForContent` is false until `loadingPlaceholderDelay` has elapsed in the current
  /// `.loading` state. Only the loading placeholder is withheld: `.empty` is a terminal answer,
  /// and delaying it would render a genuinely empty Home as a blank scroll view.
  static func placeholder(
    for state: HomeModel.State, hasWaitedForContent: Bool
  ) -> Placeholder? {
    switch state {
    case .loading: return hasWaitedForContent ? .loading : nil
    case .empty: return .empty
    case .loaded: return nil
    }
  }

  /// Latest Episodes has one durable model shared with Podcasts. Home combines that model's
  /// readiness with its item shelves instead of opening a second episode observation inside
  /// `HomeModel`. Filters that cannot render episodes ignore the episode model entirely.
  static func pageState(
    home: HomeModel.State,
    latestEpisodes: HomeMoreModel.State,
    filter: MediaFilter
  ) -> HomeModel.State {
    guard filter == .all || filter == .podcasts else { return home }
    if home == .loading || latestEpisodes == .loading { return .loading }
    return home == .loaded || latestEpisodes == .loaded ? .loaded : .empty
  }

  /// Both Home entry points for Latest Episodes resolve to the same route the Podcasts tab uses.
  /// Other shelves retain the filter currently visible on Home.
  static func detailRoute(
    for section: HomeMoreSection,
    selectedFilter: MediaFilter
  ) -> NavigationModel.Route {
    switch section {
    case .newEpisodes: .latestEpisodes
    case .smartLists: .smartLists
    default: .homeMore(section: section, filter: selectedFilter)
    }
  }

  /// The screen for one smart list, as the Podcasts tab opens it.
  static func route(forSmartListID listID: Int64) -> NavigationModel.Route {
    .smartList(id: listID)
  }

  /// One element of the screen's single scroll surface.
  struct ContentElement: Equatable, Identifiable {
    nonisolated enum Kind: Equatable {
      case filter
      case section(Section.Kind)
    }

    let kind: Kind
    let section: Section?

    var id: String {
      switch kind {
      case .filter:
        return "filter"
      case .section(let kind):
        return "section-\(kind)"
      }
    }
  }

  /// One row's identity, title, and what it holds. `HomeView` renders one of these per non-empty
  /// section, in this fixed order, omitting any empty section entirely rather than rendering it
  /// blank.
  struct Section: Equatable {
    typealias Kind = HomeMoreSection

    /// Most rows contain library items; New Episodes and Saved for Later contain projections
    /// instead.
    nonisolated enum Content: Equatable {
      case items([HomeItem])
      case podcastEpisodes([HomePodcastEpisode])
      case savedEntries([SavedShelfItem])
      /// A single card, not a strip. `nil` until the account has a snapshot, which hides it.
      case listeningStats(ListeningStatsSummary?)
      /// Rows drawn from the smart lists model, so only how many there are is carried here. None
      /// hides the section: Home never offers a first list, the Podcasts tab does.
      case smartLists(count: Int)

      var isEmpty: Bool {
        switch self {
        case .items(let items): return items.isEmpty
        case .podcastEpisodes(let episodes): return episodes.isEmpty
        case .savedEntries(let entries): return entries.isEmpty
        case .listeningStats(let summary): return summary == nil
        case .smartLists(let count): return count == 0
        }
      }
    }

    let kind: Kind
    let title: String
    let content: Content

    var items: [HomeItem] {
      if case .items(let items) = content { return items }
      return []
    }

    var podcastEpisodes: [HomePodcastEpisode] {
      if case .podcastEpisodes(let episodes) = content { return episodes }
      return []
    }

    var savedEntries: [SavedShelfItem] {
      if case .savedEntries(let entries) = content { return entries }
      return []
    }
  }

  /// Builds the relevant sections, drops any that are empty or that the reader switched off in
  /// Settings (`HomeSectionVisibility`), and arranges what survives into the reader's own order
  /// (`HomeSectionOrder`, the built-in order until they drag something).
  static func sections(
    continueListening: [HomeItem],
    continueReading: [HomeItem] = [],
    continueSeries: [HomeItem] = [],
    recentlyAdded: [HomeItem],
    newPodcastEpisodes: [HomePodcastEpisode] = [],
    downloaded: [HomeItem],
    savedForLater: [SavedShelfItem] = [],
    listeningStats: ListeningStatsSummary? = nil,
    smartListCount: Int = 0,
    filter: MediaFilter = .all,
    hiddenSections: Set<HomeMoreSection> = [],
    sectionOrder: String = ""
  ) -> [Section] {
    var sections = [
      Section(
        kind: .continueListening, title: HomeCopy.continueListeningTitle,
        content: .items(continueListening))
    ]
    if filter != .podcasts {
      sections.append(
        Section(
          kind: .continueReading, title: HomeCopy.continueReadingTitle,
          content: .items(continueReading)))
    }
    if filter != .podcasts {
      sections.append(
        Section(
          kind: .continueSeries, title: HomeCopy.continueSeriesTitle,
          content: .items(continueSeries)))
    }
    if filter == .all || filter == .podcasts {
      sections.append(
        Section(
          kind: .newEpisodes, title: HomeCopy.latestEpisodesTitle,
          content: .podcastEpisodes(newPodcastEpisodes)))
    }
    if filter != .podcasts {
      sections.append(
        Section(
          kind: .recentlyAdded, title: HomeCopy.recentlyAddedTitle,
          content: .items(recentlyAdded)))
    }
    sections.append(
      Section(kind: .downloaded, title: HomeCopy.downloadedTitle, content: .items(downloaded)))
    sections.append(
      Section(
        kind: .savedForLater, title: HomeCopy.savedForLaterTitle,
        content: .savedEntries(savedForLater)))
    // Account-wide figures, so only the unfiltered Home shows them.
    if filter == .all {
      sections.append(
        Section(
          kind: .listeningStats, title: ListeningStatsCopy.title,
          content: .listeningStats(listeningStats)))
    }
    // Lists hold podcast episodes only.
    if filter == .all || filter == .podcasts {
      sections.append(
        Section(
          kind: .smartLists, title: HomeCopy.smartListsTitle,
          content: .smartLists(count: smartListCount)))
    }
    let visible = sections.filter {
      $0.content.isEmpty == false && hiddenSections.contains($0.kind) == false
    }
    let arrangement = HomeSectionOrder.sorted(visible.map(\.kind), in: sectionOrder)
    return arrangement.compactMap { kind in visible.first { $0.kind == kind } }
  }

  /// One vertical scroll surface in every state, the filter as its first element so the header and
  /// chips recede together. Loading and empty keep only the filter in this scroll view, so a
  /// filter matching nothing neither moves it nor drops its scroll edge effect (its glass). A
  /// non-loaded state shows no shelves even while the model holds the previous filter's contents.
  static func contentElements(
    state: HomeModel.State,
    continueListening: [HomeItem],
    continueReading: [HomeItem] = [],
    continueSeries: [HomeItem] = [],
    recentlyAdded: [HomeItem],
    newPodcastEpisodes: [HomePodcastEpisode] = [],
    downloaded: [HomeItem],
    savedForLater: [SavedShelfItem] = [],
    listeningStats: ListeningStatsSummary? = nil,
    smartListCount: Int = 0,
    filter: MediaFilter = .all,
    hiddenSections: Set<HomeMoreSection> = [],
    sectionOrder: String = ""
  ) -> [ContentElement] {
    let filterElement = ContentElement(kind: .filter, section: nil)
    guard state == .loaded else { return [filterElement] }
    let sectionElements = sections(
      continueListening: continueListening,
      continueReading: continueReading,
      continueSeries: continueSeries,
      recentlyAdded: recentlyAdded,
      newPodcastEpisodes: newPodcastEpisodes,
      downloaded: downloaded,
      savedForLater: savedForLater,
      listeningStats: listeningStats,
      smartListCount: smartListCount,
      filter: filter,
      hiddenSections: hiddenSections,
      sectionOrder: sectionOrder
    ).map { section in
      ContentElement(kind: .section(section.kind), section: section)
    }
    return [filterElement] + sectionElements
  }

  /// Full-bleed list rows carry the page's vertical rhythm themselves.
  /// Everything but the page's `medium` tail rides on each row's top inset, so a row's spacing
  /// never depends on what loads after it. The filter row must not shift when the first shelf
  /// arrives.
  static func rowBottomSpacing(for kind: ContentElement.Kind, isLast: Bool) -> CGFloat {
    switch kind {
    case .filter:
      return 0
    case .section:
      return isLast ? WhirrSpacing.medium : 0
    }
  }

  /// The full-screen empty state's message (every section empty). One sentence owned by
  /// `HomeCopy`, not the per-section lines joined.
  static func emptyStateMessage() -> String {
    HomeCopy.allSectionsEmptyMessage
  }

  /// `Persistence.ItemMediaCategory` → `DesignSystem.MediaKindBadge`. A closed 1:1 mapping (same
  /// three cases on both sides) kept as an explicit switch, not a shared raw value, so DesignSystem
  /// stays decoupled from Persistence while the App target still never spells a `mediaKind`
  /// string literal.
  static func badgeKind(for category: ItemMediaCategory) -> MediaKindBadge {
    switch category {
    case .audiobook: return .audiobook
    case .podcast: return .podcast
    case .ebook: return .ebook
    }
  }

  /// The Downloaded shelf is the only Home context that narrows a podcast show on arrival.
  /// Audiobooks and ebooks still use item detail, and podcast cards in the other shelves retain
  /// their existing show/episode destinations.
  static func podcastShowFilter(
    for category: ItemMediaCategory,
    in section: HomeMoreSection
  ) -> PodcastEpisodeFilter? {
    category == .podcast && section == .downloaded ? .downloaded : nil
  }

  /// Whether a Continue Reading card is eligible to open the reader on tap when the reader's
  /// preference enables immediate opening. Otherwise the shared card-selection policy opens
  /// details, matching what the same preference does to Continue Listening.
  static func cardOpensReader(for section: HomeMoreSection) -> Bool {
    section == .continueReading
  }

  /// Whether a Continue Listening card is eligible to resume on tap when the reader's preference
  /// enables immediate opening. Otherwise the shared card-selection policy opens details.
  static func cardResumesPlayback(
    for category: ItemMediaCategory,
    in section: HomeMoreSection
  ) -> Bool {
    section == .continueListening && (category == .audiobook || category == .podcast)
  }

  static func coverFrame(forWidth width: CGFloat) -> CGSize {
    CGSize(width: width, height: width)
  }

  /// One card's fully-derived presentation values. Every formatted value (`progressFraction`,
  /// `trailingCaption`, `badgeLabel`) comes from `HomeRowPresentation` (AppModel) and is never
  /// recomputed here. `showsProgress` is `false` for Recently Added/Downloaded/Saved for Later
  /// cards, which suppresses the bar and caption regardless of the item's own progress data.
  struct Card: Equatable {
    let title: String
    let subtitle: String
    let badgeKind: MediaKindBadge
    let badgeLabel: String
    let progressFraction: Double?
    let trailingCaption: String?
    /// Non-nil marks the card finished, from the item's `isFinished`, not gated on `showsProgress`
    /// (Recently Added and Downloaded suppress the caption and would never say a title is done).
    let finishedLabel: String?
    /// Where this card's podcast came from, when the shelf it sits on mixes sources. `nil` on
    /// every other card. `PodcastSourceMarkPolicy` decides, and the shelf passes it its own
    /// resolved contents rather than each card re-deriving them.
    let sourceMark: PodcastSourceMark?
    let usesItemContextMenu: Bool
  }

  /// Whether a shelf holds podcasts from both sources, and so needs its server ones marked. Taken
  /// over the shelf's resolved contents so every card on one shelf agrees about which shelf it is
  /// on; audiobooks and ebooks are not in the question and are skipped.
  static func shelfMixesPodcastSources(items: [HomeItem]) -> Bool {
    PodcastSourceMarkPolicy.surfaceMixesSources(
      podcastItemIDs: items.filter { $0.category == .podcast }.map(\.serverItemId))
  }

  /// An episode shelf asks the same question of the shows its episodes belong to.
  static func shelfMixesPodcastSources(episodes: [HomePodcastEpisode]) -> Bool {
    PodcastSourceMarkPolicy.surfaceMixesSources(podcastItemIDs: episodes.map(\.itemID))
  }

  /// The saved shelf mixes both flavours of entry, so it asks per entry which show, if any, it
  /// stands for.
  static func shelfMixesPodcastSources(savedEntries: [SavedShelfItem]) -> Bool {
    PodcastSourceMarkPolicy.surfaceMixesSources(
      podcastItemIDs: savedEntries.compactMap(savedEntryShowID))
  }

  /// Every card on an episode shelf holds the progress bar's line, started or not, so starting an
  /// episode never resizes the shelf. Holding it only once something was started made the playing
  /// card grow on the live playhead and the rest follow when the position was saved.
  static func shelfReservesProgressLine(episodes: [HomePodcastEpisode]) -> Bool {
    true
  }

  /// New Episodes leaves finished episodes out, so an empty track there always means unstarted.
  static let episodeShelfShowsEmptyProgressTrack = true

  static func shelfReservesProgressLine(savedEntries: [SavedShelfItem]) -> Bool {
    savedEntries.contains { savedCard(for: $0).progressFraction != nil }
  }

  private static func savedEntryShowID(_ entry: SavedShelfItem) -> String? {
    guard entry.category == .podcast else { return nil }
    return entry.episode?.itemID ?? entry.itemSummary?.serverItemId
  }

  /// `progressSeconds` is the listening position the card prints (see
  /// `PlaybackModel.displayedPositionSeconds`); it defaults to the persisted position.
  static func card(
    for item: HomeItem, showsProgress: Bool, usesEbookProgress: Bool = false,
    progressSeconds: Double? = nil, playbackRate: Double = 1.0, surfaceMixesSources: Bool = false
  ) -> Card {
    let text = HomeCardText(
      item: item, showsProgress: showsProgress, usesEbookProgress: usesEbookProgress,
      progressSeconds: progressSeconds)
    let trailingCaption =
      usesEbookProgress
      ? HomeRowPresentation.ebookProgressCaption(
        ebookProgress: item.ebookProgress, isFinished: item.isFinished)
      : HomeRowPresentation.remainingCaption(
        progressSeconds: progressSeconds ?? item.progressSeconds,
        durationSeconds: item.durationSeconds,
        isFinished: item.isFinished, category: item.category, playbackRate: playbackRate)
    return Card(
      title: text.title,
      subtitle: text.subtitle ?? "",
      badgeKind: badgeKind(for: text.badgeCategory),
      badgeLabel: HomeRowPresentation.badgeLabel(for: text.badgeCategory),
      progressFraction: text.progressFraction,
      trailingCaption: showsProgress ? trailingCaption : nil,
      finishedLabel: item.isFinished ? ItemFinishedCopy.badgeLabel : nil,
      sourceMark: PodcastSourceMarkPolicy.mark(
        itemID: item.serverItemId, category: item.category,
        surfaceMixesSources: surfaceMixesSources),
      usesItemContextMenu: ItemContextMenuAvailability.offersMenu(for: item.category)
    )
  }

  /// A New Episodes card: the episode is the subject and its show the context, as on a podcast
  /// continuation card. Every formatted value comes from the
  /// `HomePodcastEpisodePresentation` the more-screen's rows already use, so Home and that screen
  /// cannot format the same episode two different ways.
  static func episodeCard(
    for episode: HomePodcastEpisode, progressSeconds: Double? = nil,
    surfaceMixesSources: Bool = false
  ) -> Card {
    let presentation = HomePodcastEpisodePresentation(
      episode: episode, progressSeconds: progressSeconds)
    return Card(
      title: presentation.title,
      subtitle: episode.showTitle,
      badgeKind: badgeKind(for: .podcast),
      badgeLabel: HomeRowPresentation.badgeLabel(for: .podcast),
      progressFraction: presentation.listening.progressFraction,
      trailingCaption: presentation.dateText,
      // New Episodes leaves finished episodes out (`DefaultHomeReading+Projection`), so there is
      // never a mark to draw; Saved for Later keeps them and draws its own below.
      finishedLabel: nil,
      sourceMark: PodcastSourceMarkPolicy.mark(
        itemID: episode.itemID, category: .podcast, surfaceMixesSources: surfaceMixesSources),
      usesItemContextMenu: ItemContextMenuAvailability.offersMenu(for: .podcast))
  }

  static func savedCard(
    for entry: SavedShelfItem, progressSeconds: Double? = nil, surfaceMixesSources: Bool = false
  ) -> Card {
    if let episode = entry.episode {
      let card = episodeCard(
        for: episode, progressSeconds: progressSeconds, surfaceMixesSources: surfaceMixesSources)
      return Card(
        title: card.title,
        subtitle: entry.isUnavailable
          ? PodcastCopy.unavailableOnServer
          : (entry.contextTitle ?? card.subtitle),
        badgeKind: card.badgeKind,
        badgeLabel: card.badgeLabel,
        progressFraction: card.progressFraction,
        // The New Episodes date says nothing about why an episode was saved.
        trailingCaption: nil,
        finishedLabel: episode.isFinished ? ItemFinishedCopy.badgeLabel : nil,
        sourceMark: card.sourceMark,
        usesItemContextMenu: card.usesItemContextMenu)
    }

    let summary = entry.itemSummary
    return Card(
      title: entry.subjectTitle.isEmpty ? (summary?.title ?? "") : entry.subjectTitle,
      subtitle: entry.isUnavailable ? HomeCopy.savedItemUnavailable : (summary?.author ?? ""),
      badgeKind: badgeKind(for: entry.category),
      badgeLabel: HomeRowPresentation.badgeLabel(for: entry.category),
      progressFraction: nil,
      trailingCaption: nil,
      // ItemSummary has no finished-state flag, so this slice cannot derive the overlay mark.
      finishedLabel: nil,
      sourceMark: summary.flatMap {
        PodcastSourceMarkPolicy.mark(
          itemID: $0.serverItemId, category: entry.category,
          surfaceMixesSources: surfaceMixesSources)
      },
      usesItemContextMenu: ItemContextMenuAvailability.offersMenu(for: entry.category))
  }
}
