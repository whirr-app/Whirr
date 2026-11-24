#if DEBUG || PERF_INVESTIGATION
  import DesignSystem
  import SwiftUI

  /// `WHIRR_UI_HARNESS_SCREEN=home-shell`: Home inside the shipping tab shell.
  ///
  /// The plain `home` screen uses a bare `NavigationStack` with the mini player as a bottom
  /// `safeAreaInset`: enough for scroll measurement, wrong for anything turning on the safe area.
  /// `LibraryShellView` puts every root screen in a `TabView` whose bottom accessory is a
  /// system-owned host, and SwiftUI drives a `ScrollView`'s refresh control through
  /// `safeAreaInsets`, not `contentInset`, so a pull grows the top safe area by the control's
  /// height and shrinks it on return. Two owners of one inset is what a stranded inset needs; the
  /// bare stack has one.
  extension UIHarnessRootView {
    var homeShellBody: some View {
      HarnessHomeShellScreen(session: session)
    }
  }

  struct HarnessHomeShellScreen: View {
    let session: UIHarnessSession
    @State private var models = HarnessHomeModels()

    var body: some View {
      TabView {
        Tab("Home", systemImage: "house") {
          NavigationStack {
            HomeView(
              model: models.home,
              latestEpisodesModel: models.latestEpisodes,
              coverClient: session.coverClient,
              paletteService: session.paletteService,
              playback: session.playback,
              actions: session.actions,
              onSelectItem: { _ in },
              onSelectDownloadedPodcast: { _ in },
              onSelectEpisode: { _, _ in },
              onOpenSection: { _ in },
              onSearch: { _ in }
            )
          }
        }
        Tab("Library", systemImage: "books.vertical") {
          NavigationStack { Color.clear.navigationTitle("Library") }
        }
        Tab("Podcasts", systemImage: "waveform") {
          NavigationStack { Color.clear.navigationTitle("Podcasts") }
        }
      }
      .tabViewStyle(.sidebarAdaptable)
      .tabBarMinimizeBehavior(.never)
      .tabViewBottomAccessory { harnessShellAccessory }
      .preferredColorScheme(UIHarness.harnessColorScheme)
      .overlay {
        if UIHarness.runsScrollScript {
          UIHarnessScrollDriver()
        }
      }
    }

    private var harnessShellAccessory: some View {
      MiniPlayerView(
        title: UIHarnessFixtures.title,
        subtitle: UIHarnessFixtures.mixedAuthor,
        isPlaying: false,
        playPauseAccessibilityLabel: "Play",
        skipBackAccessibilityLabel: "Skip back",
        skipBackAccessibilityHint: "Skips backward.",
        skipBackSystemImage: "gobackward.15",
        skipForwardAccessibilityLabel: "Skip forward",
        skipForwardAccessibilityHint: "Skips forward.",
        skipForwardSystemImage: "goforward.30",
        progressAccessibilityValue: { "" },
        expandAccessibilityHint: "Opens the full player.",
        coverAccessibilityLabel: nil,
        isTitleMarqueeActive: false,
        contentColorScheme: .dark,
        cover: { Color.gray },
        onPlayPauseTap: {},
        onSkipBackTap: {},
        onSkipForwardTap: {},
        onExpandTap: {}
      )
    }
  }
#endif
