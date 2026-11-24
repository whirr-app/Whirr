import Foundation
import GRDB
import Persistence
import Testing

@testable import Whirr

/// The bootstrap decides, before any graph is composed, whether the store can be used and what
/// it says about the account. A store that cannot open and an account that cannot be read are
/// different states from "no account".
@MainActor
@Suite("App bootstrap")
struct AppBootstrapTests {

  @Test("a store that cannot open before the first unlock is unavailable, not failed")
  func lockedStoreIsUnavailable() {
    let outcome = AppBootstrap.run(database: { nil }, isProtectedDataAvailable: { false })

    guard case .storageUnavailable = outcome else {
      Issue.record("expected storageUnavailable, got \(outcome)")
      return
    }
  }

  @Test("a store that cannot open while protected data is readable is a database failure")
  func unopenableStoreIsAFailure() {
    let outcome = AppBootstrap.run(database: { nil }, isProtectedDataAvailable: { true })

    guard case .failed(.databaseUnopenable) = outcome else {
      Issue.record("expected databaseUnopenable, got \(outcome)")
      return
    }
  }

  @Test("an empty store is ready with no account and no pending removal")
  func emptyStoreIsReadyWithoutAccount() throws {
    let database = try AppDatabase.inMemory()

    let outcome = AppBootstrap.run(database: { database }, isProtectedDataAvailable: { true })

    guard case .ready(let launch) = outcome else {
      Issue.record("expected ready, got \(outcome)")
      return
    }
    #expect(launch.accountState.account == nil)
    #expect(launch.accountState.removalIsPending == false)
  }

  @Test("a durable removal journal is reported as a pending removal")
  func pendingRemovalIsReported() throws {
    let database = try AppDatabase.inMemory()
    try AccountRemovalJournalStore(database: database).create(
      AccountRemovalJournalRecord(
        serverBaseURL: "https://pending-removal.invalid",
        serverUserId: "pending-removal-user",
        accountRowId: 1,
        downloadsRootRelativePath: "Downloads",
        createdAt: Date()
      ))

    let outcome = AppBootstrap.run(database: { database }, isProtectedDataAvailable: { true })

    guard case .ready(let launch) = outcome else {
      Issue.record("expected ready, got \(outcome)")
      return
    }
    #expect(launch.accountState.removalIsPending)
  }

  @Test("an account that cannot be read is a failure, never 'no account'")
  func unreadableAccountIsAFailure() throws {
    let database = try AppDatabase.inMemory()
    try database.write { try $0.execute(sql: "ALTER TABLE account RENAME TO accountMislaid") }

    let outcome = AppBootstrap.run(database: { database }, isProtectedDataAvailable: { true })

    guard case .failed(.accountUnreadable) = outcome else {
      Issue.record("expected accountUnreadable, got \(outcome)")
      return
    }
  }

  @Test("a removal journal that cannot be read is a failure, never 'no removal'")
  func unreadableRemovalJournalIsAFailure() throws {
    let database = try AppDatabase.inMemory()
    try database.write {
      try $0.execute(sql: "ALTER TABLE accountRemovalJournal RENAME TO accountRemovalJournalMislaid")
    }

    let outcome = AppBootstrap.run(database: { database }, isProtectedDataAvailable: { true })

    guard case .failed(.accountUnreadable) = outcome else {
      Issue.record("expected accountUnreadable, got \(outcome)")
      return
    }
  }
}

@MainActor
@Suite("Launch unavailable presentation")
struct LaunchUnavailablePresentationTests {

  @Test("only a runtime without a graph has something to explain")
  func presentsOnlyUnavailableStates() {
    #expect(LaunchUnavailablePresentation(.starting) == nil)
    #expect(LaunchUnavailablePresentation(.ready) == nil)
    #expect(LaunchUnavailablePresentation(.storageUnavailable) != nil)
  }

  @Test("a locked store, an unopenable store and an unreadable account read differently")
  func unavailableStatesAreDistinct() {
    let states: [AppRuntime.Readiness] = [
      .storageUnavailable, .failed(.databaseUnopenable), .failed(.accountUnreadable),
    ]
    let titles = states.compactMap { LaunchUnavailablePresentation($0)?.title.key }

    #expect(Set(titles).count == states.count)
  }
}
