import Foundation
import WatchProtocol

/// Whether a status the Watch published may replace the confirmation this phone holds. One pure
/// decision, repeated here so the record's newest-wins rule and the report's
/// account and clock checks cannot drift apart.
enum WatchStatusReportAcceptance {
  /// A `checkedAt` further ahead than this is a clock the phone cannot trust.
  static let futureTolerance: TimeInterval = 5 * 60

  /// What one report says about the Watch's account, and the entry to record when it names this
  /// phone's. A rejection keeps only the fact that the Watch is signed out or on another
  /// account, for readiness; nothing else in such a report is used.
  enum Outcome: Equatable {
    /// The report names this phone's account. The entry is nil when it changes nothing recorded.
    case accepted(WatchLinkRecord.Entry?)
    /// The report carries no stamp: the Watch app is signed out.
    case signedOut
    /// The report is stamped with another account.
    case otherAccount
    /// The report names this account but its clock cannot be trusted, so it records nothing. Its
    /// stamp still says whose the Watch is.
    case ignored

    /// The account fact for readiness, which needs no trusted clock.
    var reportedAccount: WatchReportedAccount {
      switch self {
      case .accepted, .ignored: .matching
      case .signedOut: .signedOut
      case .otherAccount: .otherAccount
      }
    }
  }

  /// The entry to record, or nil when the report is ignored. A signed-out report has no stamp and
  /// is therefore ignored rather than clearing the record.
  static func acceptedEntry(
    for report: WatchStatusReport, accountIdentityHash: String,
    stored: WatchLinkRecord.Entry?, now: Date
  ) -> WatchLinkRecord.Entry? {
    guard
      case .accepted(let entry) = outcome(
        for: report, accountIdentityHash: accountIdentityHash, stored: stored, now: now)
    else { return nil }
    return entry
  }

  static func outcome(
    for report: WatchStatusReport, accountIdentityHash: String,
    stored: WatchLinkRecord.Entry?, now: Date
  ) -> Outcome {
    guard let stamp = report.accountStamp else { return .signedOut }
    guard stamp.accountIdentityHash == accountIdentityHash else { return .otherAccount }
    guard let checkedAt = report.checkedAt,
      checkedAt.timeIntervalSinceReferenceDate.isFinite,
      checkedAt <= now.addingTimeInterval(futureTolerance)
    else { return .ignored }
    if let stored, stored.confirmedAt >= checkedAt {
      // A newer probe answer keeps its confirmation, but only a report says what the Watch app
      // can do, and the Watch does not resend an unchanged report.
      guard report.capabilities != stored.capabilities else { return .accepted(nil) }
      return .accepted(
        WatchLinkRecord.Entry(
          accountIdentityHash: accountIdentityHash, health: stored.health,
          confirmedAt: stored.confirmedAt, capabilities: report.capabilities))
    }
    return .accepted(
      WatchLinkRecord.Entry(
        accountIdentityHash: accountIdentityHash, health: report.health, confirmedAt: checkedAt,
        capabilities: report.capabilities))
  }
}
