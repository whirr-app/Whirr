import ABSApi
import AppModel
import Persistence
import SwiftUI

/// What the Podcasts root's show tiles read synchronously on their first frame, made ready before
/// the tab is first visited.
///
/// Tiles read their cover from `PreparedArtworkCache` and card colour from `HomeWashProvider`,
/// both memory tiers empty each launch that Home never fills for show tiles. This lifts the
/// preview's share into memory at `.scrollPrefetch` so a cold first arrival doesn't crossfade
/// covers in and repaint cards from neutral. Bytes and records are already persistent
/// (`FollowedShowArtworkWarmPass`).
enum PodcastsRootArrivalWarming {
  /// The root's curated preview. Width is unknown here, so this is the compact count. A regular
  /// width's preview is two full grid rows and may draw more tiles than this warms.
  static func previewShows(
    nativeShows: [ItemSummary], nativeMode: NativePodcastShowSortMode,
    serverShows: [ItemSummary], serverMode: PodcastShowSortMode,
    nativeSubscriptionsEnabled: Bool, hasIncludedPodcastLibrary: Bool
  ) -> [ItemSummary] {
    PodcastsViewPresentation.showsSectionShows(
      nativeShows: nativeShows, nativeMode: nativeMode,
      serverShows: serverShows, serverMode: serverMode,
      nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
      hasIncludedPodcastLibrary: hasIncludedPodcastLibrary,
      limit: PodcastsViewPresentation.previewLimit)
  }

  static func warm(
    _ shows: [ItemSummary],
    displayScale: CGFloat,
    client: any ArtworkServing,
    service: CoverPaletteService,
    pipeline: ArtworkImagePipeline = .shared
  ) async {
    let subjects = shows.map(\.washSubject)
    _ = await service.cachedWashes(
      itemIDs: subjects.itemIDs, revisionsByID: subjects.revisionsByID,
      sourcesByID: subjects.sourcesByID)
    for show in shows {
      guard Task.isCancelled == false else { return }
      // A followed show with no artwork source draws generated art, which has nothing to fetch.
      if PodcastSourceIdentity(itemId: show.serverItemId)?.rssFeedId != nil,
        show.providerArtworkSource == nil
      {
        continue
      }
      let key = CoverImageView.artworkKey(
        itemID: show.serverItemId, client: client, source: show.providerArtworkSource,
        displaySize: PodcastsView.cardSize, displayScale: displayScale, role: .homeCard,
        revision: show.artworkRevision)
      _ = await pipeline.image(for: key, priority: .scrollPrefetch, client: client)
    }
  }
}

/// Runs `PodcastsRootArrivalWarming` for the shell's lifetime, following the show models through
/// `Observations` so the shell's own body never depends on them.
struct PodcastsRootArrivalWarmup: ViewModifier {
  let isEnabled: Bool
  let showsModel: PodcastShowsModel
  let nativeShowsModel: NativePodcastShowsModel
  let hasIncludedPodcastLibrary: Bool
  let nativeSubscriptionsEnabled: Bool
  let coverClient: any ArtworkServing
  let service: CoverPaletteService

  @Environment(\.displayScale) private var displayScale

  private struct Configuration: Equatable {
    let isEnabled: Bool
    let hasIncludedPodcastLibrary: Bool
    let nativeSubscriptionsEnabled: Bool
    let displayScale: CGFloat
  }

  func body(content: Content) -> some View {
    content.task(
      id: Configuration(
        isEnabled: isEnabled, hasIncludedPodcastLibrary: hasIncludedPodcastLibrary,
        nativeSubscriptionsEnabled: nativeSubscriptionsEnabled, displayScale: displayScale)
    ) {
      guard isEnabled else { return }
      let previews = Observations {
        [showsModel, nativeShowsModel, hasIncludedPodcastLibrary, nativeSubscriptionsEnabled] in
        PodcastsRootArrivalWarming.previewShows(
          nativeShows: nativeShowsModel.shows, nativeMode: nativeShowsModel.sortMode,
          serverShows: PodcastsViewPresentation.shows(in: showsModel.state),
          serverMode: showsModel.sortMode,
          nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
          hasIncludedPodcastLibrary: hasIncludedPodcastLibrary)
      }
      var warmed: Set<EditorialWashSubject> = []
      for await shows in previews {
        let fresh = shows.filter { warmed.insert($0.washSubject).inserted }
        guard fresh.isEmpty == false else { continue }
        await PodcastsRootArrivalWarming.warm(
          fresh, displayScale: displayScale, client: coverClient, service: service)
      }
    }
  }
}
