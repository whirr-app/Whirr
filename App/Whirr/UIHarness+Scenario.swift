#if DEBUG || PERF_INVESTIGATION
  import SwiftUI

  /// What one harness run presents, resolved from `WHIRR_UI_HARNESS_*`.
  ///
  /// The environment names and the scenario enums they select (`UIHarness.Screen`,
  /// `UIHarnessReaderScenario`, `UIHarness.SearchScenario`, `UIHarness.PodcastScenario`) are the
  /// harness's public surface: schemes, screenshot scripts and `App/WhirrTests` pass them by name.
  /// This value gathers the ones a screen needs so a body reads one input instead of re-parsing
  /// `ProcessInfo`.
  ///
  /// Computed, never cached: the hosted suites rewrite `WHIRR_UI_HARNESS_SCREEN` between hosts
  /// (`ReflowTests` sweeps ten screens in one process), so a stored snapshot would pin the first.
  struct UIHarnessScenario: Sendable {
    var screen: UIHarness.Screen
    /// The item the detail screen presents. `WHIRR_UI_HARNESS_ITEM` selects the alternate fixtures.
    var detailItemID: String
    /// The appearance the screens pin, so a capture is reproducible. `WHIRR_UI_HARNESS_SCHEME=light`
    /// flips it, which is how a token pinned to one scheme gets caught.
    var colorScheme: ColorScheme

    static var current: Self {
      Self(
        screen: UIHarness.screen,
        detailItemID: UIHarness.detailItemID,
        colorScheme: UIHarness.harnessColorScheme)
    }
  }
#endif
