import AppModel
import Foundation

/// The smallest common surface shared by local defaults, iCloud's key-value store, and tests.
/// Values are limited to property-list types by both production implementations.
protocol SettingsKeyValueStoring: AnyObject {
  func object(forKey defaultName: String) -> Any?
  func set(_ value: Any?, forKey defaultName: String)
  func removeObject(forKey defaultName: String)
  @discardableResult func synchronize() -> Bool
}

extension UserDefaults: SettingsKeyValueStoring {}
extension NSUbiquitousKeyValueStore: SettingsKeyValueStoring {}

/// Mirrors app-wide, non-sensitive preferences between `UserDefaults` and iCloud key-value storage.
/// An allowlist: identity, server addresses, credentials, database and reader state, diagnostics
/// and downloaded media never enter it by accident. `UserDefaults` stays the runtime source of
/// truth; at launch an existing iCloud value wins and a local value seeds a key iCloud has never
/// seen. Later local changes mirror out and iCloud notifications apply back.
final class ICloudSettingsSync {
  static let shared = ICloudSettingsSync(
    local: UserDefaults.standard,
    cloud: NSUbiquitousKeyValueStore.default)

  static let playbackRatePresetsKey = "player.playbackRate.presets"
  static let sleepTimerPresetsKey = "player.sleepTimer.presets"

  static let syncedKeys = [
    AdSkipPreference.key,
    AppAppearance.storageKey,
    UserDefaultsDownloadPreferences.allowCellularKey,
    UserDefaultsDownloadPreferences.deleteWhenFinishedKey,
    UserDefaultsDownloadPreferences.queueAutoDownloadPolicyKey,
    UserDefaultsDownloadPreferences.savedShelfAutoDownloadPolicyKey,
    UserDefaultsDownloadPreferences.storageCeilingBytesKey,
    // Retired: automatic artwork top-up is always on and has no setting. Both keys stay in the
    // sync list so old synced values are harmless and no migration is needed.
    "com.remoteconcern.whirr.libraryCacheAutomaticArtworkTopUpEnabled",
    "com.remoteconcern.whirr.libraryCacheHasUserSetAutomaticTopUp",
    UserDefaultsPlaybackPreferences.rateKey,
    UserDefaultsPlaybackPreferences.smartRewindKey,
    UserDefaultsPlaybackPreferences.sleepTimerResumeGraceKey,
    UserDefaultsPlaybackPreferences.voiceBoostKey,
    UserDefaultsTrimSilencesPreferences.enabledKey,
    UserDefaultsTrimSilencesPreferences.strengthKey,
    HomeSectionVisibility.storageKey,
    HomeSectionOrder.storageKey,
    PodcastsRootSectionVisibility.storageKey,
    PodcastsRootSectionOrder.storageKey,
    playbackRatePresetsKey,
    SkipIntervalConfiguration.backwardStorageKey,
    SkipIntervalConfiguration.forwardStorageKey,
    sleepTimerPresetsKey,
  ]

  private static let syncedKeySet = Set(syncedKeys)

  private let local: any SettingsKeyValueStoring
  private let cloud: any SettingsKeyValueStoring
  private let notificationCenter: NotificationCenter
  private var localObserver: (any NSObjectProtocol)?
  private var cloudObserver: (any NSObjectProtocol)?
  /// The local value this class last saw for each synced key. See `changedSyncedKeys`.
  private var mirroredLocalValues: [String: Any] = [:]

  init(
    local: any SettingsKeyValueStoring,
    cloud: any SettingsKeyValueStoring,
    notificationCenter: NotificationCenter = .default
  ) {
    self.local = local
    self.cloud = cloud
    self.notificationCenter = notificationCenter
  }

  func start() {
    guard localObserver == nil, cloudObserver == nil else { return }

    // Apple requires the external-change observer to be installed before the initial synchronize
    // request, otherwise an initial iCloud download can arrive between those two operations.
    cloudObserver = notificationCenter.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: cloud,
      queue: .main
    ) { [weak self] notification in
      let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
      let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
      MainActor.assumeIsolated {
        self?.handleExternalChange(reason: reason, keys: keys)
      }
    }

    localObserver = notificationCenter.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: local,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.pushLocalPreferences()
      }
    }

    reconcileAtLaunch()
  }

  func stop() {
    if let localObserver {
      notificationCenter.removeObserver(localObserver)
      self.localObserver = nil
    }
    if let cloudObserver {
      notificationCenter.removeObserver(cloudObserver)
      self.cloudObserver = nil
    }
  }

  /// Requests a refresh when the app returns to the foreground. The system decides when remote
  /// values arrive and reports them through the external-change notification installed in
  /// `start()`; `synchronize()` does not force an immediate network round trip.
  func refreshFromICloud() {
    _ = cloud.synchronize()
  }

  /// Routes an external iCloud change. Only a change that names the keys it carries may apply a
  /// removal to local defaults; an account change, the first download onto a fresh install, and any
  /// notification that arrives without a key list all reconcile the whole allowlist instead, so a
  /// store the app has not seen the contents of can never be read as a set of deletions.
  func handleExternalChange(reason: Int?, keys: [String]?) {
    guard reason != NSUbiquitousKeyValueStoreQuotaViolationChange else { return }
    switch (reason, keys) {
    case (NSUbiquitousKeyValueStoreAccountChange, _),
      (NSUbiquitousKeyValueStoreInitialSyncChange, _),
      (_, nil):
      reconcileAtLaunch()
    case (_, let keys?):
      applyCloudChanges(keys: keys)
    }
  }

  func reconcileAtLaunch() {
    _ = cloud.synchronize()
    for key in Self.syncedKeys {
      if let cloudValue = cloud.object(forKey: key) {
        setLocal(cloudValue, forKey: key)
      } else if let localValue = local.object(forKey: key) {
        setCloud(localValue, forKey: key)
      }
    }
    // Both stores now agree, so the next `UserDefaults.didChangeNotification` starts from a
    // snapshot that describes local storage rather than treating every key as new.
    for key in Self.syncedKeys {
      mirroredLocalValues[key] = local.object(forKey: key)
    }
  }

  func pushLocalPreferences() {
    let changed = changedSyncedKeys()
    guard changed.isEmpty == false else { return }
    for key in changed {
      // Absent locally means "never written on this device", not "reset everywhere".
      // `UserDefaults.didChangeNotification` names no keys, so the two cannot be told apart.
      // Deleting on absence would let a fresh install erase iCloud before its first download.
      guard let localValue = local.object(forKey: key) else { continue }
      setCloud(localValue, forKey: key)
    }
  }

  /// Which synced keys changed locally since this class last looked, updating the snapshot.
  ///
  /// The notification fires for every write in the process, nearly all outside the allowlist, so
  /// the snapshot comparison keeps the common case to one local read per key and no
  /// `NSUbiquitousKeyValueStore` access. A key unchanged locally is skipped even if iCloud
  /// diverged (`reconcileAtLaunch`'s and the external-change notification's job).
  private func changedSyncedKeys() -> [String] {
    var changed: [String] = []
    for key in Self.syncedKeys {
      let value = local.object(forKey: key)
      guard Self.isEqual(mirroredLocalValues[key], value) == false else { continue }
      mirroredLocalValues[key] = value
      changed.append(key)
    }
    return changed
  }

  func applyCloudChanges(keys: [String]) {
    for key in keys where Self.syncedKeySet.contains(key) {
      if let cloudValue = cloud.object(forKey: key) {
        setLocal(cloudValue, forKey: key)
      } else if local.object(forKey: key) != nil {
        local.removeObject(forKey: key)
      }
    }
  }

  /// Writes only when the value differs. Every local defaults write notifies this class, so an
  /// unguarded mirror would re-send the whole allowlist to a store that rate-limits writes, and
  /// the local side would notify itself back into another pass.
  private func setCloud(_ value: Any, forKey key: String) {
    guard !Self.isEqual(cloud.object(forKey: key), value) else { return }
    cloud.set(value, forKey: key)
  }

  private func setLocal(_ value: Any, forKey key: String) {
    guard !Self.isEqual(local.object(forKey: key), value) else { return }
    local.set(value, forKey: key)
  }

  private static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return (lhs as AnyObject).isEqual(rhs as AnyObject)
  }
}
