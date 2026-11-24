import Foundation

/// The two device preferences the Watch episode sender reads. One key each, in one place: the
/// publisher asks this type, and Settings writes through the same key with `@AppStorage`.
nonisolated enum WatchEpisodeSendPreferences {
  /// Remove a title the phone sent once the phone records it finished. Absent means on, so an
  /// install that never opened Settings keeps the documented behaviour. The key still names
  /// episodes: renaming it would silently turn the setting back on for every listener who turned it
  /// off.
  static let removesPlayedEpisodesKey = "watch.podcasts.removePlayedEpisodes"

  static func removesPlayedEpisodes(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: removesPlayedEpisodesKey) as? Bool ?? true
  }
}
