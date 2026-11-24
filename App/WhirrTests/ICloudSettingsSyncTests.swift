import AppModel
import Foundation
import Testing

@testable import Whirr

@Suite("iCloud settings sync")
struct ICloudSettingsSyncTests {
  @Test("only app-wide non-sensitive preferences are eligible for iCloud")
  func syncPolicyIsAnExplicitAllowlist() {
    #expect(
      Set(ICloudSettingsSync.syncedKeys)
        == [
          "app.appearance",
          "com.remoteconcern.whirr.adSkipEnabled",
          "com.remoteconcern.whirr.deleteDownloadsWhenFinished",
          "com.remoteconcern.whirr.downloadsAllowCellular",
          "com.remoteconcern.whirr.libraryCacheAutomaticArtworkTopUpEnabled",
          "com.remoteconcern.whirr.libraryCacheHasUserSetAutomaticTopUp",
          "com.remoteconcern.whirr.playbackRate",
          "com.remoteconcern.whirr.queueAutoDownloadPolicy",
          "com.remoteconcern.whirr.savedShelfAutoDownloadPolicy",
          "com.remoteconcern.whirr.storageCeilingBytes",
          "home.hiddenSections",
          "home.sectionOrder",
          "podcasts.hiddenSections",
          "podcasts.sectionOrder",
          "player.playbackRate.presets",
          "player.skipInterval.backward.seconds",
          "player.skipInterval.forward.seconds",
          "player.sleepTimer.presets",
          "player.sleepTimer.resumeGraceSeconds",
          "player.smartRewind.enabled",
          "player.trimSilences.enabled",
          "player.trimSilences.strength",
          "player.voiceBoost.enabled",
        ])
  }

  @Test("device-local podcast cloud consent and the introduction marker never reach iCloud")
  func podcastConsentKeysStayDeviceLocal() {
    let synced = Set(ICloudSettingsSync.syncedKeys)
    #expect(synced.contains(PodcastCloudSyncConsentStore.consentKey) == false)
    // Time saved is per device; iCloud sums it through its own per-device entries.
    for source in TimeSavedSource.allCases {
      #expect(synced.contains(UserDefaultsTimeSaved.localKey(source)) == false)
    }
    #expect(synced.contains(UserDefaultsTimeSaved.cloudDeviceKey) == false)
    #expect(synced.contains(PodcastCloudSyncConsentStore.installTokenKey) == false)
    #expect(synced.contains(PodcastIntroductionPreference.storageKey) == false)
    // Notification intent and its one-time offer belong to the device that was asked.
    #expect(synced.contains(PodcastNotificationPreference.storageKey) == false)
    #expect(synced.contains(PodcastNotificationOfferPreference.storageKey) == false)
  }

  @Test("launch adopts existing iCloud values and seeds preferences missing from iCloud")
  func launchReconcilesWithoutOverwritingCloud() {
    let local = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.light.rawValue,
      UserDefaultsPlaybackPreferences.smartRewindKey: false,
    ])
    let cloud = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.dark.rawValue
    ])
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.reconcileAtLaunch()

    #expect(cloud.synchronizeCallCount == 1)
    #expect(local.object(forKey: AppAppearance.storageKey) as? String == AppAppearance.dark.rawValue)
    #expect(
      cloud.object(forKey: UserDefaultsPlaybackPreferences.smartRewindKey) as? Bool == false)
  }

  @Test("local changes copy values to iCloud without copying unknown keys")
  func localChangesStayInsideTheAllowlist() {
    let local = MemorySettingsStore([
      SkipIntervalConfiguration.forwardStorageKey: 45,
      "account.serverURL": "https://private.example",
    ])
    let cloud = MemorySettingsStore()
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.pushLocalPreferences()

    #expect(cloud.object(forKey: SkipIntervalConfiguration.forwardStorageKey) as? Int == 45)
    #expect(cloud.object(forKey: "account.serverURL") == nil)
  }

  @Test("a preference never set on this device does not delete the iCloud value")
  func absentLocalPreferencesNeverDeleteCloudValues() {
    let local = MemorySettingsStore([
      SkipIntervalConfiguration.forwardStorageKey: 45
    ])
    let cloud = MemorySettingsStore([
      UserDefaultsPlaybackPreferences.smartRewindKey: true,
      AppAppearance.storageKey: AppAppearance.dark.rawValue,
    ])
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.pushLocalPreferences()

    #expect(cloud.object(forKey: UserDefaultsPlaybackPreferences.smartRewindKey) as? Bool == true)
    #expect(cloud.object(forKey: AppAppearance.storageKey) as? String == AppAppearance.dark.rawValue)
  }

  @Test("unchanged preferences are not rewritten to iCloud")
  func unchangedPreferencesAreNotRewritten() {
    let local = MemorySettingsStore([
      SkipIntervalConfiguration.forwardStorageKey: 45,
      UserDefaultsPlaybackPreferences.smartRewindKey: true,
    ])
    let cloud = MemorySettingsStore([
      SkipIntervalConfiguration.forwardStorageKey: 45,
      UserDefaultsPlaybackPreferences.smartRewindKey: false,
    ])
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.pushLocalPreferences()

    #expect(cloud.writtenKeys == [UserDefaultsPlaybackPreferences.smartRewindKey])
  }

  @Test("the initial iCloud download reconciles the whole allowlist")
  func initialSyncAdoptsDownloadedPreferences() {
    let local = MemorySettingsStore()
    let cloud = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.dark.rawValue,
      SkipIntervalConfiguration.forwardStorageKey: 45,
    ])
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreInitialSyncChange, keys: nil)

    #expect(local.object(forKey: AppAppearance.storageKey) as? String == AppAppearance.dark.rawValue)
    #expect(local.object(forKey: SkipIntervalConfiguration.forwardStorageKey) as? Int == 45)
  }

  @Test("a server change with no key list reconciles instead of clearing local preferences")
  func serverChangeWithoutKeysDoesNotClearLocalPreferences() {
    let local = MemorySettingsStore([
      SkipIntervalConfiguration.forwardStorageKey: 45
    ])
    let cloud = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.dark.rawValue
    ])
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.handleExternalChange(reason: NSUbiquitousKeyValueStoreServerChange, keys: nil)

    #expect(local.object(forKey: SkipIntervalConfiguration.forwardStorageKey) as? Int == 45)
    #expect(local.object(forKey: AppAppearance.storageKey) as? String == AppAppearance.dark.rawValue)
  }

  @Test("a quota violation leaves both stores untouched")
  func quotaViolationIsIgnored() {
    let local = MemorySettingsStore()
    let cloud = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.dark.rawValue
    ])
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.handleExternalChange(
      reason: NSUbiquitousKeyValueStoreQuotaViolationChange, keys: [AppAppearance.storageKey])

    #expect(local.object(forKey: AppAppearance.storageKey) == nil)
  }

  @Test("external iCloud changes update only allowlisted local preferences")
  func externalChangesStayInsideTheAllowlist() {
    let local = MemorySettingsStore([
      "account.serverURL": "https://local.example"
    ])
    let cloud = MemorySettingsStore([
      UserDefaultsDownloadPreferences.allowCellularKey: true,
      "account.serverURL": "https://cloud.example",
    ])
    let sync = ICloudSettingsSync(local: local, cloud: cloud)

    sync.applyCloudChanges(keys: [
      UserDefaultsDownloadPreferences.allowCellularKey,
      "account.serverURL",
    ])

    #expect(local.object(forKey: UserDefaultsDownloadPreferences.allowCellularKey) as? Bool == true)
    #expect(local.object(forKey: "account.serverURL") as? String == "https://local.example")
  }

  /// A defaults write that touches no synced key must cost nothing. Every write posts
  /// `UserDefaults.didChangeNotification`, which names no keys, so walking the allowlist on each
  /// one cost ~32 store lookups on the main queue per unrelated write.
  @Test("a defaults change that touches no synced key reads and writes nothing in iCloud")
  func unrelatedLocalChangeDoesNoCloudWork() {
    let local = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.dark.rawValue
    ])
    let cloud = MemorySettingsStore()
    let sync = ICloudSettingsSync(local: local, cloud: cloud)
    sync.reconcileAtLaunch()
    cloud.resetAccessLog()
    local.resetAccessLog()

    local.set(Date(), forKey: "watch.context.timestamp")
    local.resetAccessLog()
    for _ in 0..<10 {
      sync.pushLocalPreferences()
    }

    #expect(cloud.readKeys.isEmpty)
    #expect(cloud.writtenKeys.isEmpty)
    // One local read per synced key per pass, and nothing beyond it.
    #expect(local.readKeys.count == ICloudSettingsSync.syncedKeys.count * 10)
    #expect(local.writtenKeys.isEmpty)
  }

  @Test("a synced key that does change is still mirrored, and only that key")
  func changedSyncedKeyStillReachesCloud() {
    let local = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.dark.rawValue,
      UserDefaultsPlaybackPreferences.smartRewindKey: true,
    ])
    let cloud = MemorySettingsStore()
    let sync = ICloudSettingsSync(local: local, cloud: cloud)
    sync.reconcileAtLaunch()
    cloud.resetAccessLog()

    local.set(AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)
    sync.pushLocalPreferences()

    #expect(cloud.writtenKeys == [AppAppearance.storageKey])
    #expect(cloud.object(forKey: AppAppearance.storageKey) as? String == AppAppearance.light.rawValue)
    #expect(cloud.readKeys.contains(UserDefaultsPlaybackPreferences.smartRewindKey) == false)

    // The same value again is not a change.
    cloud.resetAccessLog()
    sync.pushLocalPreferences()
    #expect(cloud.readKeys.isEmpty)
    #expect(cloud.writtenKeys.isEmpty)
  }

  @Test("a synced key removed locally is not re-pushed and does not erase iCloud")
  func locallyRemovedSyncedKeyIsNotPushed() {
    let local = MemorySettingsStore([
      AppAppearance.storageKey: AppAppearance.dark.rawValue
    ])
    let cloud = MemorySettingsStore()
    let sync = ICloudSettingsSync(local: local, cloud: cloud)
    sync.reconcileAtLaunch()
    cloud.resetAccessLog()

    local.removeObject(forKey: AppAppearance.storageKey)
    sync.pushLocalPreferences()

    #expect(cloud.writtenKeys.isEmpty)
    #expect(cloud.object(forKey: AppAppearance.storageKey) as? String == AppAppearance.dark.rawValue)
  }
}

private final class MemorySettingsStore: SettingsKeyValueStoring {
  private var values: [String: Any]
  private(set) var synchronizeCallCount = 0
  /// Every key this store was asked to write, so a test can assert that redundant writes, which
  /// count against the iCloud key-value store's rate limit, never leave the app.
  private(set) var writtenKeys: [String] = []
  /// Every key this store was asked to read. `UserDefaults.didChangeNotification` names no keys
  /// and fires for every write in the process, so each read the mirror makes lands on the main
  /// queue whether or not a synced preference changed.
  private(set) var readKeys: [String] = []

  func resetAccessLog() {
    writtenKeys.removeAll()
    readKeys.removeAll()
  }

  init(_ values: [String: Any] = [:]) {
    self.values = values
  }

  func object(forKey defaultName: String) -> Any? {
    readKeys.append(defaultName)
    return values[defaultName]
  }

  func set(_ value: Any?, forKey defaultName: String) {
    writtenKeys.append(defaultName)
    values[defaultName] = value
  }

  func removeObject(forKey defaultName: String) {
    writtenKeys.append(defaultName)
    values.removeValue(forKey: defaultName)
  }

  @discardableResult
  func synchronize() -> Bool {
    synchronizeCallCount += 1
    return true
  }
}
