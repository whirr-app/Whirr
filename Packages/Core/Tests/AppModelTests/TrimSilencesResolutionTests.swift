import Persistence
import Testing

@testable import AppModel

/// `TrimSilencesResolution`: a show's own setting wins, and
/// `inherit` takes the default.
@Suite struct TrimSilencesResolutionTests {
  static let defaults: [TrimSilencesDefault] = [
    .off, TrimSilencesDefault(isEnabled: false, strength: .maximum),
    TrimSilencesDefault(isEnabled: true, strength: .moderate),
    TrimSilencesDefault(isEnabled: true, strength: .maximum),
  ]

  @Test(arguments: defaults)
  func everyDefaultAndOverridePair(_ value: TrimSilencesDefault) {
    let inherited: TrimStrength? = value.isEnabled ? value.strength : nil
    #expect(TrimSilencesResolution.strength(default: value, showOverride: .inherit) == inherited)
    #expect(TrimSilencesResolution.strength(default: value, showOverride: .off) == nil)
    #expect(TrimSilencesResolution.strength(default: value, showOverride: .moderate) == .moderate)
    #expect(TrimSilencesResolution.strength(default: value, showOverride: .maximum) == .maximum)
  }

  @Test func tickingWritesTheDefaultStrengthWhenTheDefaultIsOff() {
    let value = TrimSilencesDefault(isEnabled: false, strength: .maximum)
    #expect(TrimSilencesResolution.overrideForToggle(toOn: true, default: value) == .maximum)
  }

  @Test func untickingWritesOffWhenTheDefaultIsOn() {
    let value = TrimSilencesDefault(isEnabled: true, strength: .moderate)
    #expect(TrimSilencesResolution.overrideForToggle(toOn: false, default: value) == .off)
  }

  @Test func aTapThatMatchesTheDefaultClearsTheOverride() {
    let on = TrimSilencesDefault(isEnabled: true, strength: .moderate)
    #expect(TrimSilencesResolution.overrideForToggle(toOn: true, default: on) == .inherit)
    #expect(TrimSilencesResolution.overrideForToggle(toOn: false, default: .off) == .inherit)
  }
}

/// A Focus filter's trim: it replaces the default, and
/// every show's own setting too unless it keeps them.
@Suite struct FocusTrimResolutionTests {
  static let stored = TrimSilencesDefault(isEnabled: true, strength: .maximum)
  static let overrides: [TrimSilencesShowOverride] = [.inherit, .off, .moderate, .maximum]
  static let focusStrengths: [TrimStrength?] = [nil, .moderate, .maximum]

  @Test(arguments: overrides, focusStrengths)
  func aFocusThatReplacesShowSettingsDecidesEveryShow(
    _ showOverride: TrimSilencesShowOverride, _ focusStrength: TrimStrength?
  ) {
    var value = Self.stored
    value.focus = FocusTrim(strength: focusStrength, keepsShowSettings: false)
    #expect(
      TrimSilencesResolution.strength(default: value, showOverride: showOverride) == focusStrength)
  }

  @Test(arguments: overrides, focusStrengths)
  func aFocusThatKeepsShowSettingsDecidesOnlyInheritingShows(
    _ showOverride: TrimSilencesShowOverride, _ focusStrength: TrimStrength?
  ) {
    var value = Self.stored
    value.focus = FocusTrim(strength: focusStrength, keepsShowSettings: true)
    let expected =
      showOverride == .inherit
      ? focusStrength
      : TrimSilencesResolution.strength(default: Self.stored, showOverride: showOverride)
    #expect(TrimSilencesResolution.strength(default: value, showOverride: showOverride) == expected)
  }

  @Test func storedDropsOnlyTheFocus() {
    var value = Self.stored
    value.focus = FocusTrim(strength: nil, keepsShowSettings: true)
    #expect(value.stored == Self.stored)
    #expect(value != Self.stored)
  }

  @Test func showSettingsLabelNamesTheStoredDefaultNotTheFocus() {
    var value = Self.stored
    value.focus = FocusTrim(strength: nil, keepsShowSettings: false)
    #expect(TrimSilencesCopy.showChoiceLabel(.inherit, default: value) == "Default (High)")
  }

  @Test func focusGovernsAShowUnlessItKeepsThatShowsOwnSetting() {
    var value = Self.stored
    #expect(TrimSilencesResolution.focusGoverns(default: value, showOverride: .inherit) == false)
    value.focus = FocusTrim(strength: .moderate, keepsShowSettings: true)
    #expect(TrimSilencesResolution.focusGoverns(default: value, showOverride: .inherit))
    #expect(TrimSilencesResolution.focusGoverns(default: value, showOverride: .off) == false)
    value.focus = FocusTrim(strength: .moderate, keepsShowSettings: false)
    #expect(TrimSilencesResolution.focusGoverns(default: value, showOverride: .off))
  }

  /// Under a keeping Focus, unticking an inheriting show pins it off, so the Focus stops
  /// deciding it at once.
  @Test func untickingUnderAKeepingFocusPinsTheShow() {
    var value = TrimSilencesDefault.off
    value.focus = FocusTrim(strength: .maximum, keepsShowSettings: true)
    #expect(TrimSilencesResolution.toggledOverride(from: .inherit, default: value) == .off)
  }

  /// A pin the Focus keeps is not collapsed to inherit just because inherit matches the Focus:
  /// inherit would mean something else once the Focus ends.
  @Test func aKeptPinIsNotCollapsedToMatchTheFocus() {
    var value = Self.stored
    value.focus = FocusTrim(strength: nil, keepsShowSettings: true)
    #expect(TrimSilencesResolution.toggledOverride(from: .maximum, default: value) == .off)
  }

  /// Under a Focus that decides every show, a tap flips the stored setting, which
  /// takes effect when the Focus ends.
  @Test func aTapUnderAGoverningFocusFlipsTheStoredSetting() {
    var value = Self.stored
    value.focus = FocusTrim(strength: .maximum, keepsShowSettings: false)
    #expect(TrimSilencesResolution.toggledOverride(from: .inherit, default: value) == .off)
    #expect(TrimSilencesResolution.toggledOverride(from: .off, default: value) == .inherit)
  }

  @Test func withoutAFocusTheToggleIsUnchanged() {
    let on = TrimSilencesDefault(isEnabled: true, strength: .moderate)
    #expect(TrimSilencesResolution.toggledOverride(from: .inherit, default: on) == .off)
    #expect(TrimSilencesResolution.toggledOverride(from: .off, default: on) == .inherit)
    #expect(TrimSilencesResolution.toggledOverride(from: .inherit, default: .off) == .moderate)
  }
}

extension TrimSilencesDefault: CustomTestStringConvertible {
  public var testDescription: String { isEnabled ? "on, \(strength)" : "off, \(strength)" }
}
