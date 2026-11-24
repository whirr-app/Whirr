import Foundation
import Persistence

/// User-facing copy for `HomeModel`, owned and tested in AppModel (as `StorageCopy` and
/// `SettingsCopy` are). The screen omits a section only when another still has content, so each
/// section has its own empty line; the full-screen `.empty` state uses `allSectionsEmptyMessage`.
public enum HomeCopy {
  /// The full-screen empty state's message, for when every section is empty at once.
  ///
  /// One sentence, not the per-section lines joined: both "Continue" sections share
  /// `continueListeningEmpty`, so an empty eBooks-filtered Home would repeat "Nothing in progress
  /// yet."
  public static let allSectionsEmptyMessage = "Items you start, add, or download will appear here."

  public static let continueListeningTitle = "Continue Listening"
  public static let continueListeningEmpty = "Nothing in progress yet."

  public static let continueReadingTitle = "Continue Reading"
  public static let continueReadingEmpty = "Nothing in progress yet."

  /// The hint for a card's primary tap; details remain available from its long-press menu.
  public static func continueCardHint(
    for category: ItemMediaCategory,
    in section: HomeMoreSection,
    opensContinueCardImmediately: Bool = true
  ) -> String? {
    if section == .continueReading {
      return opensContinueCardImmediately ? "Opens the reader." : "Opens details."
    }
    if section == .continueListening && (category == .audiobook || category == .podcast) {
      return opensContinueCardImmediately ? "Resumes playback." : "Opens details."
    }
    return nil
  }

  public static let continueSeriesTitle = "Continue Series"
  public static let continueSeriesEmpty = "Finish a book in a series to see what comes next."

  public static let recentlyAddedTitle = "Recently Added"
  public static let recentlyAddedEmpty = "Nothing added yet."

  /// One label for the same recency projection on Home, Podcasts, Settings, and its pushed list.
  public static let latestEpisodesTitle = "Latest Episodes"

  /// The destination/section is a collection of files, so its noun is consistently "Downloads".
  /// Item state copy remains the grammatically distinct "Downloaded".
  public static let downloadedTitle = "Downloads"
  public static let downloadedEmpty = "No downloads yet."
  public static func downloadedStorageAmount(bytes: Int64) -> String {
    "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on this device"
  }

  public static let savedForLaterTitle = "Saved for Later"
  /// It says the shelf clears itself, which sets it apart from a playlist.
  public static let savedForLaterEmpty =
    "Save a book or podcast episode to find it here. It leaves this shelf once you start it."
  public static let savedForLaterEmptyTitle = "Nothing Saved Yet"
  public static let savedItemUnavailable = "Saved item unavailable"

  /// Saved for Later narrows in place, so an empty result under a chip is almost never an empty
  /// shelf. These two say which kind came back empty and leave the rest of the shelf standing;
  /// `.all` resolves to the unfiltered constants above, which stay the single source for it.
  public static func savedForLaterEmptyTitle(for filter: MediaFilter) -> String {
    filter == .all ? savedForLaterEmptyTitle : "No Saved \(MediaFilterCopy.label(for: filter))"
  }

  public static func savedForLaterEmpty(for filter: MediaFilter) -> String {
    guard filter != .all else { return savedForLaterEmpty }
    return "Your saved shelf has no \(savedNoun(for: filter)) yet."
  }

  /// Podcasts are saved one episode at a time, so the saved shelf's noun for them is the episode
  /// rather than the show `MediaFilterCopy.pluralNoun` names for the Library's grid of shows.
  private static func savedNoun(for filter: MediaFilter) -> String {
    filter == .podcasts ? "podcast episodes" : MediaFilterCopy.pluralNoun(for: filter)
  }

  public static let moreRecentWindow = "Showing content from the last 7 days."
  public static let newPodcastEpisodesEmpty = "No podcast episodes were published in the last 7 days."
  public static let recentItemsEmpty = "No titles were added in the last 7 days."

  /// A section's own on-screen title, independent of any filter: what the shelf header says on
  /// Home, and therefore what the Home Screen settings toggles must be labelled with.
  public static func sectionTitle(_ section: HomeMoreSection) -> String {
    switch section {
    case .continueListening: return continueListeningTitle
    case .continueReading: return continueReadingTitle
    case .continueSeries: return continueSeriesTitle
    case .newEpisodes: return latestEpisodesTitle
    case .recentlyAdded: return recentlyAddedTitle
    case .downloaded: return downloadedTitle
    case .savedForLater: return savedForLaterTitle
    case .listeningStats: return ListeningStatsCopy.title
    case .smartLists: return smartListsTitle
    }
  }

  public static let smartListsTitle = "Smart Lists"
  public static let smartListsEmpty = "No smart lists yet."

  public static func moreTitle(section: HomeMoreSection, filter: MediaFilter) -> String {
    if section == .newEpisodes || (section == .recentlyAdded && filter == .podcasts) {
      return latestEpisodesTitle
    }
    return sectionTitle(section)
  }

  public static func detailHint(section: HomeMoreSection, filter: MediaFilter) -> String {
    "Shows all \(moreTitle(section: section, filter: filter).lowercased()) for \(MediaFilterCopy.pluralNoun(for: filter))."
  }

  public static func moreEmptyMessage(section: HomeMoreSection, filter: MediaFilter) -> String {
    switch section {
    case .continueListening: return continueListeningEmpty
    case .continueReading: return continueReadingEmpty
    case .continueSeries: return continueSeriesEmpty
    case .newEpisodes: return newPodcastEpisodesEmpty
    case .recentlyAdded:
      return filter == .podcasts ? newPodcastEpisodesEmpty : recentItemsEmpty
    case .downloaded: return downloadedEmpty
    case .savedForLater: return savedForLaterEmpty
    case .listeningStats: return ListeningStatsCopy.emptyMessage
    case .smartLists: return smartListsEmpty
    }
  }
}
