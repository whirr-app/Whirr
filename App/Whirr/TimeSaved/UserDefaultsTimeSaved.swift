import AppModel
import Foundation
import Observation

/// The iCloud key-value store as the time-saved sum reads it. `SettingsKeyValueStoring` cannot
/// list keys, and `UserDefaults` must never stand in here, so this is its own narrow protocol.
protocol TimeSavedCloudStoring: AnyObject {
  var dictionaryRepresentation: [String: Any] { get }
  func set(_ value: Any?, forKey defaultName: String)
  @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: TimeSavedCloudStoring {}

/// The device's time saved against 1×, by source.
///
/// Totals build up in memory and reach `UserDefaults` and iCloud only on `flush`: every defaults
/// write costs an `ICloudSettingsSync` pass, and the key-value store throttles frequent writes,
/// which would also hold back the synced settings. The local keys must never join
/// `ICloudSettingsSync.syncedKeys`, which is last-writer-wins and would let one device overwrite
/// another's figure.
///
/// In iCloud each device writes only its own `timeSaved.<deviceID>.<source>` entries and reads the
/// sum of every device's. A device that is gone keeps counting.
@MainActor
@Observable
final class UserDefaultsTimeSaved: TimeSavedRecording {
  static let localKeyPrefix = "stats.timeSaved."
  /// Which device ID the local totals were last written to iCloud under.
  static let cloudDeviceKey = "stats.timeSaved.cloudDeviceID"
  /// The Trim Silences-only total this replaces. It was at the listener's rate, not at 1×, so it
  /// is deleted rather than carried over.
  static let retiredTrimSavingsKey = "player.trimSilences.savedSeconds"
  static let cloudKeyPrefix = "timeSaved."

  static func localKey(_ source: TimeSavedSource) -> String { localKeyPrefix + source.rawValue }

  static func cloudKey(_ source: TimeSavedSource, deviceID: String) -> String {
    "\(cloudKeyPrefix)\(deviceID).\(source.rawValue)"
  }

  /// This device's own totals.
  private(set) var local: TimeSavedTotals
  /// Every other device's, from iCloud.
  private(set) var otherDevices: TimeSavedTotals = .zero
  /// What Home and the Stats screen show.
  var totals: TimeSavedTotals { local + otherDevices }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let cloud: (any TimeSavedCloudStoring)?
  @ObservationIgnored private let deviceID: String?
  @ObservationIgnored private var isDirty = false

  /// `cloud` is used only with a `deviceID`: without one a device cannot tell its own entries
  /// from the others'.
  init(
    defaults: UserDefaults = .standard, cloud: (any TimeSavedCloudStoring)? = nil,
    deviceID: String? = nil
  ) {
    self.defaults = defaults
    self.deviceID = deviceID
    self.cloud = deviceID == nil ? nil : cloud
    defaults.removeObject(forKey: Self.retiredTrimSavingsKey)
    var local = TimeSavedTotals.zero
    for source in TimeSavedSource.allCases {
      local[source] = Self.sanitised(defaults.double(forKey: Self.localKey(source)))
    }
    self.local = local
    adoptRestoredTotals()
    refreshFromCloud()
  }

  func add(_ seconds: Double, to source: TimeSavedSource) {
    guard seconds.isFinite, seconds != 0 else { return }
    let next = max(0, local[source] + seconds)
    guard next != local[source] else { return }
    local[source] = next
    isDirty = true
  }

  func flush() {
    guard isDirty else { return }
    isDirty = false
    for source in TimeSavedSource.allCases {
      defaults.set(local[source], forKey: Self.localKey(source))
    }
    guard let cloud, let deviceID else { return }
    for source in TimeSavedSource.allCases {
      cloud.set(local[source], forKey: Self.cloudKey(source, deviceID: deviceID))
    }
    defaults.set(deviceID, forKey: Self.cloudDeviceKey)
    cloud.synchronize()
  }

  /// Re-reads the other devices' entries; called at launch and when iCloud reports a change.
  func refreshFromCloud() {
    guard let cloud, let deviceID else { return }
    var sum = TimeSavedTotals.zero
    for (key, value) in cloud.dictionaryRepresentation {
      guard let (owner, source) = Self.parseCloudKey(key), owner != deviceID,
        let seconds = (value as? NSNumber)?.doubleValue
      else { continue }
      sum[source] += Self.sanitised(seconds)
    }
    if sum != otherDevices { otherDevices = sum }
  }

  /// A backup restored onto a phone brings the local totals with it but not the device ID, which
  /// is new. If the old ID's entries are visible in iCloud they already count these totals, so
  /// this device starts from zero rather than counting them twice.
  private func adoptRestoredTotals() {
    guard let cloud, let deviceID,
      let previous = defaults.string(forKey: Self.cloudDeviceKey), previous != deviceID
    else { return }
    let previousKeys = Set(TimeSavedSource.allCases.map { Self.cloudKey($0, deviceID: previous) })
    guard cloud.dictionaryRepresentation.keys.contains(where: previousKeys.contains) else { return }
    local = .zero
    for source in TimeSavedSource.allCases {
      defaults.set(0.0, forKey: Self.localKey(source))
    }
    defaults.set(deviceID, forKey: Self.cloudDeviceKey)
  }

  static func parseCloudKey(_ key: String) -> (deviceID: String, source: TimeSavedSource)? {
    guard key.hasPrefix(cloudKeyPrefix) else { return nil }
    let rest = key.dropFirst(cloudKeyPrefix.count)
    guard let dot = rest.lastIndex(of: "."),
      let source = TimeSavedSource(rawValue: String(rest[rest.index(after: dot)...]))
    else { return nil }
    let owner = String(rest[..<dot])
    return owner.isEmpty ? nil : (owner, source)
  }

  private static func sanitised(_ seconds: Double) -> Double {
    seconds.isFinite ? max(0, seconds) : 0
  }
}
