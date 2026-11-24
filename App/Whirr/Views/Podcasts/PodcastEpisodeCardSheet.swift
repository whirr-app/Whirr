import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The shared host for an episode card. Both the library shell and expanded player supply their
/// own model and navigation closures, while this wrapper owns the sheet's size-class contract and
/// dismissal affordance.
struct PodcastEpisodeCardSheet: View {
  let itemID: String
  let episodeID: String
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let navigation: NavigationModel
  let playback: PlaybackModel
  let makeModel: () -> PodcastEpisodeCardModel
  let host: PodcastEpisodeCardHost
  var listContext: NavigationModel.SmartListContext?
  var transcriptCoordinator: EpisodeTranscriptCoordinator?

  @Environment(\.dismiss) private var dismiss
  /// The window's size class, not the sheet's. See `EnvironmentValues.windowHorizontalSizeClass`.
  @Environment(\.windowHorizontalSizeClass) private var windowHorizontalSizeClass

  private typealias Metric = PodcastEpisodeCardViewPresentation.Metric

  private var mode: SheetViewPresentation.Mode {
    SheetViewPresentation.mode(for: windowHorizontalSizeClass, role: .episodeCard)
  }

  @ViewBuilder
  var body: some View {
    switch mode {
    case .compactDetents:
      // Detents and drag indicator, no navigation bar: it would cost the `.medium` detent vertical
      // space the notes are short of. Content interaction stays `.automatic`: the body is one
      // `ScrollView`, so `.scrolls` would take every vertical drag and leave the grabber as the
      // only way to `.large`. System Liquid Glass at `.medium` shows cover art under the notes; a
      // fixed grey fell below AA there (ADR 0012), so secondary copy uses hierarchical ink.
      card(onSystemGlass: true)
        .presentationDetents(PodcastEpisodeCardViewPresentation.detents)
        .presentationDragIndicator(.visible)
    case .regularPage:
      // A page-sized sheet has no detents, so an explicit Close replaces the indicator. `.page`,
      // not `.page.fitted(vertical:)`: the sheet is measured while the model is `.loading` (a
      // spinner), so fitting would open a strip that never grows when the episode arrives.
      NavigationStack {
        card()
          .frame(maxWidth: Metric.cardMaxWidth)
          .frame(maxWidth: .infinity)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(role: .close) { dismiss() }
            }
          }
      }
      .presentationSizing(.page)
      .presentationDragIndicator(.hidden)
    case .compactLarge, .regularForm, .regularFitted, .regularFullPage, .exempt:
      card()
    }
  }

  private func card(onSystemGlass: Bool = false) -> some View {
    PodcastEpisodeCardView(
      itemID: itemID,
      episodeID: episodeID,
      coverClient: coverClient,
      paletteService: paletteService,
      navigation: navigation,
      playback: playback,
      makeModel: makeModel,
      host: host,
      onSystemGlass: onSystemGlass,
      listContext: listContext,
      transcriptCoordinator: transcriptCoordinator
    )
    #if PERF_INVESTIGATION
      .modifier(MicrostutterSheetAblation())
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("podcast.episode.sheet")
    #endif
  }
}
