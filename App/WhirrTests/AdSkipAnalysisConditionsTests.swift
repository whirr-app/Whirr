import Foundation
import Testing

@testable import Whirr

/// When analysis may run: on external power unless the listener allows battery, never in Low Power
/// Mode, and never once the phone is hot.
@Suite("Ad skip analysis conditions")
struct AdSkipAnalysisConditionsTests {

  private func reason(
    lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal,
    onExternalPower: Bool = true, onlyWhileCharging: Bool = true
  ) -> AdSkipPauseReason? {
    AdSkipAnalysisConditions.pauseReason(
      .init(
        isLowPowerModeEnabled: lowPower, thermalState: thermal,
        isOnExternalPower: onExternalPower, onlyWhileCharging: onlyWhileCharging))
  }

  private func isolatedDefaults() throws -> UserDefaults {
    let name = "AdSkipAnalysisConditionsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("only while charging is off until turned on")
  func chargingOnlyOffByDefault() throws {
    let defaults = try isolatedDefaults()
    #expect(AdSkipPreference.isOnlyWhileCharging(in: defaults) == false)
    defaults.set(true, forKey: AdSkipPreference.onlyWhileChargingKey)
    #expect(AdSkipPreference.isOnlyWhileCharging(in: defaults))
  }

  @Test("on battery, analysis waits for power unless the listener allows battery")
  func batteryWaitsForPower() {
    #expect(reason(onExternalPower: false) == .notCharging)
    #expect(reason(onExternalPower: false, onlyWhileCharging: false) == nil)
    #expect(reason(onExternalPower: true) == nil)
  }

  @Test("Low Power Mode and a hot phone pause analysis even on power")
  func lowPowerAndHeatPause() {
    #expect(reason(lowPower: true) == .lowPowerMode)
    #expect(reason(thermal: .fair) == nil)
    #expect(reason(thermal: .serious) == .warm)
    #expect(reason(thermal: .critical) == .warm)
    #expect(reason(lowPower: true, onlyWhileCharging: false) == .lowPowerMode)
  }

  @Test("waiting for power is reported before the other reasons")
  func chargingReportedFirst() {
    #expect(reason(lowPower: true, thermal: .serious, onExternalPower: false) == .notCharging)
  }

  @Test("the charging setting stays on this device")
  func chargingSettingIsNotSynced() {
    #expect(ICloudSettingsSync.syncedKeys.contains(AdSkipPreference.onlyWhileChargingKey) == false)
  }
}
