import AppModel
import Foundation
import Testing

@testable import Whirr

/// An in-memory iCloud key-value store several simulated devices can share.
final class MemoryTimeSavedCloudStore: TimeSavedCloudStoring {
  private(set) var values: [String: Any]
  private(set) var writtenKeys: [String] = []
  private(set) var synchronizeCount = 0

  init(_ values: [String: Any] = [:]) { self.values = values }

  var dictionaryRepresentation: [String: Any] { values }

  func set(_ value: Any?, forKey defaultName: String) {
    writtenKeys.append(defaultName)
    values[defaultName] = value
  }

  @discardableResult func synchronize() -> Bool {
    synchronizeCount += 1
    return true
  }
}

/// The device's time-saved totals: kept in memory, written only on flush, never through the synced
/// settings, and summed across devices in iCloud.
@MainActor
@Suite("Time saved store")
struct UserDefaultsTimeSavedTests {

  private func makeDefaults() throws -> UserDefaults {
    let name = "UserDefaultsTimeSavedTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  // MARK: - On the device

  @Test("the totals persist across a flush")
  func totalsPersistAcrossAFlush() throws {
    let defaults = try makeDefaults()
    let store = UserDefaultsTimeSaved(defaults: defaults)
    store.add(20, to: .ads)
    store.add(1.5, to: .silence)
    store.add(3, to: .speed)
    store.flush()

    let reopened = UserDefaultsTimeSaved(defaults: defaults)

    #expect(reopened.totals == TimeSavedTotals(ads: 20, silence: 1.5, speed: 3))
  }

  @Test("nothing is written between flushes")
  func nothingIsWrittenBetweenFlushes() throws {
    let defaults = try makeDefaults()
    let store = UserDefaultsTimeSaved(defaults: defaults)

    store.add(5, to: .speed)

    #expect(store.totals.speed == 5)
    #expect(defaults.object(forKey: UserDefaultsTimeSaved.localKey(.speed)) == nil)
  }

  @Test("an undo never takes a total below zero, and nonsense is ignored")
  func totalsStayNonNegative() throws {
    let store = UserDefaultsTimeSaved(defaults: try makeDefaults())
    store.add(10, to: .ads)
    store.add(-25, to: .ads)
    store.add(.nan, to: .speed)
    store.add(.infinity, to: .silence)

    #expect(store.totals == .zero)
  }

  @Test("the Trim Silences-only total is deleted, not carried over")
  func retiredTrimTotalIsDeleted() throws {
    let defaults = try makeDefaults()
    defaults.set(900.0, forKey: UserDefaultsTimeSaved.retiredTrimSavingsKey)

    let store = UserDefaultsTimeSaved(defaults: defaults)

    #expect(store.totals == .zero)
    #expect(defaults.object(forKey: UserDefaultsTimeSaved.retiredTrimSavingsKey) == nil)
  }

  @Test("the totals never ride the synced settings")
  func keysAreNotSynced() {
    let synced = Set(ICloudSettingsSync.syncedKeys)
    for source in TimeSavedSource.allCases {
      #expect(synced.contains(UserDefaultsTimeSaved.localKey(source)) == false)
    }
    #expect(synced.contains(UserDefaultsTimeSaved.cloudDeviceKey) == false)
    #expect(synced.contains { $0.hasPrefix(UserDefaultsTimeSaved.cloudKeyPrefix) } == false)
  }

  // MARK: - In iCloud

  @Test("two devices' totals sum")
  func twoDevicesSum() throws {
    let cloud = MemoryTimeSavedCloudStore()
    let phone = UserDefaultsTimeSaved(defaults: try makeDefaults(), cloud: cloud, deviceID: "phone")
    phone.add(100, to: .ads)
    phone.flush()
    let pad = UserDefaultsTimeSaved(defaults: try makeDefaults(), cloud: cloud, deviceID: "pad")
    pad.add(40, to: .speed)
    pad.flush()

    phone.refreshFromCloud()

    #expect(pad.totals == TimeSavedTotals(ads: 100, silence: 0, speed: 40))
    #expect(phone.totals == TimeSavedTotals(ads: 100, silence: 0, speed: 40))
  }

  @Test("a device writes only its own entries, and only on flush")
  func writesOnlyItsOwnEntriesOnFlush() throws {
    let cloud = MemoryTimeSavedCloudStore([
      UserDefaultsTimeSaved.cloudKey(.ads, deviceID: "pad"): 30.0
    ])
    let phone = UserDefaultsTimeSaved(defaults: try makeDefaults(), cloud: cloud, deviceID: "phone")

    phone.add(10, to: .silence)
    #expect(cloud.writtenKeys.isEmpty)

    phone.flush()
    phone.flush()

    #expect(
      Set(cloud.writtenKeys)
        == Set(TimeSavedSource.allCases.map { UserDefaultsTimeSaved.cloudKey($0, deviceID: "phone") }))
    #expect(cloud.writtenKeys.count == TimeSavedSource.allCases.count)
    #expect(cloud.values[UserDefaultsTimeSaved.cloudKey(.ads, deviceID: "pad")] as? Double == 30)
  }

  @Test("a device that is gone still counts, and unrelated keys do not")
  func staleDeviceStillCounts() throws {
    let cloud = MemoryTimeSavedCloudStore([
      UserDefaultsTimeSaved.cloudKey(.speed, deviceID: "old-phone"): 600.0,
      "timeSaved.old-phone.unknown": 5.0,
      "player.trimSilences.enabled": true,
    ])

    let phone = UserDefaultsTimeSaved(defaults: try makeDefaults(), cloud: cloud, deviceID: "phone")

    #expect(phone.totals == TimeSavedTotals(ads: 0, silence: 0, speed: 600))
  }

  @Test("a restored backup does not count its totals twice")
  func restoredBackupIsNotCountedTwice() throws {
    let cloud = MemoryTimeSavedCloudStore()
    let defaults = try makeDefaults()
    let before = UserDefaultsTimeSaved(defaults: defaults, cloud: cloud, deviceID: "old-id")
    before.add(300, to: .ads)
    before.flush()

    // The same defaults, restored onto a phone with a new vendor ID.
    let after = UserDefaultsTimeSaved(defaults: defaults, cloud: cloud, deviceID: "new-id")

    #expect(after.totals == TimeSavedTotals(ads: 300, silence: 0, speed: 0))
    #expect(after.local == .zero)
  }

  @Test("a restored backup keeps its totals when iCloud has none for the old ID")
  func restoredBackupWithoutCloudEntriesKeepsTotals() throws {
    let defaults = try makeDefaults()
    let before = UserDefaultsTimeSaved(
      defaults: defaults, cloud: MemoryTimeSavedCloudStore(), deviceID: "old-id")
    before.add(300, to: .ads)
    before.flush()

    let after = UserDefaultsTimeSaved(
      defaults: defaults, cloud: MemoryTimeSavedCloudStore(), deviceID: "new-id")

    #expect(after.totals == TimeSavedTotals(ads: 300, silence: 0, speed: 0))
  }

  @Test("without a device ID iCloud is left alone")
  func noDeviceIDNoCloud() throws {
    let cloud = MemoryTimeSavedCloudStore([
      UserDefaultsTimeSaved.cloudKey(.ads, deviceID: "pad"): 30.0
    ])
    let store = UserDefaultsTimeSaved(defaults: try makeDefaults(), cloud: cloud, deviceID: nil)
    store.add(5, to: .speed)
    store.flush()

    #expect(store.totals == TimeSavedTotals(ads: 0, silence: 0, speed: 5))
    #expect(cloud.writtenKeys.isEmpty)
  }

  @Test(
    "a cloud key names its device and source",
    arguments: [
      ("timeSaved.ABC-123.ads", "ABC-123", TimeSavedSource.ads),
      ("timeSaved.ABC-123.speed", "ABC-123", .speed),
    ])
  func parsesCloudKeys(key: String, device: String, source: TimeSavedSource) {
    let parsed = UserDefaultsTimeSaved.parseCloudKey(key)
    #expect(parsed?.deviceID == device)
    #expect(parsed?.source == source)
  }

  @Test(
    "keys that are not time-saved entries are not parsed",
    arguments: [
      "timeSaved..ads", "timeSaved.ABC", "stats.timeSaved.ads", "timeSaved.ABC.minutes",
    ])
  func rejectsOtherKeys(key: String) {
    #expect(UserDefaultsTimeSaved.parseCloudKey(key) == nil)
  }
}
