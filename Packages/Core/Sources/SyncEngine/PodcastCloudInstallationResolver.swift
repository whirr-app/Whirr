import Foundation
import Persistence

/// Proof that installation identity resolution ran and succeeded.
///
/// Only `PodcastCloudInstallationResolver` can construct one, and it is the only value carrying a
/// resolved clock. `PodcastCloudActivation` requires one, so a `PodcastCloudSyncing` conformer
/// cannot start where resolution was skipped, refused or never reached. It lives here, beside the
/// boundary that consumes it, since a token the boundary cannot name would constrain nothing.
public struct PodcastCloudInstallationResolution: Sendable, Equatable {
  /// The typed clock, ready for `PodcastCloudClock(state:)`. Resolution is the only producer of a
  /// clock state whose identity is known to match the durable anchor.
  public let clock: PodcastCloudClockState

  fileprivate init(clock: PodcastCloudClockState) {
    self.clock = clock
  }
}

/// What resolution can conclude. There is no `disabled` case: the consent gate lives in `AppModel`,
/// above this target, so a closed gate is a decision the caller makes instead of resolving.
public enum PodcastCloudInstallationOutcome: Sendable, Equatable {
  /// Mint, re-mint and adopt are indistinguishable. By the time the store returns, a re-mint has
  /// already applied the transport reset and outbox quarantine, so no caller has anything left to
  /// decide.
  case resolved(PodcastCloudInstallationResolution)
  /// The anchor could not be read, so nothing was written and the next launch re-reads it. Needs no
  /// repair control or Settings surface, because a refusal persists nothing.
  case refused
}

/// Step 2 of the launch sequence: after GRDB is open and migrated, and before any sync engine
/// exists.
public enum PodcastCloudInstallationResolver {
  /// Resolves the installation identity, minting or re-minting as needed.
  ///
  /// `anchorUnreadable` is the only error absorbed into `.refused`. Any other failure is a real
  /// persistence fault and is rethrown: as a refusal, a corrupt row would look like a transient
  /// Keychain outage and retry on every launch forever.
  public static func resolve(
    database: AppDatabase,
    anchor: any PodcastCloudInstallationAnchor
  ) async throws -> PodcastCloudInstallationOutcome {
    let store = PodcastCloudInstallationStore(database: database, anchor: anchor)
    do {
      guard let fields = try await store.clock(mint: true) else {
        // `clock(mint: true)` is documented never to return nil. Treating nil as a refusal rather
        // than force-unwrapping keeps a future contract change from crashing launch.
        return .refused
      }
      return .resolved(PodcastCloudInstallationResolution(clock: try PodcastCloudClockState(fields)))
    } catch PodcastCloudInstallationError.anchorUnreadable {
      return .refused
    }
  }
}
