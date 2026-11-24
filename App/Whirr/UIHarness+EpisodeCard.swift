#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import SwiftUI

  extension UIHarnessRootView {
    /// `WHIRR_UI_HARNESS_SCREEN=episode-card`: the shipping episode-card sheet over generated
    /// notes long enough to test whether the final sentinel is reachable after scrolling.
    ///
    /// Scenario fake: an episode's notes and download state are server-owned reads.
    var episodeCardBody: some View {
      HarnessEpisodeCardScreen(session: session)
    }
  }

  private struct HarnessEpisodeCardScreen: View {
    let session: UIHarnessSession

    @State private var isEpisodeCardPresented = true

    var body: some View {
      ZStack {
        Color(red: 0.05, green: 0.45, blue: 0.4).ignoresSafeArea()
        Text("APP BEHIND THE EPISODE CARD")
          .font(.title.bold())
          .foregroundStyle(.white)
      }
      .sheet(isPresented: $isEpisodeCardPresented) {
        PodcastEpisodeCardSheet(
          itemID: HarnessPodcastFixtures.longNotesShowID,
          episodeID: HarnessPodcastFixtures.longNotesEpisodeID,
          coverClient: session.coverClient,
          paletteService: session.paletteService,
          navigation: session.navigation,
          playback: session.playback,
          makeModel: {
            PodcastEpisodeCardModel(
              itemID: HarnessPodcastFixtures.longNotesShowID,
              episodeID: HarnessPodcastFixtures.longNotesEpisodeID,
              reading: HarnessPodcastReading(scenario: .offline))
          },
          host: PodcastEpisodeCardHost(openShow: { _ in }, search: { _ in })
        )
      }
      .preferredColorScheme(UIHarnessRootView.harnessColorScheme)
    }
  }
#endif
