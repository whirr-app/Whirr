import Testing

@testable import Whirr

@Suite("Podcast UI harness configuration")
struct PodcastUIHarnessConfigurationTests {
  @Test func requiredServerlessScenariosAreRepresented() {
    #expect(
      Set(UIHarness.PodcastScenario.allCases)
        == Set([
          .malformed, .empty, .loading, .offline, .deviceDownloaded, .staleShow,
          .downloadWaitingForWiFi, .downloadFailed, .filteredEmpty, .downloadTicking,
        ]))
  }

  @Test func representativePhonePadAndAccessibilityConfigurationsAreRepresented() {
    #expect(UIHarness.PodcastHarnessFormFactor.compactPhone.maximumContentWidth == 430)
    #expect(UIHarness.PodcastHarnessFormFactor.compactPhone.horizontalSizeClass == .compact)
    // 930 pt is the landscape content pane beside the 280 pt sidebar. The harness stands in for
    // the width production gets from its parent.
    #expect(UIHarness.PodcastHarnessFormFactor.regularPad.maximumContentWidth == 930)
    #expect(UIHarness.PodcastHarnessFormFactor.regularPad.horizontalSizeClass == .regular)
    #expect(
      UIHarness.PodcastHarnessFormFactor.accessibilityPhone.dynamicTypeSize
        == .accessibility3)
    // The accessibility grid minimum shows only at regular width. `regularPad` is pinned to
    // `.large`, so it cannot exercise that case, hence this one.
    #expect(UIHarness.PodcastHarnessFormFactor.accessibilityPad.maximumContentWidth == 930)
    #expect(UIHarness.PodcastHarnessFormFactor.accessibilityPad.horizontalSizeClass == .regular)
    #expect(
      UIHarness.PodcastHarnessFormFactor.accessibilityPad.dynamicTypeSize == .accessibility3)
  }
}
