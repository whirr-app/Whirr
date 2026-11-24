import Foundation
import Testing
import WatchProtocol

@testable import Whirr

@Suite("Watch status report acceptance")
struct WatchStatusReportAcceptanceTests {
  private let now = Date(timeIntervalSinceReferenceDate: 10_000)
  private let stamp = try! WatchAccountStamp(
    accountIdentityHash: "account", serverIdentityHash: "server")

  private func report(
    _ checkedAt: Date?, health: WatchLinkHealth? = .healthy,
    stamp: WatchAccountStamp? = nil, reportedAt: Date? = nil,
    capabilities: Set<String> = []
  ) throws -> WatchStatusReport {
    try WatchStatusReport(
      accountStamp: stamp ?? self.stamp, health: health, checkedAt: checkedAt,
      reportedAt: reportedAt ?? now, capabilities: capabilities)
  }

  private func entry(
    _ confirmedAt: Date, health: WatchLinkHealth? = .healthy,
    capabilities: Set<String>? = nil
  ) -> WatchLinkRecord.Entry {
    WatchLinkRecord.Entry(
      accountIdentityHash: "account", health: health, confirmedAt: confirmedAt,
      capabilities: capabilities)
  }

  /// A report says whose the Watch is even when it records nothing, so readiness can
  /// tell "set up Whirr on your Watch" from "open Whirr on your Watch".
  @Test func theOutcomeSaysWhoseTheWatchIs() throws {
    let other = try WatchAccountStamp(accountIdentityHash: "another-account", serverIdentityHash: "server")
    let signedOut = try WatchStatusReport(accountStamp: nil, reportedAt: now)
    let outcome = { (report: WatchStatusReport) in
      WatchStatusReportAcceptance.outcome(for: report, accountIdentityHash: "account", stored: nil, now: now)
    }

    #expect(outcome(signedOut) == .signedOut)
    #expect(outcome(signedOut).reportedAccount == .signedOut)
    #expect(outcome(try report(now.addingTimeInterval(-1), stamp: other)) == .otherAccount)
    #expect(outcome(try report(now.addingTimeInterval(-1), stamp: other)).reportedAccount == .otherAccount)
    #expect(outcome(try report(nil)) == .ignored)
    #expect(outcome(try report(nil)).reportedAccount == .matching, "the stamp needs no trusted clock")
    #expect(outcome(try report(now.addingTimeInterval(-1))).reportedAccount == .matching)
  }

  @Test func theNewestCheckedReportForThisAccountIsRecorded() throws {
    let checkedAt = now.addingTimeInterval(-120)

    let accepted = WatchStatusReportAcceptance.acceptedEntry(
      for: try report(checkedAt, health: .serverUnreachable), accountIdentityHash: "account",
      stored: entry(now.addingTimeInterval(-300)), now: now)

    #expect(accepted?.confirmedAt == checkedAt)
    #expect(accepted?.health == .serverUnreachable)
    #expect(accepted?.accountIdentityHash == "account")
  }

  @Test func aReportWithNoStoredEntryStillNeedsACheckTime() throws {
    let checkedAt = now.addingTimeInterval(-30)

    #expect(
      WatchStatusReportAcceptance.acceptedEntry(
        for: try report(checkedAt), accountIdentityHash: "account", stored: nil, now: now)?
        .confirmedAt == checkedAt)
    #expect(
      WatchStatusReportAcceptance.acceptedEntry(
        for: try report(nil), accountIdentityHash: "account", stored: nil, now: now) == nil)
  }

  @Test func anotherAccountsReportIsIgnored() throws {
    let other = try WatchAccountStamp(
      accountIdentityHash: "another-account", serverIdentityHash: "server")
    let signedOut = try report(nil)

    #expect(
      WatchStatusReportAcceptance.acceptedEntry(
        for: try report(now.addingTimeInterval(-1), stamp: other),
        accountIdentityHash: "account", stored: nil, now: now) == nil)
    #expect(
      WatchStatusReportAcceptance.acceptedEntry(
        for: signedOut, accountIdentityHash: "account", stored: entry(now.addingTimeInterval(-600)), now: now)
        == nil)
  }

  @Test func aCheckTimeOverFiveMinutesAheadIsIgnored() throws {
    #expect(
      WatchStatusReportAcceptance.acceptedEntry(
        for: try report(now.addingTimeInterval(WatchStatusReportAcceptance.futureTolerance + 1)),
        accountIdentityHash: "account", stored: nil, now: now) == nil)
    #expect(
      WatchStatusReportAcceptance.acceptedEntry(
        for: try report(now.addingTimeInterval(WatchStatusReportAcceptance.futureTolerance)),
        accountIdentityHash: "account", stored: nil, now: now) != nil)
  }

  @Test func anOlderOrEqualReportDoesNotReplaceTheStoredOne() throws {
    let stored = entry(now.addingTimeInterval(-60), health: .healthy, capabilities: [])

    for checkedAt in [now.addingTimeInterval(-60), now.addingTimeInterval(-61)] {
      #expect(
        WatchStatusReportAcceptance.acceptedEntry(
          for: try report(checkedAt, health: .signInRejected), accountIdentityHash: "account",
          stored: stored, now: now) == nil)
    }
  }

  @Test func aNewerReportReplacesTheStoredHealth() throws {
    let stored = entry(now.addingTimeInterval(-300), health: .healthy)
    let checkedAt = now.addingTimeInterval(-1)

    let accepted = WatchStatusReportAcceptance.acceptedEntry(
      for: try report(checkedAt, health: .signInRejected), accountIdentityHash: "account",
      stored: stored, now: now)

    #expect(accepted == entry(checkedAt, health: .signInRejected, capabilities: []))
  }

  @Test func anOlderReportStillUpdatesCapabilitiesButNotTheConfirmation() throws {
    let stored = entry(now.addingTimeInterval(-60), health: .healthy)
    let capabilities: Set<String> = [WatchStatusCapability.enclosureFetch]

    let accepted = WatchStatusReportAcceptance.acceptedEntry(
      for: try report(
        now.addingTimeInterval(-120), health: .signInRejected, capabilities: capabilities),
      accountIdentityHash: "account", stored: stored, now: now)

    #expect(accepted == entry(now.addingTimeInterval(-60), health: .healthy, capabilities: capabilities))
  }

  @Test func anAcceptedReportCarriesTheWatchsCapabilities() throws {
    let capabilities: Set<String> = [WatchStatusCapability.enclosureFetch]

    let accepted = WatchStatusReportAcceptance.acceptedEntry(
      for: try report(now.addingTimeInterval(-1), capabilities: capabilities),
      accountIdentityHash: "account", stored: nil, now: now)

    #expect(accepted?.capabilities == capabilities)
  }
}
