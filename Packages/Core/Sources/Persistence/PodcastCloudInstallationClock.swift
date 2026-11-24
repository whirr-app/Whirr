import Foundation

public enum PodcastCloudInstallationError: Error, Equatable, Sendable {
  /// The durable anchor could not be read at all. Distinct from "readable and empty", which is the
  /// restore signature; collapsing the two would let a Keychain outage fabricate an identity.
  case anchorUnreadable
  /// No installation row exists. Only reachable from `advance`, which never mints.
  case absent
  /// The stored identity is not a UUID. The table's `length` check cannot catch this alone.
  case invalidRecord
  /// A write-back carrying an installation UUID the row no longer holds: a clock loaded before a
  /// re-mint trying to write itself back over the fresh identity.
  case identityChanged
  /// A write-back that moves `(physical, logical)` backwards outside a sanctioned clock repair.
  case nonMonotonicAdvance
}

/// The out-of-SQLite anchor, inverted into `Persistence` because this layer depends on GRDB alone
/// and cannot reach `SecItemClient`. The App supplies a Keychain implementation, mirroring how
/// `DeviceInstallIdentity` is supplied to the consent store.
public protocol PodcastCloudInstallationAnchor: Sendable {
  /// `.some(uuid)` when an anchor exists, `.none` when the store is readable and definitively
  /// empty, and a thrown error when readability itself is unknown. The three-way result is
  /// load-bearing: "readable and empty" is the restore signature, and an error must not imitate it.
  func read() throws -> UUID?
  func write(_ uuid: UUID) throws
}

/// The persisted whole of the hybrid logical clock.
public struct PodcastCloudClockFields: Sendable, Equatable {
  public let installationUUID: String
  public let physicalMilliseconds: Int64
  public let logicalCounter: Int64
  public let anchorServerMilliseconds: Int64?
  public let lastAdmittedPhysicalMilliseconds: Int64
  public let lastAdmittedLogicalCounter: Int64
  public let repairRequired: Bool

  public init(
    installationUUID: String, physicalMilliseconds: Int64 = 0, logicalCounter: Int64 = 0,
    anchorServerMilliseconds: Int64? = nil, lastAdmittedPhysicalMilliseconds: Int64 = 0,
    lastAdmittedLogicalCounter: Int64 = 0, repairRequired: Bool = false
  ) {
    self.installationUUID = installationUUID
    self.physicalMilliseconds = physicalMilliseconds
    self.logicalCounter = logicalCounter
    self.anchorServerMilliseconds = anchorServerMilliseconds
    self.lastAdmittedPhysicalMilliseconds = lastAdmittedPhysicalMilliseconds
    self.lastAdmittedLogicalCounter = lastAdmittedLogicalCounter
    self.repairRequired = repairRequired
  }
}

extension PodcastCloudClockFields {
  /// The identity as a `UUID`, or `nil` if the stored text is not one. Comparisons against the
  /// anchor go through this rather than through the string, so a difference in case can never read
  /// as a different installation.
  var installationIdentity: UUID? { UUID(uuidString: installationUUID) }

  /// Everything numeric carries forward across a re-mint; only the identity changes. Resetting the
  /// counter while keeping the physical time would sort the new identity's first stamp before
  /// stamps the source device already published at that time.
  func carryingForward(_ newIdentity: UUID) -> Self {
    Self(
      installationUUID: newIdentity.uuidString.lowercased(),
      physicalMilliseconds: physicalMilliseconds, logicalCounter: logicalCounter,
      anchorServerMilliseconds: anchorServerMilliseconds,
      lastAdmittedPhysicalMilliseconds: lastAdmittedPhysicalMilliseconds,
      lastAdmittedLogicalCounter: lastAdmittedLogicalCounter, repairRequired: repairRequired)
  }
}
