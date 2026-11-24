import Foundation
import Testing
import WatchProtocol

@testable import Whirr

@Suite("Watch link record")
struct WatchLinkRecordTests {
  private let confirmedAt = Date(timeIntervalSinceReferenceDate: 5_000)

  private func scratch() -> (defaults: UserDefaults, suite: String) {
    let suite = "watch.link.record.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
  }

  @Test func aRecordRoundTripsItsHealthAndTime() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(accountIdentityHash: "account", health: .serverUnreachable, confirmedAt: confirmedAt)

    #expect(
      record.load(accountIdentityHash: "account")
        == WatchLinkRecord.Entry(
          accountIdentityHash: "account", health: .serverUnreachable, confirmedAt: confirmedAt))
  }

  @Test func aRecordWithoutHealthSurvivesTheRoundTrip() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(accountIdentityHash: "account", health: nil, confirmedAt: confirmedAt)

    let entry = record.load(accountIdentityHash: "account")
    #expect(entry?.health == nil)
    #expect(entry?.confirmedAt == confirmedAt)
  }

  @Test func anotherAccountCannotReadTheRecord() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt)

    #expect(record.load(accountIdentityHash: "another-account") == nil)
  }

  @Test func anOlderConfirmationDoesNotOverwriteANewerOne() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt)
    record.record(
      accountIdentityHash: "account", health: .signInRejected,
      confirmedAt: confirmedAt.addingTimeInterval(-60))

    #expect(record.load(accountIdentityHash: "account")?.health == .healthy)
    #expect(record.load(accountIdentityHash: "account")?.confirmedAt == confirmedAt)
  }

  @Test func aNewerConfirmationReplacesAnOlderOne() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt)
    record.record(
      accountIdentityHash: "account", health: .signInRejected,
      confirmedAt: confirmedAt.addingTimeInterval(60))

    #expect(record.load(accountIdentityHash: "account")?.health == .signInRejected)
    #expect(record.load(accountIdentityHash: "account")?.confirmedAt == confirmedAt.addingTimeInterval(60))
  }

  @Test func anotherAccountsConfirmationReplacesTheStoredOne() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt)
    record.record(
      accountIdentityHash: "another-account", health: .serverUnreachable, confirmedAt: confirmedAt)

    #expect(record.load(accountIdentityHash: "account") == nil)
    #expect(record.load(accountIdentityHash: "another-account")?.health == .serverUnreachable)
  }

  @Test func capabilitiesRoundTripAndAnOlderEntryDecodesWithoutThem() throws {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(
      accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt,
      capabilities: [WatchStatusCapability.enclosureFetch])

    #expect(
      record.load(accountIdentityHash: "account")?.capabilities
        == [WatchStatusCapability.enclosureFetch])

    // The shape stored before capabilities existed: the key is absent, not an empty set.
    let legacy = try JSONSerialization.data(withJSONObject: [
      "accountIdentityHash": "account",
      "health": "healthy",
      "confirmedAt": confirmedAt.timeIntervalSinceReferenceDate,
    ])
    defaults.set(legacy, forKey: "watch.link.record.v1")

    let decoded = try #require(record.load(accountIdentityHash: "account"))
    #expect(decoded.health == .healthy)
    #expect(decoded.confirmedAt == confirmedAt)
    #expect(decoded.capabilities == nil)
  }

  @Test func aProbeAnswerKeepsTheCapabilitiesTheLastReportStored() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(
      accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt,
      capabilities: [WatchStatusCapability.enclosureFetch])
    // A newer live probe or a completed setup knows the link but not the Watch app's build.
    record.record(
      accountIdentityHash: "account", health: .serverUnreachable,
      confirmedAt: confirmedAt.addingTimeInterval(60))

    let entry = record.load(accountIdentityHash: "account")
    #expect(entry?.health == .serverUnreachable)
    #expect(entry?.capabilities == [WatchStatusCapability.enclosureFetch])
  }

  @Test func anOlderReportStillStoresItsCapabilitiesUnderANewerProbe() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(
      accountIdentityHash: "account", health: .healthy,
      confirmedAt: confirmedAt.addingTimeInterval(60))
    record.record(
      accountIdentityHash: "account", health: .serverUnreachable, confirmedAt: confirmedAt,
      capabilities: [WatchStatusCapability.enclosureFetch])

    let entry = record.load(accountIdentityHash: "account")
    #expect(entry?.health == .healthy)
    #expect(entry?.confirmedAt == confirmedAt.addingTimeInterval(60))
    #expect(entry?.capabilities == [WatchStatusCapability.enclosureFetch])
  }

  @Test func aReportWithoutCapabilitiesReplacesTheStoredSet() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(
      accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt,
      capabilities: [WatchStatusCapability.enclosureFetch])
    // A report from an older Watch app carries an empty set; that is a real answer, not silence.
    record.record(
      accountIdentityHash: "account", health: .healthy,
      confirmedAt: confirmedAt.addingTimeInterval(60), capabilities: [])

    #expect(record.load(accountIdentityHash: "account")?.capabilities == Set<String>())
  }

  @Test func anotherAccountsCapabilitiesAreNotCarriedAcross() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(
      accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt,
      capabilities: [WatchStatusCapability.enclosureFetch])
    record.record(
      accountIdentityHash: "another-account", health: .healthy,
      confirmedAt: confirmedAt.addingTimeInterval(60))

    #expect(record.load(accountIdentityHash: "another-account")?.capabilities == nil)
  }

  @Test func clearingRemovesOnlyTheNamedAccountsRecord() {
    let (defaults, suite) = scratch()
    defer { defaults.removePersistentDomain(forName: suite) }
    let record = WatchLinkRecord(defaults: defaults)

    record.record(accountIdentityHash: "account", health: .healthy, confirmedAt: confirmedAt)
    record.clear(accountIdentityHash: "another-account")
    #expect(record.load(accountIdentityHash: "account")?.health == .healthy)

    record.clear(accountIdentityHash: "account")
    #expect(record.load(accountIdentityHash: "account") == nil)
    #expect(defaults.data(forKey: "watch.link.record.v1") == nil)
  }
}
