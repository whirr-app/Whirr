import AppModel
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// The launch-sequence half of the installation identity work. The store's resolution table is
/// covered by `PodcastCloudInstallationStoreTests` in `Persistence` and the resolver itself by
/// `PodcastCloudSyncBoundaryTests` in `SyncEngine`, so these cover only what the App target adds:
/// the consent gate, and the fact that a closed gate resolves nothing at all.
@Suite("Podcast cloud launch sequence")
struct PodcastCloudLaunchSequenceTests {
  private struct StubConsent: PodcastCloudSyncConsentReading {
    let consented: Bool
    func hasConsent() -> Bool { consented }
    func observeConsent() -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
  }

  /// `destinationReady` is forced true throughout, so these tests exercise resolution whatever the
  /// build's own readiness is.
  private func gate(consented: Bool) -> PodcastCloudSyncGate {
    PodcastCloudSyncGate(consent: StubConsent(consented: consented), destinationReady: true)
  }

  private func resolution(from outcome: PodcastCloudLaunchOutcome)
    -> PodcastCloudInstallationResolution?
  {
    guard case .resolved(let resolution) = outcome else { return nil }
    return resolution
  }

  @Test("a closed gate mints nothing and does not even read the anchor")
  func closedGateTouchesNothing() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()

    let outcome = try await PodcastCloudLaunchSequence.resolve(
      database: database, anchor: anchor, gate: gate(consented: false))

    #expect(outcome == .disabled)
    #expect(anchor.reads == 0)
    #expect(anchor.value == nil)
    // No row, so a later first-enable still resolves as a first run rather than an adoption.
    let store = PodcastCloudInstallationStore(database: database, anchor: anchor)
    #expect(try await store.clock(mint: false) == nil)
  }

  @Test("a first run mints an identity and anchors it")
  func firstRunMints() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()

    let outcome = try await PodcastCloudLaunchSequence.resolve(
      database: database, anchor: anchor, gate: gate(consented: true))

    let resolved = try #require(resolution(from: outcome))
    #expect(anchor.value == resolved.clock.installationUUID)
  }

  @Test("an ordinary relaunch adopts the same identity rather than minting a second one")
  func relaunchAdopts() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()

    let first = try #require(
      resolution(
        from: try await PodcastCloudLaunchSequence.resolve(
          database: database, anchor: anchor, gate: gate(consented: true))))
    let second = try #require(
      resolution(
        from: try await PodcastCloudLaunchSequence.resolve(
          database: database, anchor: anchor, gate: gate(consented: true))))

    #expect(first.clock.installationUUID == second.clock.installationUUID)
  }

  @Test("the restore signature re-mints the identity and carries the numeric state forward")
  func restoreReMintsButKeepsCounters() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor()
    let store = PodcastCloudInstallationStore(database: database, anchor: anchor)

    let original = try #require(
      resolution(
        from: try await PodcastCloudLaunchSequence.resolve(
          database: database, anchor: anchor, gate: gate(consented: true))))

    // Put the clock somewhere non-trivial, so a reset would be visible rather than indistinguish-
    // able from a fresh mint. `repairRequired` is included because clearing it on re-mint
    // would launder a quarantine through a restore.
    try await store.advance(
      PodcastCloudClockFields(
        installationUUID: original.clock.installationUUID.uuidString.lowercased(),
        physicalMilliseconds: 5_000,
        logicalCounter: 7,
        anchorServerMilliseconds: 4_000,
        lastAdmittedPhysicalMilliseconds: 3_000,
        lastAdmittedLogicalCounter: 2,
        repairRequired: true))

    anchor.clear()

    let reMinted = try #require(
      resolution(
        from: try await PodcastCloudLaunchSequence.resolve(
          database: database, anchor: anchor, gate: gate(consented: true))))

    #expect(reMinted.clock.installationUUID != original.clock.installationUUID)
    #expect(anchor.value == reMinted.clock.installationUUID)
    #expect(reMinted.clock.physicalMilliseconds == 5_000)
    #expect(reMinted.clock.logicalCounter == 7)
    #expect(reMinted.clock.anchorServerMilliseconds == 4_000)
    #expect(reMinted.clock.lastAdmittedPhysicalMilliseconds == 3_000)
    #expect(reMinted.clock.lastAdmittedLogicalCounter == 2)
    #expect(reMinted.clock.repairRequired)
  }

  @Test("an unreadable anchor refuses, persists nothing, and resolves on the next launch")
  func unreadableAnchorRefusesWithoutPersisting() async throws {
    let database = try AppDatabase.inMemory()
    let anchor = FakePodcastCloudInstallationAnchor(readsFail: true)

    let refused = try await PodcastCloudLaunchSequence.resolve(
      database: database, anchor: anchor, gate: gate(consented: true))
    #expect(refused == .refused)
    #expect(anchor.value == nil)

    // The exit path from a transient Keychain outage: nothing was written, so the next launch is
    // still a first run and mints normally, so the outage needs no repair control.
    anchor.setReadsFail(false)
    let resolved = try #require(
      resolution(
        from: try await PodcastCloudLaunchSequence.resolve(
          database: database, anchor: anchor, gate: gate(consented: true))))
    #expect(anchor.value == resolved.clock.installationUUID)
  }

  @Test("neither failure path yields a resolution, so no engine can be built from one")
  func failurePathsCarryNoResolution() async throws {
    let database = try AppDatabase.inMemory()

    let disabled = try await PodcastCloudLaunchSequence.resolve(
      database: database, anchor: FakePodcastCloudInstallationAnchor(), gate: gate(consented: false))
    let refused = try await PodcastCloudLaunchSequence.resolve(
      database: database, anchor: FakePodcastCloudInstallationAnchor(readsFail: true), gate: gate(consented: true))

    #expect(resolution(from: disabled) == nil)
    #expect(resolution(from: refused) == nil)
  }

  @Test("the sync namespace names the environment each configuration's entitlements select")
  func destinationEnvironmentFollowsTheBuildConfiguration() {
    // Whirr.entitlements is Production and WhirrDebug.entitlements Development (ReleaseAuditTests);
    // the namespace must agree, so moving an install between them re-runs the bootstrap barrier.
    #expect(PodcastCloudSyncComposition.destination(debugBuild: true).environment == "development")
    #expect(PodcastCloudSyncComposition.destination(debugBuild: false).environment == "production")
    #expect(PodcastCloudSyncComposition.destination.environment == "development")  // tests run Debug
  }

  @Test("the build offers sync, and launch is inert without consent")
  func productionEntryIsGated() async throws {
    // On the dedicated test simulator no listener has consented, so the real gate is closed and
    // launch neither mints nor touches the Keychain.
    #expect(PodcastCloudSyncComposition.destinationReady)
    #expect(PodcastCloudSyncComposition.gate.allowsCloudWork == false)
    #expect(await PodcastCloudLaunchSequence.resolveForLaunch(database: try AppDatabase.inMemory()) == .disabled)
  }
}
