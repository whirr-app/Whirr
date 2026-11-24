import ABSApi
import Persistence
import SyncEngine

extension AppEnvironment {
  struct ItemDetailServicesComposition {
    let extrasAccess: ItemDetailExtrasService
    let ebookDelivery: EbookDeliveryService
    let historyAccess: ListeningHistoryCoordinator
    let listeningStatsAccess: ListeningStatsCoordinator
  }

  @MainActor
  static func makeItemDetailServicesComposition(
    database: AppDatabase,
    client: ABSClient
  ) -> ItemDetailServicesComposition {
    // Both are on-demand-only boundaries (no `ValueObservation` stream to subscribe to), so unlike
    // `syncEngine`/`playbackCoordinator` there is nothing to kick off beyond construction; each
    // call composes its own fetch against the account current at call time.
    let extrasAccess = ItemDetailExtrasService(database: database, client: client)
    // Account-keyed and lazily read, so it needs no lifecycle hook beyond construction here.
    let ebookDelivery = EbookDeliveryService(client: client, database: database)
    let historyAccess = ListeningHistoryCoordinator(client: client, database: database)
    // Account-keyed, on demand, never started from background.
    let listeningStatsAccess = ListeningStatsCoordinator(client: client, database: database)

    return ItemDetailServicesComposition(
      extrasAccess: extrasAccess,
      ebookDelivery: ebookDelivery,
      historyAccess: historyAccess,
      listeningStatsAccess: listeningStatsAccess)
  }
}
