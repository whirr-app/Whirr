import AppModel
import Foundation
import Persistence

/// One Audiobookshelf download group the Watch's latest inventory reported, in the phone's terms.
/// A phone-origin group adds live facts to its `absWatchCopy` row; a Watch-origin group is a row
/// of its own, never adopted into the desired set and shown with the titles the phone resolved for
/// it.
struct ABSWatchGroup: Codable, Equatable, Sendable {
  enum State: String, Codable, Equatable, Sendable {
    case queued
    case downloading
    case waitingForNetwork
    case ready
    case failed
    case declined
    case removed
  }

  let itemID: String
  let episodeID: String?
  /// The phone's revision for a phone-origin group; nil for one started on the Watch.
  let revision: Int64?
  let state: State
  /// The fraction across every file of the group.
  let progress: Double?
  let trackCount: Int
  let completedTracks: Int
  let committedBytes: Int64?
  let declineReason: RSSWatchDeclineReason?
  let failureReason: ABSWatchFailureReason?
  /// From the phone's library when the group was reported, or a placeholder when the phone does not
  /// hold the item. Only a Watch-origin row draws it; a phone row keeps its own.
  let title: String
  let subtitle: String?

  var key: ABSWatchCopyKey { ABSWatchCopyKey(itemId: itemID, episodeId: episodeID) }
  var isPhoneOrigin: Bool { revision != nil }
  var isBook: Bool { episodeID == nil }

  /// The same report under other titles.
  func titled(_ title: String, subtitle: String?) -> ABSWatchGroup {
    ABSWatchGroup(
      itemID: itemID, episodeID: episodeID, revision: revision, state: state, progress: progress,
      trackCount: trackCount, completedTracks: completedTracks, committedBytes: committedBytes,
      declineReason: declineReason, failureReason: failureReason, title: title, subtitle: subtitle)
  }

  /// A Watch-origin group read the way the store's rows are, for the menus and the status line.
  /// A removed group is gone from the Watch, so it has no state.
  var copyState: WatchCopyState? {
    switch state {
    case .queued, .waitingForNetwork, .downloading: .sending
    case .ready: .delivered
    case .failed:
      WatchCopyState(
        state: .failed, removedBy: nil, declineReason: nil, failureReason: failureReason)
    case .declined:
      WatchCopyState(state: .declined, removedBy: nil, declineReason: declineReason)
    case .removed: nil
    }
  }
}

/// The last Audiobookshelf half of an inventory this phone applied, persisted so the On Apple Watch
/// rows keep their Watch-origin titles and percentages across this phone's relaunch.
/// `WatchDownloadStatusRecord` cannot hold it: that record is keyed by `rssEpisode` row and replaced
/// whole by each RSS projection.
///
/// It is scoped to one Watch install and one account. The next applied inventory replaces it whole,
/// and the account boundary clears it. Like the RSS record it holds no title: `UserDefaults` is in
/// the device backup, so it keeps server item and episode IDs and download facts only, and the
/// titles are read from the library again when it is restored.
struct ABSWatchInventoryRecord {
  struct Snapshot: Codable, Equatable, Sendable {
    let watchInstallID: String
    let accountIdentityHash: String
    let groups: [ABSWatchGroup]

    var withoutTitles: Snapshot {
      Snapshot(
        watchInstallID: watchInstallID, accountIdentityHash: accountIdentityHash,
        groups: groups.map { $0.titled("", subtitle: nil) })
    }

    /// Titles each Watch-origin group from the library; a phone-origin group shows its row's own.
    func titled(by resolver: ABSWatchTitleResolver) async -> Snapshot {
      var titled: [ABSWatchGroup] = []
      for group in groups {
        guard group.isPhoneOrigin == false else {
          titled.append(group)
          continue
        }
        let facts = await resolver.titles(group.key)
        titled.append(group.titled(facts.title, subtitle: facts.subtitle))
      }
      return Snapshot(watchInstallID: watchInstallID, accountIdentityHash: accountIdentityHash, groups: titled)
    }
  }

  private static let key = "watch.abs.inventory.record.v1"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The last snapshot for this install and account, untitled, or nil when none is stored or it
  /// describes another install or account.
  func load(watchInstallID: String, accountIdentityHash: String) -> Snapshot? {
    guard let data = defaults.data(forKey: Self.key),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
      snapshot.watchInstallID == watchInstallID,
      snapshot.accountIdentityHash == accountIdentityHash
    else { return nil }
    return snapshot
  }

  func save(_ snapshot: Snapshot) {
    guard let data = try? JSONEncoder().encode(snapshot.withoutTitles) else { return }
    defaults.set(data, forKey: Self.key)
  }

  func clear() {
    defaults.removeObject(forKey: Self.key)
  }
}
