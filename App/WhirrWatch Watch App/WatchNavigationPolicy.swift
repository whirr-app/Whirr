import Foundation
import WatchPlayback
import WatchProtocol

enum WatchMediaType: String {
  case book, podcast
}

/// How a detail page's title stands against what the Watch has loaded.
enum WatchLoadedItemState: Equatable {
  case notLoaded, active, paused
}

/// Server-library scope is secondary to the media destination. Switching between Audiobooks
/// and Podcasts must not keep an incompatible library selected from the other destination.
enum WatchNavigationPolicy {
  static func itemDestination(
    selection: WatchSelection, capabilities: WatchSelectionCapabilities,
    preferred: WatchPlaybackDestination, phoneAvailable: Bool, watchAvailable: Bool,
    hasLocalCopy: Bool
  ) -> WatchPlaybackDestination? {
    let phone = WatchDestinationPreference.supports(.phone, selection: selection, capabilities: capabilities)
    let watch = WatchDestinationPreference.supports(
      .watch, selection: selection, capabilities: capabilities, hasLocalCopy: hasLocalCopy)
    if preferred == .phone && phone && phoneAvailable { return .phone }
    if preferred == .watch && watch && watchAvailable { return .watch }
    if phone && phoneAvailable { return .phone }
    if watch && watchAvailable { return .watch }
    if phone { return .phone }
    if watch { return .watch }
    return nil
  }

  /// `play(_:)` supersedes whatever is loaded, so the loaded title must open the player or resume
  /// instead of offering a play that restarts its stream.
  static func loadedState(
    of selection: WatchSelection, current: WatchSelection?, wantsPlayback: Bool
  ) -> WatchLoadedItemState {
    guard current == selection else { return .notLoaded }
    return wantsPlayback ? .active : .paused
  }

  /// A signed-in Watch always has a download action for a Watch-playable title: download, retry or
  /// remove. Otherwise only the device the primary button does not name is left to offer.
  static func itemOffersMoreActions(
    watchSupported: Bool, watchAccountMatches: Bool, primary: WatchPlaybackDestination?, phonePlayable: Bool
  ) -> Bool {
    (watchSupported && (watchAccountMatches || primary != .watch)) || (phonePlayable && primary == .watch)
  }

  static func shouldPresentPhonePlayer(
    selection: WatchSelection, accountStamp: WatchAccountStamp,
    snapshot: WatchCatalogueSnapshot?, newerThan previous: Date
  ) -> Bool {
    guard let snapshot, snapshot.accountStamp == accountStamp,
      snapshot.generatedAt > previous, snapshot.playbackState == .playing
    else { return false }
    return snapshot.items.first(where: \.isCurrentPlayback)?.selection == selection
  }

  /// Followed shows play only on the iPhone, so the entry needs a reachable, signed-in phone that
  /// says its followed podcasts are on. An older phone says nothing and gets no entry.
  static func offersFollowedOnIPhone(
    phoneReachable: Bool, phoneSignedIn: Bool, followedPodcastsEnabled: Bool?
  ) -> Bool {
    phoneReachable && phoneSignedIn && followedPodcastsEnabled == true
  }

  /// Followed lists store their filter apart from the Audiobookshelf lists, which keep the key they
  /// had before the sources were split.
  static func podcastListPreferenceKey(base: String, source: WatchBrowseSource?) -> String {
    source == .nativeFeed ? base + ".followed" : base
  }

  static func libraries(_ libraries: [WatchLibrary], mediaType: WatchMediaType) -> [WatchLibrary] {
    libraries.filter { $0.mediaType == nil || $0.mediaType?.lowercased() == mediaType.rawValue }
  }

  static func selectedLibrary(_ libraries: [WatchLibrary], preferred: String?, mediaType: WatchMediaType) -> String? {
    let matching = Self.libraries(libraries, mediaType: mediaType)
    return matching.first { $0.id == preferred }?.id ?? matching.first?.id
  }

  static func isBook(_ selection: WatchSelection) -> Bool {
    if case .audiobookshelf(_, nil) = selection { return true }
    return false
  }
}
