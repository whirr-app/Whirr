#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import Persistence
  import SwiftUI

  extension UIHarnessRootView {
    /// `WHIRR_UI_HARNESS_SCREEN=detail-card`: ADR 0008's regular-width item-detail card over the
    /// real Library browse root. The card spends most of its life dimming a populated grid, which
    /// captures over a near-empty list could not show. This screen exists to judge that, and to
    /// give the card a portrait capture the landscape-locked simulator could not produce.
    ///
    /// Scenario fake: the card dims the Library grid and pushes the `detail` screen, so it reads the
    /// same server-owned item fixtures that screen documents.
    var detailCardBody: some View {
      HarnessDetailCardScreen(session: session)
    }
  }

  /// Its own view rather than a computed property: the presentation is `@State`, which an
  /// extension cannot add.
  private struct HarnessDetailCardScreen: View {
    let session: UIHarnessSession

    @State private var isCardPresented = true

    var body: some View {
      HarnessLibraryScreen(session: session)
        .sheet(isPresented: $isCardPresented) {
          ItemDetailCardSheet {
            HarnessItemDetailView(session: session)
          }
        }
        .preferredColorScheme(UIHarnessRootView.harnessColorScheme)
    }
  }

  /// Item detail as the harness builds it, shared by the `detail` screen's own `NavigationStack`
  /// and by the card above. Both must present the same screen, or the card capture proves
  /// nothing about the pushed one.
  struct HarnessItemDetailView: View {
    let session: UIHarnessSession

    var body: some View {
      ItemDetailView(
        itemId: UIHarness.detailItemID,
        library: session.library,
        nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
        coverClient: session.coverClient,
        paletteService: session.paletteService,
        playback: session.playback,
        downloadReading: session.downloadReading,
        downloadIntents: session.downloadIntents,
        extrasAccess: session.extrasAccess,
        historyAccess: session.historyAccess,
        finishedStatus: session.finishedStatus,
        requestLocalSessionUploadDrain: {},
        downloadStatus: session.downloadStatus,
        readerReading: session.readerStateReading,
        tableOfContentsReading: session.readerTableOfContents,
        effectiveAppColorScheme: UIHarnessRootView.harnessColorScheme
      )
    }
  }
#endif
