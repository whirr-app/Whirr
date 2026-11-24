import Foundation
import Persistence

extension NavigationModel {
  /// Pushable destinations only. Anything reachable as a tab belongs in `Section`, not here.
  ///
  /// Up Next is absent: it is a presentation the expanded player owns, like its
  /// Chapters/Rate/Sleep sheets, and opening it must not change any section's path.
  public enum Route: Sendable, Equatable, Hashable {
    case itemDetail(itemID: String, seed: ItemSummary? = nil)
    /// A podcast show's episode list. Kept distinct from `itemDetail` so the App target never
    /// has to inspect a raw `mediaKind` string while resolving a pushed destination. `seed` is
    /// display data from an in-app row, absent from route identity and deep links like
    /// `itemDetail`'s seed.
    case podcastShow(
      itemID: String, filter: PodcastEpisodeFilter = .all, seed: ItemSummary? = nil)
    /// The all-shows page: the complete, ordered Your Shows grid the Podcasts root's bounded
    /// preview pushes to. A content destination on the `.podcasts` stack, not a sheet and not a
    /// Settings route.
    case podcastShows
    /// The device-owned native subscription collection, distinct from the ABS all-shows page.
    case nativePodcastShows
    /// A bounded expansion of one Home section, retaining the Home media filter that launched it.
    case homeMore(section: HomeMoreSection, filter: MediaFilter)
    /// The storage screen (per-item/account purgeable totals, `StorageModel`), pushed under the
    /// `.settings` section.
    case storage
    /// The resolution center (`ResolutionCenterModel`), pushed under `.settings`.
    case resolutionCenter
    /// An author's navigable item list: a search hit's destination, not a browse-tab concept, so
    /// it lives here rather than as a `Section`. `seed` is presentation data from an
    /// already-rendered Library row, absent from route identity and deep links: restored routes
    /// resolve by id, while a direct Library tap paints its first frame without rediscovering
    /// the name.
    case author(
      id: String, libraryID: String? = nil, seed: AuthorSeriesDestinationSeed? = nil)
    /// An item-detail author credit carries a name but no server entity id. This route resolves
    /// that exact normalized name inside its destination without detouring through Search.
    case authorName(name: String)
    /// A series's navigable item list, the sibling of `.author`.
    case series(
      id: String, libraryID: String? = nil, seed: AuthorSeriesDestinationSeed? = nil)
    case seriesName(name: String)
    /// Audiobookshelf exposes narrator strings rather than narrator entities, so this collection
    /// is name-keyed.
    case narrator(name: String)
    /// The Settings > Podcasts destination: the account's global device-side auto-download
    /// defaults and the ordered show-override list. Belongs to the `.settings` stack.
    case podcastSettings
    /// One show's tri-state auto-download/keep-latest/delete-after-played overrides, plus its
    /// read-only server diagnostic. Reached from the Podcast Settings show list and the show's
    /// overflow menu, both on the `.settings` stack, so a deep link installs
    /// `[.podcastSettings, .podcastShowSettings(itemID:)]`.
    case podcastShowSettings(itemID: String, titleSeed: String? = nil)
    /// One collection or playlist. Keyed by server identity,
    /// not a local row id, because every refresh replaces the stored rows.
    case libraryCollection(kind: LibraryCollectionListKind, serverID: String, libraryID: String)
    /// The "Edit Smart Lists" screen pushed from the Podcasts tab's Smart Lists section: reorder
    /// and delete.
    case smartLists
    /// One smart list's screen, keyed by its local row id. Lists are device-owned, so the id is
    /// meaningful only on this device; a deep link to a deleted list lands on its "missing" state.
    case smartList(id: Int64)

    /// Canonical cross-tab podcast section routes. Home and Podcasts use these same values so a
    /// label cannot lead to two subtly different detail screens as their local filters evolve.
    public static var latestEpisodes: Self {
      .homeMore(section: .newEpisodes, filter: .podcasts)
    }

    public static var podcastContinueListening: Self {
      .homeMore(section: .continueListening, filter: .podcasts)
    }

    static let itemDetailPrefix = "item"
    static let podcastShowPrefix = "podcast"
    static let filteredPodcastShowPrefix = "podcast-filtered"
    static let podcastShowsToken = "podcast-shows"
    static let nativePodcastShowsToken = "your-shows"
    static let homeMorePrefix = "home-more"
    static let storageToken = "storage"
    static let resolutionCenterToken = "resolution"
    static let authorPrefix = "author"
    static let seriesPrefix = "series"
    static let authorNamePrefix = "author-name"
    static let seriesNamePrefix = "series-name"
    static let narratorPrefix = "narrator"
    static let libraryAuthorPrefix = "library-author"
    static let librarySeriesPrefix = "library-series"
    static let podcastSettingsToken = "podcast-settings"
    static let podcastShowSettingsPrefix = "podcast-show-settings"
    static let libraryCollectionPrefix = "library-list"
    static let smartListsToken = "smart-lists"
    static let smartListPrefix = "smart-list"

    var deepLinkComponents: [String] {
      switch self {
      case .itemDetail(let itemID, _):
        let escaped = itemID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? itemID
        return [Self.itemDetailPrefix, escaped]
      case .podcastShow(let itemID, let filter, _):
        let escaped = itemID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? itemID
        return filter == .all
          ? [Self.podcastShowPrefix, escaped]
          : [Self.filteredPodcastShowPrefix, escaped, filter.rawValue]
      case .podcastShows:
        return [Self.podcastShowsToken]
      case .nativePodcastShows:
        return [Self.nativePodcastShowsToken]
      case .homeMore(let section, let filter):
        return [Self.homeMorePrefix, section.rawValue, filter.rawValue]
      case .storage:
        return [Self.storageToken]
      case .resolutionCenter:
        return [Self.resolutionCenterToken]
      case .author(let id, let libraryID, _):
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        guard let libraryID else { return [Self.authorPrefix, escaped] }
        let escapedLibrary =
          libraryID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? libraryID
        return [Self.libraryAuthorPrefix, escapedLibrary, escaped]
      case .series(let id, let libraryID, _):
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        guard let libraryID else { return [Self.seriesPrefix, escaped] }
        let escapedLibrary =
          libraryID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? libraryID
        return [Self.librarySeriesPrefix, escapedLibrary, escaped]
      case .authorName(let name):
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return [Self.authorNamePrefix, escaped]
      case .seriesName(let name):
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return [Self.seriesNamePrefix, escaped]
      case .narrator(let name):
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return [Self.narratorPrefix, escaped]
      case .podcastSettings:
        return [Self.podcastSettingsToken]
      case .podcastShowSettings(let itemID, _):
        let escaped = itemID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? itemID
        return [Self.podcastShowSettingsPrefix, escaped]
      case .libraryCollection(let kind, let serverID, let libraryID):
        return [Self.libraryCollectionPrefix, kind.rawValue, escape(libraryID), escape(serverID)]
      case .smartLists:
        return [Self.smartListsToken]
      case .smartList(let id):
        return [Self.smartListPrefix, String(id)]
      }
    }

    private func escape(_ component: String) -> String {
      component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? component
    }

    private enum Identity: Hashable {
      case itemDetail(String)
      case podcastShow(String, PodcastEpisodeFilter)
      case podcastShows
      case nativePodcastShows
      case homeMore(HomeMoreSection, MediaFilter)
      case storage
      case resolutionCenter
      case author(String, String?)
      case series(String, String?)
      case authorName(String)
      case seriesName(String)
      case narrator(String)
      case podcastSettings
      case podcastShowSettings(String)
      case libraryCollection(LibraryCollectionListKind, String, String)
      case smartLists
      case smartList(Int64)
    }

    private var identity: Identity {
      switch self {
      case .itemDetail(let itemID, _):
        .itemDetail(itemID)
      case .podcastShow(let itemID, let filter, _):
        .podcastShow(itemID, filter)
      case .podcastShows:
        .podcastShows
      case .nativePodcastShows:
        .nativePodcastShows
      case .homeMore(let section, let filter):
        .homeMore(section, filter)
      case .storage:
        .storage
      case .resolutionCenter:
        .resolutionCenter
      case .author(let id, let libraryID, _):
        .author(id, libraryID)
      case .series(let id, let libraryID, _):
        .series(id, libraryID)
      case .authorName(let name):
        .authorName(name)
      case .seriesName(let name):
        .seriesName(name)
      case .narrator(let name):
        .narrator(name)
      case .podcastSettings:
        .podcastSettings
      case .podcastShowSettings(let itemID, _):
        .podcastShowSettings(itemID)
      case .libraryCollection(let kind, let serverID, let libraryID):
        .libraryCollection(kind, serverID, libraryID)
      case .smartLists:
        .smartLists
      case .smartList(let id):
        .smartList(id)
      }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
      identity.hash(into: &hasher)
    }
  }
}
