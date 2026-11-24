import ABSApi
import Foundation
import Persistence

/// Converts the persisted account identity into the authenticated client identity used by
/// SyncEngine-owned coordinators. Account lookup remains with each coordinator; this is only the
/// shared record-to-client conversion.
extension AccountRecord {
  public var credentialTokenAccount: TokenAccount {
    get throws {
      try TokenAccount(
        credentialNamespace: credentialNamespace,
        userID: serverUserId)
    }
  }

  /// Foundation's lenient `URL(string:)` accepts strings with no host at all, so a corrupt
  /// address is rejected here rather than reaching a request builder.
  public var activeServerURL: URL {
    get throws {
      guard let url = URL(string: serverBaseURL), let host = url.host(), !host.isEmpty else {
        throw APIError.invalidServerConfiguration(.missingHost)
      }
      return url
    }
  }
}

/// Coordinators resolve their credentials through this so a corrupt account row (one whose
/// active address does not parse) still refuses server work with `.missingHost` even though the
/// namespace-keyed token account itself never reads the URL.
internal func tokenAccount(for accountRecord: AccountRecord) throws -> TokenAccount {
  _ = try accountRecord.activeServerURL
  return try accountRecord.credentialTokenAccount
}

/// Future-skew tolerance for client timestamps: five minutes.
internal let syncFutureSkewTolerance: TimeInterval = 5 * 60

/// Pure timestamp clamping policy. A missing observed offset means the account has no
/// server-clock observation yet, so both timestamps pass through unclamped.
internal struct ClampedTimestamps: Sendable {
  let startedAt: Date
  let updatedAt: Date
  let exceedsFutureTolerance: Bool
}

internal func clampSyncTimestamps(
  startedAt: Date,
  updatedAt: Date,
  now: Date,
  observedServerOffset: TimeInterval?
) -> ClampedTimestamps {
  guard let observedServerOffset else {
    return ClampedTimestamps(
      startedAt: startedAt, updatedAt: updatedAt, exceedsFutureTolerance: false)
  }

  let estimatedServerNow = now.addingTimeInterval(observedServerOffset)
  let ceiling = estimatedServerNow.addingTimeInterval(syncFutureSkewTolerance)
  let exceeds = startedAt > ceiling || updatedAt > ceiling
  return ClampedTimestamps(
    startedAt: min(startedAt, ceiling),
    updatedAt: min(updatedAt, ceiling),
    exceedsFutureTolerance: exceeds)
}
