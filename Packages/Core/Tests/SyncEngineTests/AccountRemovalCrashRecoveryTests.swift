import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Crash recovery at every stage boundary of the account-removal sequence. Each test drives an
/// `AccountRemovalCoordinator` ("launch A") until an injected crash right after some `Step`
/// commits, then builds a fresh one ("launch B") over the same on-disk database, token store and
/// file system (the discard-and-reopen idiom of `DownloadCrashRecoveryTests`) and proves
/// `resumeIfNeeded()` converges to completion whichever boundary the first attempt died at.
@Suite struct AccountRemovalCrashRecoveryTests {

  @Test func crashBeforeJournalCreationHasMadeNoDestructiveChange() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)

    // The process dies before `confirmRemoval()` is ever called (e.g. mid-warning-screen). A
    // fresh "launch B" coordinator observes nothing pending and nothing touched.
    let launchB = harness.makeCoordinator(database: database)
    #expect(try await launchB.isRemovalPending() == false)
    #expect(try harness.fetchAccountRow(database: database)?.id == accountId)
    #expect(try harness.hasStoredTokens())
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path))
  }

  @Test(arguments: AccountRemovalCoordinator.Step.allCases.filter { $0 != .journalCleared })
  func aCrashAtEveryStageBoundaryRelaunchesIntoRemovalPendingAndResumeConverges(
    crashAfter step: AccountRemovalCoordinator.Step
  ) async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)

    let launchA = harness.makeCoordinator(database: database)
    await launchA.setCrashAfterStepForTesting(step)
    await #expect(throws: AccountRemovalCoordinator.SimulatedCrashForTesting.self) {
      try await launchA.confirmRemoval()
    }

    // The real "relaunch" moment: a fresh coordinator, fresh `AppDatabase` instance reopened
    // over the same file (Keychain and the file system are still shared, as they
    // survive a real process death independently of anything held in memory).
    let reopenedDatabase = try harness.openDatabase()
    let launchB = harness.makeCoordinator(database: reopenedDatabase)

    #expect(
      try await launchB.isRemovalPending(),
      "login/setup must stay gated by the durable journal across the relaunch")

    try await launchB.resumeIfNeeded()

    #expect(try await launchB.isRemovalPending() == false, "resume converges and clears the journal")
    #expect(try harness.fetchAccountRow(database: reopenedDatabase) == nil)
    #expect(try harness.hasStoredTokens() == false)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path) == false)
    #expect(FileManager.default.fileExists(atPath: harness.coverCacheRootURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: harness.exportedDiagnosticsRootURL.path) == false)
    for root in harness.widgetRootURLs {
      #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }
  }

  /// A resumed run has no fresh account state to protect and may already have no credentials, so
  /// only the confirmed run drains the outbox.
  @Test func aResumedRemovalDoesNotDrainTheOutbox() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let drains = RemovalDrainCounter()

    let launchA = harness.makeCoordinator(
      database: database, drainOutboxBeforeRemoval: { drains.increment() })
    await launchA.setCrashAfterStepForTesting(.journalWritten)
    await #expect(throws: AccountRemovalCoordinator.SimulatedCrashForTesting.self) {
      try await launchA.confirmRemoval()
    }
    #expect(drains.value == 0)

    let reopenedDatabase = try harness.openDatabase()
    let launchB = harness.makeCoordinator(
      database: reopenedDatabase, drainOutboxBeforeRemoval: { drains.increment() })
    try await launchB.resumeIfNeeded()

    #expect(drains.value == 0)
    #expect(try harness.fetchAccountRow(database: reopenedDatabase) == nil)
  }

  /// A crash after the account row
  /// itself is already gone still resumes and clears the journal.
  @Test func crashAfterTheAccountRowIsAlreadyGoneStillResumesAndClearsTheJournal() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)

    let launchA = harness.makeCoordinator(database: database)
    await launchA.setCrashAfterStepForTesting(.dbRemovedAndVerified)
    await #expect(throws: AccountRemovalCoordinator.SimulatedCrashForTesting.self) {
      try await launchA.confirmRemoval()
    }
    #expect(try harness.fetchAccountRow(database: database) == nil, "the account row is already gone")

    let reopenedDatabase = try harness.openDatabase()
    let launchB = harness.makeCoordinator(database: reopenedDatabase)
    #expect(try await launchB.isRemovalPending())

    try await launchB.resumeIfNeeded()

    #expect(try await launchB.isRemovalPending() == false)
  }

  @Test func reRunningAfterCompletionIsANoOp() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let coordinator = harness.makeCoordinator(database: database)

    try await coordinator.confirmRemoval()
    #expect(try await coordinator.isRemovalPending() == false)

    // Neither entry point does anything the second time: no account, no journal.
    try await coordinator.resumeIfNeeded()
    try await coordinator.confirmRemoval()

    #expect(try await coordinator.isRemovalPending() == false)
    #expect(try harness.fetchAccountRow(database: database) == nil)
  }
}

private final class RemovalDrainCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
