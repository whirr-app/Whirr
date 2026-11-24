import CoreSupport
import Foundation
import SyncEngine

/// Production `DownloadPreferences`: persists the cellular-download and delete-when-finished
/// opt-ins (both default `false`) and the Up Next auto-download policy (default `.never`) to
/// `UserDefaults`, like `UserDefaultsPlaybackPreferences`. Each change stream is an
/// `AsyncEventMulticaster` subscription yielding only values set after subscribing.
final class UserDefaultsDownloadPreferences: DownloadPreferences, @unchecked Sendable {
  static let allowCellularKey = "com.remoteconcern.whirr.downloadsAllowCellular"
  static let deleteWhenFinishedKey = "com.remoteconcern.whirr.deleteDownloadsWhenFinished"
  static let queueAutoDownloadPolicyKey = "com.remoteconcern.whirr.queueAutoDownloadPolicy"
  static let savedShelfAutoDownloadPolicyKey =
    "com.remoteconcern.whirr.savedShelfAutoDownloadPolicy"
  static let storageCeilingBytesKey = "com.remoteconcern.whirr.storageCeilingBytes"

  private let defaults: UserDefaults
  private let allowCellularMulticaster = AsyncEventMulticaster<Bool>()
  private let deleteWhenFinishedMulticaster = AsyncEventMulticaster<Bool>()
  private let queueAutoDownloadPolicyMulticaster = AsyncEventMulticaster<QueueAutoDownloadPolicy>()
  private let savedShelfAutoDownloadPolicyMulticaster = AsyncEventMulticaster<SavedShelfAutoDownloadPolicy>()
  private let storageCeilingBytesMulticaster = AsyncEventMulticaster<Int64?>()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var allowCellular: Bool {
    defaults.bool(forKey: Self.allowCellularKey)
  }

  var deleteWhenFinished: Bool {
    defaults.bool(forKey: Self.deleteWhenFinishedKey)
  }

  var queueAutoDownloadPolicy: QueueAutoDownloadPolicy {
    QueueAutoDownloadPolicy(rawValue: defaults.string(forKey: Self.queueAutoDownloadPolicyKey) ?? "")
      ?? .never
  }

  var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy {
    SavedShelfAutoDownloadPolicy(
      rawValue: defaults.string(forKey: Self.savedShelfAutoDownloadPolicyKey) ?? "") ?? .never
  }

  var storageCeilingBytes: Int64? {
    (defaults.object(forKey: Self.storageCeilingBytesKey) as? NSNumber)?.int64Value
  }

  func setAllowCellular(_ allowed: Bool) async {
    defaults.set(allowed, forKey: Self.allowCellularKey)
    allowCellularMulticaster.yield(allowed)
  }

  var changes: AsyncStream<Bool> {
    allowCellularMulticaster.subscribe()
  }

  func setDeleteWhenFinished(_ enabled: Bool) async {
    defaults.set(enabled, forKey: Self.deleteWhenFinishedKey)
    deleteWhenFinishedMulticaster.yield(enabled)
  }

  var deleteWhenFinishedChanges: AsyncStream<Bool> {
    deleteWhenFinishedMulticaster.subscribe()
  }

  func setQueueAutoDownloadPolicy(_ policy: QueueAutoDownloadPolicy) async {
    defaults.set(policy.rawValue, forKey: Self.queueAutoDownloadPolicyKey)
    queueAutoDownloadPolicyMulticaster.yield(policy)
  }

  var queueAutoDownloadPolicyChanges: AsyncStream<QueueAutoDownloadPolicy> {
    queueAutoDownloadPolicyMulticaster.subscribe()
  }

  func setSavedShelfAutoDownloadPolicy(_ policy: SavedShelfAutoDownloadPolicy) async {
    defaults.set(policy.rawValue, forKey: Self.savedShelfAutoDownloadPolicyKey)
    savedShelfAutoDownloadPolicyMulticaster.yield(policy)
  }

  var savedShelfAutoDownloadPolicyChanges: AsyncStream<SavedShelfAutoDownloadPolicy> {
    savedShelfAutoDownloadPolicyMulticaster.subscribe()
  }

  func setStorageCeilingBytes(_ ceiling: Int64?) async {
    if let ceiling {
      defaults.set(ceiling, forKey: Self.storageCeilingBytesKey)
    } else {
      defaults.removeObject(forKey: Self.storageCeilingBytesKey)
    }
    storageCeilingBytesMulticaster.yield(ceiling)
  }

  var storageCeilingBytesChanges: AsyncStream<Int64?> {
    storageCeilingBytesMulticaster.subscribe()
  }
}

/// Persists the last automatic storage-ceiling result separately from the preference itself. The
/// result is account-scoped so an account switch cannot disclose the previous account's deletion
/// history on the Downloads screen.
final class UserDefaultsStorageCeilingSummaryStore: StorageCeilingSummaryStoring, @unchecked Sendable {
  private static let keyPrefix = "com.remoteconcern.whirr.storageCeilingLastEviction"

  private let defaults: UserDefaults
  private let key: String
  private let summaryMulticaster = AsyncEventMulticaster<StorageCeilingEvictionSummary?>()

  init(defaults: UserDefaults = .standard, accountId: Int64?) {
    self.defaults = defaults
    key = "\(Self.keyPrefix).\(accountId.map(String.init) ?? "unscoped")"
  }

  var lastStorageCeilingSummary: StorageCeilingEvictionSummary? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(StorageCeilingEvictionSummary.self, from: data)
  }

  var storageCeilingSummaryChanges: AsyncStream<StorageCeilingEvictionSummary?> {
    summaryMulticaster.subscribe()
  }

  func storeStorageCeilingSummary(_ summary: StorageCeilingEvictionSummary) async {
    guard let data = try? JSONEncoder().encode(summary) else { return }
    defaults.set(data, forKey: key)
    summaryMulticaster.yield(summary)
  }
}
