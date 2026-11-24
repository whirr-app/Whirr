import ABSApi
import Foundation
import Persistence

// Values a save or removal flight carries between its stages. They live outside the
// coordinator's primary declaration because the save pipeline, the removal pipeline and the
// fence/durable-write layer all name them.

struct NativeEpisodeServerSaveFlight: Sendable {
  let fence: NativeEpisodeServerSaveAccountFence
  let command: NativeEpisodeServerSaveCommand
  let attempt: NativeEpisodeServerSaveAttemptRecord
}

struct NativeEpisodeServerSaveFlightKey: Hashable, Sendable {
  let feedID: Int64
  let episodeID: Int64
}

enum NativeEpisodeServerSaveFenceFailure: Error, Sendable {
  case accountReplaced
  case subscriptionsDisabled
  case episodeMissing
  case reader(NativeEpisodeServerSaveCommandReaderError)
  case persistence
}

enum NativeEpisodeServerSaveRequestPhase: Sendable {
  case create
  case enqueue
}

/// How much of the flight's world a continuation must re-verify before it may proceed.
///
/// The account fence is always checked. A request already sent is checkpointed under `.account`
/// only: a native toggle or pruned RSS row cannot erase that the server may have acted. Sending
/// a further request needs at least `.subscription`; one built from the RSS row needs `.source`,
/// which re-reads the command and fences on its identity.
enum NativeEpisodeServerSaveFenceScope: Sendable {
  case account
  case subscription
  case source
}

/// Where a rebuilt flight's command comes from: a save resumes from the live RSS row, while a
/// removal or reconciliation needs only the identity the attempt row already carries.
enum NativeEpisodeServerSaveFlightCommandSource: Sendable {
  case live
  case durableIdentity
}

/// A destination an earlier save in the same batch already resolved and used. A save handed
/// one skips the catalogue scan the resolver would otherwise repeat for every episode, and
/// reads `detail` for its preflight instead of fetching the show again. Only a batch builds
/// these, and only from an outcome that named the item.
struct NativeEpisodeServerSaveKnownShow: Sendable {
  let itemID: String
  let detail: NativeEpisodeServerSaveCoordinator.ItemDetailRead?
}

enum NativeEpisodeServerSaveConvergencePolicy: Sendable {
  case foreground
  case deferred
}
