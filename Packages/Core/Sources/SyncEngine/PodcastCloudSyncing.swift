import Foundation

/// The boundary between this target's podcast cloud orchestration and the platform sync engine.
/// CloudKit is a platform/network leaf: the only conformer that talks to it lives in the App
/// target, and no CloudKit type appears in any signature here. No Core target may import it;
/// `LayeringTests` enforces that.
///
/// Commands travel down through `PodcastCloudSyncing`; results travel up through
/// `PodcastCloudSyncHandling`, so the fake can drive event delivery without being an engine.
///
/// The policy (fetch-before-upload barrier, batch splitting and repair, conflict merge, zone-loss
/// recovery) lives in `PodcastCloudSyncCoordinator`.
public protocol PodcastCloudSyncing: Sendable {
  /// Constructs and starts the platform engine for one activation.
  ///
  /// Configuration is construction-time: a change of `automaticallySync` is a new activation and
  /// engine. Starting twice without an intervening `stop()` is a programming error.
  func start(_ activation: PodcastCloudActivation) async throws

  /// An explicit fetch. Reserved for user-requested Sync Now, first-enable and bootstrap,
  /// foreground recovery from a stale status, and the pre-restore barrier. Ordinary convergence is
  /// the engine's own schedule; do not poll.
  func fetchChanges() async throws

  /// An explicit send, for the same four occasions. The engine owns retry for `notAuthenticated`,
  /// temporary account unavailability, network errors, rate limiting and zone busy, so application
  /// code must not build a timer that fights its schedule.
  func sendChanges() async throws

  /// Tells the running engine about outbox rows it does not yet know of.
  ///
  /// `CKSyncEngine` learns of pending work only through its own pending set, so an outbox row
  /// written after construction (local mutation, or a merge re-enqueuing the winner) sits unsent
  /// until its name is added. Rehydration covers construction; this covers the rest. A name that
  /// needs no send costs one no-op batch, since `nextBatch` still decides what goes.
  func schedule(_ work: PodcastCloudPendingWork) async

  /// Deletes the whole `PodcastState` zone: the user's explicit "delete iCloud data", and the only
  /// path that removes cloud state wholesale. The result arrives as `.zoneDeletion`. Disabling
  /// sync, signing out and zone loss never call this.
  func deleteZone() async throws

  /// Fences in-flight work and tears the engine down. Never deletes cloud data: disabling sync is
  /// not deletion, and neither is signing out.
  func stop() async
}

/// Everything the platform engine needs to exist, as one value.
///
/// It carries a `PodcastCloudInstallationResolution` because an engine constructed before identity
/// resolution would stamp mutations with an identity the durable anchor does not agree with. The
/// resolution cannot be forged, so that ordering is a compile-time property of this type.
public struct PodcastCloudActivation: Sendable, Equatable {
  public let resolution: PodcastCloudInstallationResolution
  /// The `(container, environment, zone, iCloudUserRecordID, accountEpoch)` namespace every blob,
  /// send and callback is fenced by.
  public let fence: PodcastCloudAccountFence
  /// The persisted `CKSyncEngine.State.Serialization`, opaque to Core. It is a discardable cache:
  /// losing it causes a safe zone refetch, never user-state deletion.
  public let stateSerialization: Data?
  /// False for the bootstrap engine that holds the fetch-before-upload barrier closed, true for
  /// its single replacement once the barrier has been passed and durably applied.
  public let automaticallySync: Bool
  /// Whether this engine should create the zone; construction-time like `automaticallySync`. The
  /// default never creates: recreating a deleted zone is zone-loss recovery, not a startup
  /// accident.
  public let zone: PodcastCloudZoneIntent

  public init(
    resolution: PodcastCloudInstallationResolution,
    fence: PodcastCloudAccountFence,
    stateSerialization: Data?,
    automaticallySync: Bool,
    zone: PodcastCloudZoneIntent = .expectExisting
  ) {
    self.resolution = resolution
    self.fence = fence
    self.stateSerialization = stateSerialization
    self.automaticallySync = automaticallySync
    self.zone = zone
  }
}

/// What an engine construction does about the zone.
public enum PodcastCloudZoneIntent: String, Sendable, Equatable, CaseIterable {
  /// First enable after consent: queue a `.saveZone` before anything else.
  case create
  /// The zone was established in this namespace before. Its absence is zone loss, not a reason to
  /// recreate it.
  case expectExisting
}

/// The upward half of the boundary: what this target does with what the engine reports. The App
/// conformer of `PodcastCloudSyncing` translates platform events into these and calls through.
public protocol PodcastCloudSyncHandling: AnyObject, Sendable {
  /// Persist engine state updates before acknowledging them. Remote apply, system fields and
  /// fetch progress commit before an engine serialization checkpoint is accepted.
  func handle(_ event: PodcastCloudSyncEvent) async

  /// Supplies the next batch, or `nil` when there is nothing to send. That is also the answer
  /// while the bootstrap barrier is closed, while the account is signed out, and for any work
  /// belonging to a superseded namespace.
  func nextBatch(within limits: PodcastCloudBatchLimits) async -> PodcastCloudRecordBatch?

  /// Everything the durable outbox still owes the server, asked once per engine construction so
  /// the new engine's pending set can be seeded from it.
  ///
  /// The outbox is the source of truth and the engine's pending set a discardable cache, so the
  /// cache is rebuilt whenever recreated: an engine started from a lost, stale or rejected state
  /// serialization would otherwise think it has nothing to send and leave mutations in the outbox.
  /// Seeding cannot lose or duplicate data; a name no longer needing a send costs one no-op batch.
  func outstandingWork() async -> PodcastCloudPendingWork
}

/// The record names one engine construction should start out knowing about.
///
/// This mirrors `Persistence.PodcastCloudOutstandingWork`, the same information in its stored
/// shape, so the boundary declared here does not depend on the layer that stores the rows. The
/// mapping between them lives in `PodcastCloudOutboxRehydration.swift`.
public struct PodcastCloudPendingWork: Sendable, Equatable {
  public let saves: [String]
  public let deletions: [String]

  public static let none = PodcastCloudPendingWork(saves: [], deletions: [])

  public init(saves: [String], deletions: [String]) {
    self.saves = saves
    self.deletions = deletions
  }

  public var isEmpty: Bool { saves.isEmpty && deletions.isEmpty }
}

/// What the engine reported. Equatable so the deterministic matrix can assert on delivery order
/// rather than on an engine's internal state.
public enum PodcastCloudSyncEvent: Sendable, Equatable {
  /// A new opaque engine-state serialization to persist.
  case stateSerialization(Data)
  /// The result of a pending `.saveZone`. Zone creation is explicit work, never a side effect of
  /// the first record save.
  case zoneSave(succeeded: Bool)
  case sentRecords(PodcastCloudSentRecords)
  case fetchedChanges(PodcastCloudFetchedChanges)
  /// A fetch pass ended. A failed or cancelled fetch keeps the bootstrap barrier closed.
  case fetchCompleted(succeeded: Bool)
  /// Sign-in, sign-out or a switch. The engine is constructed whenever sync is enabled, even with
  /// an unavailable account, so this always has a listener.
  case accountChanged(PodcastCloudAccountChange)
  /// The zone is gone. `zoneNotFound` and `userDeletedZone` need distinct recovery, so they stay
  /// distinct here; neither ever triggers automatic recreation.
  case zoneLost(PodcastCloudZoneLoss)
  /// The result of `deleteZone()`.
  case zoneDeletion(succeeded: Bool)
  /// A send pass ended. Anything handed over in it that no `sentRecords` reported on is no longer
  /// in flight: a pass that fails as a whole reports no records, and without this the ledger would
  /// hold those sends back until the next engine construction.
  case sendPassEnded
  /// A fetch or send reported that the user's iCloud storage is full. Sync pauses and reports it;
  /// it never expires deletion markers to make room.
  case quotaExceeded
}

public enum PodcastCloudAccountChange: String, Sendable, Equatable, CaseIterable {
  case signIn, signOut, switchAccounts
}

public enum PodcastCloudZoneLoss: String, Sendable, Equatable, CaseIterable {
  case zoneNotFound, userDeletedZone
}

/// Why one record in a batch was not saved. Application code owns `serverRecordChanged`, malformed
/// records, zone policy and durable status; everything the engine retries by itself is absent.
public enum PodcastCloudSendFailure: String, Sendable, Equatable, CaseIterable {
  /// A conditional save lost to a newer server record. The returned record is the new base.
  case serverRecordChanged
  /// With `atomicByZone = true` one bad record fails the whole zone batch, so no sub-record of a
  /// batch carrying this may be acknowledged.
  case batchRequestFailed
  /// The request was too large. The record may be fine: split again, so this is a batch-level
  /// signal and only a batch of one proves `recordTooLarge`.
  case limitExceeded
  /// A single record the service or the local estimate proved too large to send.
  case recordTooLarge
  case quotaExceeded
  case malformedRecord
  case other
}

public struct PodcastCloudAcknowledgedRecord: Sendable, Equatable {
  public let recordName: String
  /// `CKRecord.encodeSystemFields` output, preserved through a `Data` boundary so the App adapter
  /// can reconstruct a conditional save. A hand-written change tag alone is not enough.
  public let systemFields: Data

  public init(recordName: String, systemFields: Data) {
    self.recordName = recordName
    self.systemFields = systemFields
  }
}

public struct PodcastCloudFailedRecord: Sendable, Equatable {
  public let recordName: String
  public let failure: PodcastCloudSendFailure
  /// The server's record as it now stands, present for `serverRecordChanged` so the merge has a
  /// base to rebase onto without a second fetch.
  public let serverRecord: PodcastCloudFetchedRecord?
  /// The service's suggested wait, for status display only. The engine owns retry scheduling and
  /// an application timer must not fight it, so nothing schedules work from this.
  public let retryAfter: TimeInterval?
  /// The service's own error code, for the log only. `failure` folds several codes into one case,
  /// and which one it was is the difference between a bad payload and an undeployed schema.
  public let serviceCode: Int?

  public init(
    recordName: String, failure: PodcastCloudSendFailure,
    serverRecord: PodcastCloudFetchedRecord? = nil, retryAfter: TimeInterval? = nil,
    serviceCode: Int? = nil
  ) {
    self.recordName = recordName
    self.failure = failure
    self.serverRecord = serverRecord
    self.retryAfter = retryAfter
    self.serviceCode = serviceCode
  }
}

public struct PodcastCloudSentRecords: Sendable, Equatable {
  public let saved: [PodcastCloudAcknowledgedRecord]
  public let failed: [PodcastCloudFailedRecord]
  /// Physical deletions the service confirmed. Without these an outbox deletion could never be
  /// acknowledged and would be re-sent at every engine construction.
  public let deleted: [String]
  public let failedDeletions: [PodcastCloudFailedRecord]

  public init(
    saved: [PodcastCloudAcknowledgedRecord], failed: [PodcastCloudFailedRecord],
    deleted: [String] = [], failedDeletions: [PodcastCloudFailedRecord] = []
  ) {
    self.saved = saved
    self.failed = failed
    self.deleted = deleted
    self.failedDeletions = failedDeletions
  }

  /// Every record the batch carried, which is the only batch size an event can report.
  public var recordCount: Int { saved.count + failed.count + deleted.count + failedDeletions.count }
}

/// A record as it arrived, already split into plaintext and encrypted compartments by the App
/// adapter, so a field the layout declares encrypted can be rejected if it turned up in the clear.
public struct PodcastCloudFetchedRecord: Sendable, Equatable {
  public let fields: PodcastCloudRecordFields
  public let systemFields: Data
  /// The record's server modification date. A remote stamp is admitted by comparing it with this
  /// date, and Core cannot unarchive `systemFields` to find it without importing CloudKit.
  public let serverModificationDate: Date?
  /// Field names carried in the clear: `allKeys()` minus `encryptedValues.allKeys()`, computed by
  /// the App adapter. `fields` is read through the layout so cannot show a stray plaintext field;
  /// this is the plaintext audit's only input. Defaults to the plaintext compartment of `fields`.
  public let plaintextFieldNames: Set<String>

  public init(
    fields: PodcastCloudRecordFields, systemFields: Data, serverModificationDate: Date? = nil,
    plaintextFieldNames: Set<String>? = nil
  ) {
    self.fields = fields
    self.systemFields = systemFields
    self.serverModificationDate = serverModificationDate
    self.plaintextFieldNames = plaintextFieldNames ?? Set(fields.plaintext.keys)
  }
}

public struct PodcastCloudFetchedChanges: Sendable, Equatable {
  public let modifications: [PodcastCloudFetchedRecord]
  public let deletions: [String]
  /// Records of a type this schema version does not declare, by name. They cannot be decoded, but
  /// dropping them silently would hide a newer device's data, so each is held and surfaces as
  /// `Sync needs attention` until a version that declares the type admits it.
  public let undeclaredRecordNames: [String]

  public init(
    modifications: [PodcastCloudFetchedRecord], deletions: [String],
    undeclaredRecordNames: [String] = []
  ) {
    self.modifications = modifications
    self.deletions = deletions
    self.undeclaredRecordNames = undeclaredRecordNames
  }
}

/// The application's batch ceilings, below CloudKit's documented 250-record request cap.
/// Estimates do not replace server validation: `limitExceeded` still splits again.
public struct PodcastCloudBatchLimits: Sendable, Equatable {
  public let maximumRecords: Int
  public let maximumBytes: Int
  public let maximumRecordBytes: Int

  /// The same numbers `PodcastCloudTransportStore.pendingSends` clamps to. Kept as one value so
  /// the two cannot drift apart unnoticed.
  public static let standard = PodcastCloudBatchLimits(
    maximumRecords: 200, maximumBytes: 1_048_576, maximumRecordBytes: 65_536)

  public init(maximumRecords: Int, maximumBytes: Int, maximumRecordBytes: Int) {
    self.maximumRecords = max(0, min(maximumRecords, Self.requestRecordCap))
    self.maximumBytes = max(0, maximumBytes)
    self.maximumRecordBytes = max(0, maximumRecordBytes)
  }

  /// CloudKit's documented per-request cap on saves plus deletes. An application ceiling may be
  /// lower, never higher.
  public static let requestRecordCap = 250
}

/// One batch to hand the engine. `atomicByZone` is absent: it is always true, and a parameter
/// would invite a caller to unset it.
public struct PodcastCloudRecordBatch: Sendable, Equatable {
  public let saves: [PodcastCloudRecordFields]
  /// Physical deletions only. Logical unfollow and Saved removal are saves carrying durable
  /// registers, so a tombstone never arrives here by inference from an empty payload.
  public let deletions: [String]
  /// The last known `encodeSystemFields` archive per saved record name. The App adapter rebuilds
  /// each `CKRecord` from its archive so the save is conditional on the change tag it carries; a
  /// record built without one would lose to the server on every save after its first.
  public let systemFields: [String: Data]

  public var isEmpty: Bool { saves.isEmpty && deletions.isEmpty }

  public init(
    saves: [PodcastCloudRecordFields], deletions: [String] = [], systemFields: [String: Data] = [:]
  ) {
    self.saves = saves
    self.deletions = deletions
    self.systemFields = systemFields
  }

  /// True when the batch respects a ceiling. The supplier checks this rather than the App adapter:
  /// the record count and the encoded payload size are both properties of the mapping, which this
  /// target owns.
  public func fits(_ limits: PodcastCloudBatchLimits, encodedBytes: (PodcastCloudRecordFields) -> Int) -> Bool {
    guard saves.count + deletions.count <= limits.maximumRecords else { return false }
    var total = 0
    for record in saves {
      let size = encodedBytes(record)
      guard size <= limits.maximumRecordBytes else { return false }
      total += size
    }
    return total <= limits.maximumBytes
  }
}
