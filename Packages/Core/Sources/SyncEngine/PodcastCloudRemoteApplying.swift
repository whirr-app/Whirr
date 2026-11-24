import Foundation
import GRDB
import Persistence

/// A fetched or conflict-winning record that passed admission: plaintext audit, schema, clock
/// admission against its server modification date, and the merge against this device's last
/// accepted stamp and pending send.
public struct PodcastCloudAdmittedRecord: Sendable, Equatable {
  public let fields: PodcastCloudRecordFields
  /// `nil` only for the unstamped keyring.
  public let stamp: PodcastCloudMutationStamp?
  public let receivedAt: Date

  public init(fields: PodcastCloudRecordFields, stamp: PodcastCloudMutationStamp?, receivedAt: Date) {
    self.fields = fields
    self.stamp = stamp
    self.receivedAt = receivedAt
  }
}

/// A remote episode state matched to one local episode.
public struct PodcastCloudResolvedEpisodeState: Sendable, Equatable {
  public let recordName: String
  public let episodeId: Int64
  public let state: PodcastCloudEpisodeState
  public let identity: PodcastCloudEpisodeIdentityFields

  public init(
    recordName: String, episodeId: Int64, state: PodcastCloudEpisodeState,
    identity: PodcastCloudEpisodeIdentityFields
  ) {
    self.recordName = recordName
    self.episodeId = episodeId
    self.state = state
    self.identity = identity
  }
}

/// A remote saved register matched to one local episode.
public struct PodcastCloudResolvedSaved: Sendable, Equatable {
  public let recordName: String
  public let episodeId: Int64
  public let register: PodcastCloudSavedRegister

  public init(recordName: String, episodeId: Int64, register: PodcastCloudSavedRegister) {
    self.recordName = recordName
    self.episodeId = episodeId
    self.register = register
  }
}

/// Where an admitted remote value lands locally.
///
/// Both methods run inside the coordinator's admission transaction with the accepted stamp and
/// system-field archive, so a crash cannot leave a value applied without its bookkeeping or
/// accepted without being applied.
///
/// `PodcastCloudHoldingApplier` projects nothing into follows, settings or playback.
public protocol PodcastCloudRemoteApplying: Sendable {
  func apply(_ record: PodcastCloudAdmittedRecord, in db: Database) throws

  /// Projects a resolved remote episode state onto its local episode. Returns `false` when this
  /// conformer does not project episode state yet, in which case the caller must keep the held
  /// copy: discarding it would lose remote history nothing has applied.
  func applyResolvedEpisodeState(_ resolved: PodcastCloudResolvedEpisodeState, in db: Database) throws
    -> Bool

  /// The saved-register counterpart of `applyResolvedEpisodeState`, with the same contract.
  func applyResolvedSaved(_ resolved: PodcastCloudResolvedSaved, in db: Database) throws -> Bool
}

extension PodcastCloudRemoteApplying {
  public func applyResolvedSaved(_ resolved: PodcastCloudResolvedSaved, in db: Database) throws -> Bool {
    false
  }
}

/// Holds every admitted episode state and saved register for later resolution against a feed.
/// Stamps and archives are recorded by the coordinator.
///
/// A state record's name carries keyed components (`v1.state.<sub>.<gen>.<digest>` under the
/// account's record-name key) and its body names no subscription. The held row stores the
/// components as received and resolution recomputes the keyed form of each local subscription,
/// generation and episode identity. No reverse mapping is needed at receive time, so a state
/// record may arrive before its subscription.
public struct PodcastCloudHoldingApplier: PodcastCloudRemoteApplying {
  public init() {}

  public func apply(_ record: PodcastCloudAdmittedRecord, in db: Database) throws {
    guard
      [PodcastCloudRecordLayout.episodeState.name, PodcastCloudRecordLayout.savedEpisode.name]
        .contains(record.fields.recordType),
      let components = PodcastCloudKeyedRecordName(record.fields.recordName),
      components.kind == "state" || components.kind == "saved"
    else { return }
    try PodcastCloudRegistryStore.holdUnresolved(
      in: db,
      PodcastCloudUnresolvedState(
        recordName: record.fields.recordName, subscriptionUUID: components.subscription,
        generationUUID: components.generation, episodeDigest: components.digest,
        payload: try PodcastCloudRecordPayload.encode(record.fields),
        receivedAt: record.receivedAt))
  }

  public func applyResolvedEpisodeState(
    _ resolved: PodcastCloudResolvedEpisodeState, in db: Database
  ) throws -> Bool {
    false
  }
}

/// The keyed components of a V1 child record name, split without being reversed.
public struct PodcastCloudKeyedRecordName: Sendable, Equatable {
  public let kind: String
  public let subscription: String
  public let generation: String
  public let digest: String

  /// `nil` for anything that is not `v1.<kind>.<keyed uuid>.<keyed uuid>.<keyed digest>`.
  public init?(_ recordName: String) {
    let parts = recordName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 5, parts[0] == PodcastCloudIdentity.version,
      ["state", "saved", "identity"].contains(parts[1]),
      UUID(uuidString: parts[2]) != nil, UUID(uuidString: parts[3]) != nil,
      parts[4].utf8.count == 64
    else { return nil }
    kind = parts[1]
    subscription = parts[2]
    generation = parts[3]
    digest = parts[4]
  }
}
