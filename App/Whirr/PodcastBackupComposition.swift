import AppModel
import Foundation
import Persistence
import SyncEngine

/// The Backups screen's services, built when the screen opens, over the process database the iCloud
/// Sync runtime also uses (and the running sync service when this build offers sync). The store
/// opens when a backup or restore runs, not when these are built: the automatic backup model is
/// created at first activation, which a scene can reach before the first unlock since boot. An
/// operation attempted then fails like any other; a later one works.
enum PodcastBackupComposition {
  @MainActor static func makeBackupModel() -> PodcastBackupModel {
    PodcastBackupModel(exporter: exporter)
  }

  /// One instance per process: the Backups screen shows it and `WhirrApp` runs it on activation.
  @MainActor static let autoBackupModel = PodcastAutoBackupModel(
    exporter: exporter, folder: PodcastBackupFolder(), store: UserDefaultsPodcastAutoBackupStore())

  @MainActor private static var exporter: any PodcastBackupExporting {
    StoreOpeningBackupExporter(
      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
  }

  @MainActor static func makeRestoreModel(podcastRefreshing: any PodcastRefreshing) -> PodcastBackupRestoreModel {
    PodcastBackupRestoreModel(
      service: StoreOpeningBackupRestoreService(),
      sync: PodcastCloudSyncComposition.syncController,
      learnedAdsRestored: { await AdSkipComposition.coordinator?.learnedAdsRestored() },
      refreshFeeds: { feedIDs in
        // A restored show has no catalogue until it refreshes, and the foreground pass reaches only
        // part of a large library, so each one is refreshed here.
        for feedID in feedIDs {
          _ = try? await podcastRefreshing.refresh(itemID: "\(PodcastSourceIdentity.reservedPrefix)\(feedID)")
        }
      })
  }
}

nonisolated struct PodcastBackupStoreUnavailable: Error {}

private nonisolated struct StoreOpeningBackupExporter: PodcastBackupExporting {
  let appBuild: String?

  func exportBackup(at date: Date) async throws -> PodcastBackupExport {
    guard let database = DatabaseHardware.sharedIfAvailable() else { throw PodcastBackupStoreUnavailable() }
    return try await NativePodcastBackupExporter(database: database, appBuild: appBuild).exportBackup(at: date)
  }
}

private nonisolated struct StoreOpeningBackupRestoreService: PodcastBackupRestoring {
  private func service() throws -> NativePodcastBackupRestoreService {
    guard let database = DatabaseHardware.sharedIfAvailable() else { throw PodcastBackupStoreUnavailable() }
    return NativePodcastBackupRestoreService(database: database)
  }

  func read(_ data: Data) async throws -> PodcastBackupDocument {
    try await service().read(data)
  }

  func preview(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome {
    try await service().preview(document)
  }

  func restore(_ document: PodcastBackupDocument) async throws -> NativePodcastRestoreOutcome {
    try await service().restore(document)
  }

  func previewSmartLists(_ document: PodcastBackupDocument) async throws -> Int {
    try await service().previewSmartLists(document)
  }

  func restoreSmartLists(_ document: PodcastBackupDocument) async throws
    -> PodcastSmartListsSnapshotCodec.RestoreOutcome?
  {
    try await service().restoreSmartLists(document)
  }
}
