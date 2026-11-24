import Testing

@testable import Whirr

@Suite("Sleep timer preset configuration")
struct SleepTimerPresetConfigurationTests {

  @Test("empty storage uses the bedtime-friendly defaults")
  func emptyStorageUsesDefaults() {
    #expect(SleepTimerPresetConfiguration.decode("").minutes == [15, 30, 45, 60])
  }

  @Test("stored presets sort while removing invalid and duplicate values")
  func storedPresetsAreSanitized() {
    let configuration = SleepTimerPresetConfiguration.decode("25,10,25,0,241,nope,90")
    #expect(configuration.minutes == [10, 25, 90])
    #expect(configuration.encoded == "10,25,90")
  }

  @Test("editing always retains at least one preset")
  func editingRetainsOnePreset() {
    let configuration = SleepTimerPresetConfiguration(minutes: [])
    #expect(configuration.minutes == SleepTimerPresetConfiguration.defaults)
  }

  /// Settings hides its reset row when there is nothing to reset, and asks before resetting.
  @Test("the presets know when they are the defaults and name them before a reset")
  func resetIsOfferedOnlyWhenCustomised() {
    #expect(SleepTimerPresetConfiguration.decode("").isDefault)
    #expect(SleepTimerPresetConfiguration.decode("60,45,30,15").isDefault)
    #expect(SleepTimerPresetConfiguration.decode("15,20,25,30").isDefault == false)
    #expect(
      SleepTimerPresetConfiguration.resetMessage
        == "Your timer shortcuts will go back to 15, 30, 45 and 60 minutes.")
  }
}
