import Foundation

/// The Watch's last download report for one Watch install, persisted so the On Apple Watch rows keep
/// their percentage across this phone's own relaunch. The Watch cannot be woken to resend, so a
/// projection held only in memory would fall back to "Waiting for your Watch" until its next
/// inventory.
///
/// It stores local episode row ids, revisions, states and progress only. The record is scoped to the
/// install that reported it: a report from a previous Watch describes copies this phone no longer
/// holds, and the next inventory from the current install replaces it whole.
struct WatchDownloadStatusRecord {
  struct Entry: Codable, Equatable {
    let watchInstallID: String
    let statuses: [Int64: WatchEpisodeDownloadStatus]
  }

  private static let key = "watch.download.status.record.v1"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The last projection this Watch install reported, or nil when no record is stored or the one
  /// stored belongs to another install. An inventory that named no in-progress copy is a real
  /// answer and loads as an empty dictionary.
  func load(watchInstallID: String) -> [Int64: WatchEpisodeDownloadStatus]? {
    guard let entry = stored, entry.watchInstallID == watchInstallID else { return nil }
    return entry.statuses
  }

  /// Replaces the record with one inventory's whole projection. Every newer inventory calls this,
  /// including one naming no in-progress copy: an empty projection is what forgets the previous
  /// percentages.
  func save(watchInstallID: String, statuses: [Int64: WatchEpisodeDownloadStatus]) {
    let entry = Entry(watchInstallID: watchInstallID, statuses: statuses)
    guard let data = try? JSONEncoder().encode(entry) else { return }
    defaults.set(data, forKey: Self.key)
  }

  /// Drops the record. The account boundary resets the copies it describes, so a later request must
  /// not inherit a saved status.
  func clear() {
    defaults.removeObject(forKey: Self.key)
  }

  private var stored: Entry? {
    guard let data = defaults.data(forKey: Self.key) else { return nil }
    return try? JSONDecoder().decode(Entry.self, from: data)
  }
}
