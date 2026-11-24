import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import UIKit

extension AppEnvironment {
  struct LibraryCacheComposition {
    let metadataBackfill: ItemMetadataBackfillCoordinator
    let access: ArtworkCacheService
    let followedShowArtworkWarmPass: FollowedShowArtworkWarmPass
    let coverPaletteBackfill: CoverPaletteBackfill
    let lifecycleTask: Task<Void, Never>
  }

  static func makeLibraryCacheComposition(
    database: AppDatabase,
    paletteService: CoverPaletteService,
    coverImageClient: CoverImageClient,
    rssArtworkClient: RSSArtworkClient,
    artworkClient: ProviderArtworkClient,
    preparedArtworkScope: ArtworkAccountScope,
    rssPodcastReading: RSSPodcastReading,
    client: ABSClient,
    networkConditions: NetworkConditionsReducer,
    lifecycle: ScenePhaseAppLifecycle
  ) -> LibraryCacheComposition {
    let metadataBackfill = ItemMetadataBackfillCoordinator(database: database, client: client)
    // `AppEnvironment` is main-actor composition rather than a View, so it cannot read
    // `@Environment(\.displayScale)`, the source every cover request actually keys off. The
    // current trait context is the scene-aware UIKit source available during composition. It can
    // still be unresolved before a scene connects, so retain the conservative 3x fallback rather
    // than warming cache keys at a zero width.
    let traitScale = Double(UITraitCollection.current.displayScale)
    let scale = traitScale > 0 ? traitScale : 3
    let libraryThumbnailPixelWidth = ArtworkVariant.libraryThumbnail(
      displaySize: Double(WhirrMetric.minimumTouchTarget), displayScale: scale
    ).pixelWidth
    let highFidelityPixelWidth = ArtworkVariant.highFidelity(
      displaySize: Double(ItemDetailView.coverDisplaySize), displayScale: scale
    ).pixelWidth
    let podcastEpisodeThumbnailPixelWidth = ArtworkVariant.libraryThumbnail(
      displaySize: Double(PodcastEpisodeCardRowMetrics.coverSize), displayScale: scale
    ).pixelWidth
    // Shared with every palette surface, which extracts from these bytes (`CoverPaletteSource`).
    let homeCardPixelWidth = CoverPaletteSource.cardPixelWidth
    let coverCacheAllCoordinator = CoverCacheAllCoordinator(
      database: database,
      covers: coverImageClient,
      libraryThumbnailPixelWidth: libraryThumbnailPixelWidth,
      highFidelityPixelWidth: highFidelityPixelWidth,
      podcastEpisodeThumbnailPixelWidth: podcastEpisodeThumbnailPixelWidth,
      homeCardPixelWidth: homeCardPixelWidth,
      artworkScope: preparedArtworkScope,
      shapes: CoverShapeMeasurement(
        index: DetailArtwork.shapes, sizing: DetailArtwork.sizing(displayScale: scale),
        pixelSize: DetailArtwork.pixelSize),
      isConstrainedOrCellular: { networkConditions.isConstrainedOrCellular })
    let access = ArtworkCacheService(
      artwork: coverCacheAllCoordinator,
      // Both tiers that can still answer for a cover: the transport's compressed cache (which
      // owns the bytes under the directory) and the process-wide decoded cache.
      maintenance: DiskArtworkCacheMaintenance(
        directoryURLs: [
          CoverImageClient.disposableCacheDirectoryURL,
          RSSArtworkClient.disposableCacheDirectoryURL,
        ],
        clearing: [
          coverImageClient,
          RSSArtworkCacheClearing(client: rssArtworkClient),
          PreparedArtworkCache.shared,
          // The rows, then the in-memory palettes (`CoverPaletteService.clearCachedArtwork`).
          paletteService,
        ]))
    let followedShowArtworkWarmPass = FollowedShowArtworkWarmPass(
      reading: rssPodcastReading,
      artworkClient: artworkClient,
      service: paletteService,
      networkConditions: networkConditions,
      lifecycle: lifecycle)
    let coverPaletteBackfill = Self.makeCoverPaletteBackfill(
      database: database,
      service: paletteService,
      artworkScope: preparedArtworkScope,
      homeCardPixelWidth: homeCardPixelWidth,
      coverCacheAllCoordinator: coverCacheAllCoordinator,
      networkConditions: networkConditions,
      lifecycle: lifecycle)
    let lifecycleTransitions = lifecycle.transitions
    let isConstrainedOrCellular = { networkConditions.isConstrainedOrCellular }
    let lifecycleTask: Task<Void, Never> = Task {
      [weak coverCacheAllCoordinator, weak metadataBackfill] in
      // Before any detail screen builds a key: until the shapes are loaded every detail cover
      // resolves to the fallback width.
      await coverCacheAllCoordinator?.loadShapes()
      var metadataTask: Task<Void, Never>?
      defer { metadataTask?.cancel() }
      for await transition in lifecycleTransitions {
        guard let coverCacheAllCoordinator else { return }
        switch transition {
        case .background:
          await coverCacheAllCoordinator.setSuspended(true)
          metadataTask?.cancel()
        case .foreground:
          await coverCacheAllCoordinator.setSuspended(false)
          // The full metadata backfill is account-wide and light, one request per 50 books. It
          // runs beside the cover pass, not after it, so a long cover sweep cannot delay it. The
          // same Wi-Fi gate applies; SyncEngine's one-page backfill covers other networks.
          if isConstrainedOrCellular() == false,
            metadataTask == nil || metadataTask?.isCancelled == true
          {
            let previous = metadataTask
            metadataTask = Task { [weak metadataBackfill] in
              // A cancelled run must leave the coordinator before this one enters, or its
              // single-flight guard would make this call a no-op until the next foreground.
              await previous?.value
              await metadataBackfill?.backfillAll()
            }
          }
          Task { [weak coverCacheAllCoordinator] in
            _ = await coverCacheAllCoordinator?.topUp()
            // The sweep only deletes, so it runs whether or not the top-up was allowed to. A
            // finished pass has already swept; the day stamp keeps this to once a day otherwise.
            guard CoverSweepSchedule.isDue() else { return }
            if await coverCacheAllCoordinator?.sweep() != nil { CoverSweepSchedule.markRun() }
          }
        }
      }
    }

    return LibraryCacheComposition(
      metadataBackfill: metadataBackfill,
      access: access,
      followedShowArtworkWarmPass: followedShowArtworkWarmPass,
      coverPaletteBackfill: coverPaletteBackfill,
      lifecycleTask: lifecycleTask)
  }

  /// The home card key the cover pass caches for every eligible item, so the backfill extracts
  /// from bytes that pass has already put on disk. Not the library thumbnail, though that pass
  /// caches it too: at 44 points the server's WebP has smeared fine coloured line work into its
  /// black, and the colour picked there disagrees with the one every larger cover gives.
  private static func makeCoverPaletteBackfill(
    database: AppDatabase,
    service: CoverPaletteService,
    artworkScope: ArtworkAccountScope,
    homeCardPixelWidth: Int,
    coverCacheAllCoordinator: CoverCacheAllCoordinator,
    networkConditions: NetworkConditionsReducer,
    lifecycle: ScenePhaseAppLifecycle
  ) -> CoverPaletteBackfill {
    let accountDAO = AccountDAO(database: database)
    let itemDAO = ItemDAO(database: database)
    let coverPassCompletions = AsyncStream<Void> { continuation in
      let task = Task {
        for await progress in await coverCacheAllCoordinator.progress
        where progress.isRunning == false {
          continuation.yield(())
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    let backfill = CoverPaletteBackfill(
      items: {
        guard let accountID = try? await accountDAO.fetchAsync()?.id,
          let kinds = try? await itemDAO.serverItemKindsEligibleForArtworkAsync(
            accountId: accountID)
        else { return [] }
        return kinds.map { kind in
          CoverPaletteBackfill.Item(
            itemID: kind.serverItemId,
            key: ArtworkKey(
              accountScope: artworkScope,
              itemID: kind.serverItemId,
              variant: .homeCard(pixelWidth: homeCardPixelWidth),
              revision: ArtworkRevision(serverUpdatedAt: kind.serverUpdatedAt)))
        }
      },
      service: service,
      save: { item in await service.save(item.key) },
      lifecycle: lifecycle,
      conditions: networkConditions,
      coverPassCompletions: coverPassCompletions)
    backfill.trigger()
    return backfill
  }
}

/// Limits the foreground cover sweep to once a day.
nonisolated enum CoverSweepSchedule {
  static let defaultsKey = "coverCache.lastSweepAt"
  static let interval: TimeInterval = 24 * 60 * 60

  static func isDue(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
    guard let last = defaults.object(forKey: defaultsKey) as? Date else { return true }
    // A clock set backwards must not postpone the sweep indefinitely.
    return now.timeIntervalSince(last) >= interval || last > now
  }

  static func markRun(defaults: UserDefaults = .standard, now: Date = Date()) {
    defaults.set(now, forKey: defaultsKey)
  }
}
