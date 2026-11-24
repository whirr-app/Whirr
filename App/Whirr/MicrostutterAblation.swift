import ABSApi
import AppModel
import SwiftUI

/// Narrow profiling-only diagnostic switches; never user preferences.
#if PERF_INVESTIGATION
  enum MicrostutterAblation {
    private static let arguments = Set(ProcessInfo.processInfo.arguments)
    static let playerPlaying = arguments.contains("-perf-player-playing")
    static let playerPaused = arguments.contains("-perf-player-paused")
    static let fixture = arguments.contains("-perf-fixture")
    static let emptySheet = arguments.contains("-perf-empty-sheet")
    static let blankUnderlay = arguments.contains("-perf-blank-underlay")
    /// Restores the pre-fix dependency: the shell body itself reads the presentation state, so a
    /// present or dismiss invalidates the `TabView` root and any retained tab under it.
    static let inlineShellPresentation = arguments.contains("-perf-inline-shell-presentation")
    static let minimalUnderlay = arguments.contains("-perf-minimal-underlay")
    static let opaqueSheet = arguments.contains("-perf-opaque-sheet")
    static let noAccessory = arguments.contains("-perf-no-accessory")
    static let staticHome = arguments.contains("-perf-static-home")
    static let logViewChanges = arguments.contains("-perf-log-view-changes")
    static let homeGeometryGroup = arguments.contains("-perf-home-geometry-group")
    static let cardGeometryGroup = arguments.contains("-perf-card-geometry-group")
    static let idealCardHeight = arguments.contains("-perf-ideal-card-height")
    static let staticCards = arguments.contains("-perf-static-cards")
    static let stableHomeCallback = arguments.contains("-perf-stable-home-callback")
    static let stableHomeHost = arguments.contains("-perf-stable-home-host")
    /// Uses a process-unique prepared-artwork cache and artwork scope. Prefetch and wash controls
    /// remain independent environment ablations so cold and warm arms can hold them constant.
    static let coldArtwork = arguments.contains("-perf-cold-artwork")
    /// Pins fixture UIKit tint adjustment to normal for sheet-handoff comparison.
    static let normalWindowTintAdjustment = arguments.contains("-perf-normal-window-tint")
    /// Optional fixture-only visual validation arm; the default remains dark.
    static let fixtureLight = arguments.contains("-perf-fixture-light")
    /// Renders the Library tab's content only while Library is selected, to test whether rebuilding
    /// the catalogue row hierarchy on every tab switch costs the arrival. Diagnostic only: it drops
    /// a deselected tab's scroll position and root state, unacceptable in production.
    static let deferInactiveLibrary = arguments.contains("-perf-defer-inactive-library")
    /// Restores the pre-boundary Library tab shape, with the root's callbacks handed to it as
    /// closure properties again, so an A/B/A run can compare the equality boundary against its own
    /// absence on one frozen binary. See `LibraryTabContent`.
    static let unboundedLibraryTab = arguments.contains("-perf-unbounded-library-tab")
  }

  /// Fixture-only artwork resources. Lazy static initialization gives each cold-artwork app
  /// process an independent decoded tier and a stable key namespace for that run.
  enum MicrostutterArtworkFixture {
    static let scope = ArtworkAccountScope("perf-cold-artwork:\(UUID().uuidString)")
    static let cache = PreparedArtworkCache()
    static let pipeline = ArtworkImagePipeline(cache: cache)
  }

  struct MicrostutterCardLayoutAblation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
      if MicrostutterAblation.idealCardHeight {
        content.fixedSize(horizontal: false, vertical: true)
      } else if MicrostutterAblation.cardGeometryGroup {
        content.geometryGroup()
      } else {
        content
      }
    }
  }

  struct MicrostutterHomeGeometryAblation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
      if MicrostutterAblation.homeGeometryGroup {
        content.geometryGroup()
      } else {
        content
      }
    }
  }

  struct MicrostutterSheetAblation: ViewModifier {
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder
    func body(content: Content) -> some View {
      if MicrostutterAblation.emptySheet {
        Color(uiColor: .systemBackground)
          .overlay(alignment: .topTrailing) {
            Button("Done") {
              if let onDismiss { onDismiss() } else { dismiss() }
            }
            .accessibilityIdentifier("perf.emptySheet.done")
            .padding()
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("perf.emptySheet")
      } else if MicrostutterAblation.opaqueSheet {
        content.presentationBackground(Color(uiColor: .systemBackground))
      } else {
        content
      }
    }
  }
  /// Live counterpart of the fixture's diagnostic tint control: the same public UIKit anchor, so
  /// a live arm can isolate automatic dimming at sheet handoff. Diagnostic only, and compiled out
  /// of ordinary builds. A concrete modifier rather than an inline overlay because the shell body
  /// it attaches to is already at the type-checker's limit.
  struct MicrostutterLiveTintAblation: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
      if MicrostutterAblation.normalWindowTintAdjustment {
        content.overlay { MicrostutterWindowTintAdjustmentOverride() }
      } else {
        content
      }
    }
  }

  struct MicrostutterUnderlayAblation: ViewModifier {
    /// Read inside this modifier's body, not handed in as a `Bool`. Computing the flag in the
    /// shell body would register the presentation dependency the presentation host exists to
    /// remove, and only in PERF builds, the ones used to measure whether it was removed.
    let navigation: NavigationModel
    @ViewBuilder
    func body(content: Content) -> some View {
      let isPresented =
        navigation.settingsPresentation == .presented || navigation.presentedEpisode != nil
      if MicrostutterAblation.blankUnderlay && isPresented {
        Color(uiColor: .systemBackground)
      } else {
        content
      }
    }
  }
#endif
