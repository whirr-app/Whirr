import AppModel
import Foundation
import Persistence
import SyncEngine

/// The three ways the launch sequence can end. The two failure shapes are distinct because they
/// differ in what the next launch should do, not merely in how they read.
enum PodcastCloudLaunchOutcome: Sendable, Equatable {
  /// The consent gate is closed. Nothing was read and nothing was minted: a listener who has not
  /// enabled iCloud sync gets no installation row and no Keychain item.
  case disabled
  case resolved(PodcastCloudInstallationResolution)
  /// The anchor could not be read, so nothing was written and the next launch re-reads it.
  case refused
}

/// Step 2 of the launch sequence: after GRDB is open and migrated, and strictly before any sync
/// engine exists.
///
/// The resolution lives in `SyncEngine`, where `PodcastCloudSyncing` can require it. What stays
/// here is what Core cannot see: the consent gate is an `AppModel` value above `SyncEngine`, so a
/// closed gate is decided here, not returned by the resolver. Until the listener consents,
/// `allowsCloudWork` is false and every launch resolves to `.disabled` (ADR 0009's default-off).
enum PodcastCloudLaunchSequence {
  /// A closed gate returns `.disabled` without touching the Keychain or the database. Minting an
  /// identity for a listener who never opted in would write a row and a Keychain item for a
  /// feature they do not use.
  static func resolve(
    database: AppDatabase,
    anchor: any PodcastCloudInstallationAnchor,
    gate: PodcastCloudSyncGate
  ) async throws -> PodcastCloudLaunchOutcome {
    guard gate.allowsCloudWork else { return .disabled }
    switch try await PodcastCloudInstallationResolver.resolve(database: database, anchor: anchor) {
    case .resolved(let resolution): return .resolved(resolution)
    case .refused: return .refused
    }
  }

  /// The production entry point, run once per process by `PodcastCloudSyncLaunch` after the
  /// database has opened; inert until the gate opens. The database is a parameter because a launch
  /// before the first unlock must not open it here. A thrown persistence fault is swallowed here:
  /// launch must not fail over a feature nobody enabled. The runtime resolves again when it starts
  /// a session and reports a failure there as `Sync needs attention`.
  @discardableResult
  static func resolveForLaunch(database: AppDatabase) async -> PodcastCloudLaunchOutcome {
    do {
      return try await resolve(
        database: database,
        anchor: PodcastCloudSyncComposition.installationAnchor,
        gate: PodcastCloudSyncComposition.gate)
    } catch {
      return .refused
    }
  }
}
