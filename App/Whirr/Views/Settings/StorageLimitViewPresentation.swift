import AppModel
import SyncEngine

/// Pure adaptive and accessibility presentation for the two Storage Limit surfaces. Visible byte
/// formatting and policy wording remain owned by `SettingsCopy`/`SettingsModel`; this type only
/// arranges those already-decided values into stable spoken and layout states.
enum StorageLimitViewPresentation {
  static func stacksCompactStatus(isAccessibilitySize: Bool) -> Bool {
    isAccessibilitySize
  }

  static func compactAccessibilityValue(
    ceiling: StorageCeiling,
    usage: String,
    availableCapacity: String?
  ) -> String {
    [SettingsCopy.storageCeilingLabel(ceiling), usage, availableCapacity]
      .compactMap { $0 }
      .joined(separator: ", ")
  }

  static func dataAccessibilityValue(displayedValue: String, isAvailable: Bool) -> String {
    isAvailable ? displayedValue : SettingsCopy.storageUnavailableAccessibilityValue
  }

  /// Where the slider's thumb sits for `ceiling`: its position among `stops`.
  static func sliderValue(for ceiling: StorageCeiling, in stops: [StorageCeiling]) -> Double {
    Double(StorageCeilingStops.index(of: ceiling, in: stops))
  }

  /// The stop a thumb position stands for. The slider steps in whole positions, but a value read
  /// against a stop list that has since changed length must still land on a real stop.
  static func ceiling(forSliderValue value: Double, in stops: [StorageCeiling]) -> StorageCeiling? {
    guard stops.isEmpty == false else { return nil }
    let index = min(max(Int(value.rounded()), 0), stops.count - 1)
    return stops[index]
  }

  static func sliderRange(for stops: [StorageCeiling]) -> ClosedRange<Double> {
    0...Double(max(stops.count - 1, 1))
  }

  /// The limit control's spoken value: the limit, then what choosing it would remove, if anything.
  static func sliderAccessibilityValue(ceiling: StorageCeiling, reductionPreview: String?) -> String {
    [SettingsCopy.storageCeilingLabel(ceiling), reductionPreview]
      .compactMap { $0 }
      .joined(separator: ", ")
  }
}
