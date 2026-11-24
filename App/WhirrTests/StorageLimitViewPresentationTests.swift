import AppModel
import SyncEngine
import Testing

@testable import Whirr

@Suite("Storage Limit view presentation")
struct StorageLimitViewPresentationTests {
  @Test("compact accessibility includes the limit, usage, and known capacity")
  func compactAccessibilityIncludesKnownValues() {
    let value = StorageLimitViewPresentation.compactAccessibilityValue(
      ceiling: .gigabytes(16),
      usage: "6.2 GB of 16 GB",
      availableCapacity: "42 GB available")

    #expect(
      value
        == "\(SettingsCopy.storageCeilingLabel(.gigabytes(16))), "
        + "6.2 GB of 16 GB, 42 GB available")
  }

  @Test("compact accessibility omits unavailable capacity")
  func compactAccessibilityOmitsUnavailableCapacity() {
    let value = StorageLimitViewPresentation.compactAccessibilityValue(
      ceiling: .unlimited,
      usage: "6.2 GB downloaded",
      availableCapacity: nil)

    #expect(
      value
        == "\(SettingsCopy.storageCeilingLabel(.unlimited)), 6.2 GB downloaded")
  }

  @Test("unavailable data is spoken as unavailable rather than as the visible dash")
  func unavailableDataHasSpokenValue() {
    #expect(
      StorageLimitViewPresentation.dataAccessibilityValue(
        displayedValue: SettingsCopy.unavailableValue,
        isAvailable: false)
        == SettingsCopy.storageUnavailableAccessibilityValue)
    #expect(
      StorageLimitViewPresentation.dataAccessibilityValue(
        displayedValue: "0 bytes",
        isAvailable: true)
        == "0 bytes")
  }

  @Test("the slider's thumb position and the stop it stands for map both ways")
  func sliderPositionsMapToStops() {
    let stops = StorageCeilingStops.stops(maximumBytes: 26_000_000_000, including: .unlimited)

    #expect(StorageLimitViewPresentation.sliderRange(for: stops) == 0...Double(stops.count - 1))
    for (index, stop) in stops.enumerated() {
      #expect(StorageLimitViewPresentation.sliderValue(for: stop, in: stops) == Double(index))
      #expect(
        StorageLimitViewPresentation.ceiling(forSliderValue: Double(index), in: stops) == stop)
    }
    #expect(StorageLimitViewPresentation.sliderValue(for: .unlimited, in: stops) == Double(stops.count - 1))
  }

  @Test("a thumb position from a longer stop list still lands on a real stop")
  func staleSliderPositionsAreHeldInRange() {
    let stops = StorageCeilingStops.stops(maximumBytes: 2_000_000_000, including: .unlimited)

    #expect(StorageLimitViewPresentation.ceiling(forSliderValue: 40, in: stops) == .unlimited)
    #expect(StorageLimitViewPresentation.ceiling(forSliderValue: -3, in: stops) == .gigabytes(1))
    #expect(StorageLimitViewPresentation.ceiling(forSliderValue: 0.6, in: stops) == .gigabytes(2))
    #expect(StorageLimitViewPresentation.ceiling(forSliderValue: 0, in: []) == nil)
  }

  @Test("the limit control speaks the limit and what choosing it would remove")
  func sliderAccessibilityValueNamesTheReduction() {
    #expect(
      StorageLimitViewPresentation.sliderAccessibilityValue(
        ceiling: .gigabytes(7), reductionPreview: "Removes about 2 GB of completed downloads.")
        == "7 GB, Removes about 2 GB of completed downloads.")
    #expect(
      StorageLimitViewPresentation.sliderAccessibilityValue(
        ceiling: .unlimited, reductionPreview: nil)
        == SettingsCopy.storageCeilingUnlimited)
  }

  @Test("compact status stacks only at accessibility Dynamic Type sizes")
  func compactStatusAdaptiveLayout() {
    #expect(
      StorageLimitViewPresentation.stacksCompactStatus(isAccessibilitySize: false) == false)
    #expect(
      StorageLimitViewPresentation.stacksCompactStatus(isAccessibilitySize: true))
  }
}
