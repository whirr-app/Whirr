import Foundation
import Persistence

/// What podcast cloud sync is doing. Persisted as an opaque token on the transport row so a
/// relaunch shows the last state instead of pretending to be up to date.
public enum PodcastCloudSyncStatus: Sendable, Equatable {
  case off
  /// The fetch-before-upload barrier is closed and the bootstrap fetch has not yet succeeded.
  case bootstrapping
  case upToDate
  /// The engine is retrying on its own schedule. The date is the service's suggestion and is for
  /// display only (the app runs no retry timer of its own).
  case waiting(until: Date?)
  /// Signed out, or signed into an account this installation has not been enabled for.
  case accountUnavailable
  /// iCloud storage is full. Sends pause; deletion markers are never expired to make room.
  case quotaExceeded
  /// The cloud zone is gone. Never recovered automatically.
  case zoneLost(PodcastCloudZoneLoss)
  /// A fetched stamp showed the local clock far ahead of the server. Local stamping stops until
  /// an explicit repair, which republishes what was skipped.
  case clockRepairRequired
  /// At least one record is held: malformed, oversize, unmergeable, in the clear, or from a
  /// newer schema. Lasts as long as the current namespace has a held record.
  case needsAttention
  /// A step failed without holding anything: a zone save, an event that did not commit, a local
  /// edit that did not publish, or a start. It is retried, and the next clean fetch or send pass
  /// clears it once no local edit is still stuck.
  case interrupted

  var token: String {
    switch self {
    case .off: "off"
    case .bootstrapping: "bootstrapping"
    case .upToDate: "upToDate"
    case .waiting: "waiting"
    case .accountUnavailable: "accountUnavailable"
    case .quotaExceeded: "quotaExceeded"
    case .zoneLost(let loss): "zoneLost.\(loss.rawValue)"
    case .clockRepairRequired: "clockRepairRequired"
    case .needsAttention: "needsAttention"
    case .interrupted: "interrupted"
    }
  }

  var retryAfter: Date? {
    if case .waiting(let until) = self { return until }
    return nil
  }

  /// Reads a persisted token back. An unknown token (written by a newer build) reads as `nil`
  /// rather than being coerced into a state this build might misreport.
  public init?(token: String?, retryAfter: Date?) {
    guard let token else { return nil }
    switch token {
    case "off": self = .off
    case "bootstrapping": self = .bootstrapping
    case "upToDate": self = .upToDate
    case "waiting": self = .waiting(until: retryAfter)
    case "accountUnavailable": self = .accountUnavailable
    case "quotaExceeded": self = .quotaExceeded
    case "clockRepairRequired": self = .clockRepairRequired
    case "needsAttention": self = .needsAttention
    case "interrupted": self = .interrupted
    case _ where token.hasPrefix("zoneLost."):
      guard let loss = PodcastCloudZoneLoss(rawValue: String(token.dropFirst("zoneLost.".count)))
      else { return nil }
      self = .zoneLost(loss)
    default: return nil
    }
  }

  /// The persisted status of the current transport row, if any.
  public init?(_ state: PodcastCloudTransportState) {
    self.init(token: state.status, retryAfter: state.statusRetryAfter)
  }
}

/// Why a record is held. Stored as its raw value in `podcastCloudHeldRecord.category`; categories
/// only, never content (SECURITY.md: no titles, feed URLs, enclosure URLs or payloads).
public enum PodcastCloudHoldCategory: String, Sendable, Equatable, CaseIterable {
  /// An outbox payload that does not decode, or a service `invalidArguments`/constraint failure.
  case malformed
  /// Over the per-record ceiling, by estimate or proven by a batch of one.
  case recordTooLarge
  /// A conflict whose merge threw: a stamp collision, or a record type with no merge yet.
  case unmergeable
  /// A fetched record carried a field in the clear that the layout declares encrypted.
  case plaintextViolation
  /// A fetched record's stamp was quarantined against its server modification date.
  case quarantinedStamp
  /// A fetched record without a server modification date cannot be admitted.
  case missingServerDate
  /// A fetched record that did not decode against this schema version.
  case undecodable
  /// A fetched record of a type this schema version does not declare.
  case undeclaredType
}
