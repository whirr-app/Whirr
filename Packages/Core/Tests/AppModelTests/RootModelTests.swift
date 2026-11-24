import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

/// `RootModel` decides, from already-tested boundaries only, when the account's default library is
/// known and the shell should navigate to it. Anything needing a concrete `ABSApi`/`Persistence`
/// type stays in the App target's `AppEnvironment`/`RootView`; this covers only what is reachable
/// through `AppDependencies`' protocol boundaries.
@MainActor
@Suite struct RootModelTests {
  // MARK: - Launch and gate

  @Test func startsRoutedToSetupWithNoLibraryModelsYet() {
    let model = RootModel(dependencies: makeDependencies())

    #expect(model.navigation.presentation == .setup)
    #expect(model.browseModel == nil)
    #expect(model.searchModel == nil)
  }

  /// Every input this decision needs is synchronous, so a configured authenticated launch resolves
  /// inside `init` and the first frame `RootView` paints is the shell. Deferring to `.task` would
  /// paint a frame of "Loading your library…" behind a scheduling hop and an async journal read,
  /// for a catalogue already on disk.
  @Test func authenticatedColdLaunchResolvesTheShellBeforeTheFirstFrame() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true

    let model = RootModel(
      dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { true }))

    #expect(model.navigation.presentation == .shell)
    #expect(model.browseModel != nil)
    #expect(model.searchModel != nil)
    #expect(model.navigation.section == .home)
  }

  /// Resolution in `init` must not bring a pull with it: the scene's first `.active` is the
  /// launch's traversal.
  @Test func resolvingInsideInitStillIssuesNoCataloguePullOfItsOwn() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = RootDiscoverySync()

    let model = RootModel(
      dependencies: makeDependencies(
        account: account, sync: sync, hasConfiguredIncludedLibrary: { true }))

    #expect(model.browseModel != nil)
    await awaitQuiescence("launch refresh requests") { "\(sync.refreshCount)" }
    #expect(sync.refreshCount == 0)
    #expect(sync.discoveryRefreshCount == 0)
  }

  /// The removal gate has to win that race. The journal is readable synchronously, so a removal
  /// that survived to this launch is known before anything resolves, and no frame of shell is
  /// painted over a mid-removal account.
  @Test func aSurvivingRemovalGatesTheLaunchBeforeAnythingResolves() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true

    let model = RootModel(
      dependencies: makeDependencies(
        account: account,
        hasConfiguredIncludedLibrary: { true },
        isRemovalPendingSynchronously: { true }))

    #expect(model.navigation.presentation == .removalPending)
    #expect(model.browseModel == nil)
    #expect(model.searchModel == nil)
  }

  /// An account still owing the setup-only selection step keeps its existing landing place: the
  /// synchronous resolution must not promote it into the shell.
  @Test func aPendingSelectionLaunchStillLandsInSetupWithNoModels() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true

    let model = RootModel(
      dependencies: makeDependencies(
        account: account,
        isLibrarySelectionPending: { true },
        hasConfiguredIncludedLibrary: { true }))

    #expect(model.navigation.presentation == .setup)
    #expect(model.browseModel == nil)
    #expect(model.searchModel == nil)
  }

  /// An authenticated account whose selection completed but whose libraries are all gone still
  /// reaches the recovery surface, and still does so without browse/search models.
  @Test func aConfiguredAccountWithNoIncludedLibraryStillReachesRecovery() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true

    let model = RootModel(
      dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { false }))

    #expect(model.navigation.presentation == .shell)
    #expect(model.isNoAccessibleLibrary)
    #expect(model.browseModel == nil)
  }

  @Test func authenticatedPendingSelectionPresentsSetupRatherThanRuntimeShell() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, isLibrarySelectionPending: { true },
        hasConfiguredIncludedLibrary: { true }))

    #expect(model.navigation.presentation == .setup)
    model.resolveLibraryIfAuthenticated()
    #expect(model.navigation.presentation == .setup)
    #expect(model.browseModel == nil)
    #expect(model.searchModel == nil)
  }

  @Test func resolveLibraryIfAuthenticatedIsANoOpWhileSignedOut() {
    let model = RootModel(dependencies: makeDependencies(hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()

    #expect(model.navigation.presentation == .setup)
  }

  @Test func resolveLibraryIfAuthenticatedShowsRecoveryWhenNoIncludedLibraryIsConfigured() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let model = RootModel(dependencies: makeDependencies(account: account))

    model.resolveLibraryIfAuthenticated()

    #expect(model.isNoAccessibleLibrary)
    #expect(model.navigation.presentation == .shell)
  }

  @Test func laterLibraryResolutionClearsTheNoAccessibleLibraryState() {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = LibrarySelectionBox(false)
    let model = RootModel(
      dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { selection.value }))

    model.resolveLibraryIfAuthenticated()
    #expect(model.isNoAccessibleLibrary)

    selection.value = true
    model.resolveLibraryIfAuthenticated()

    #expect(model.isNoAccessibleLibrary == false)
  }

  @Test func retryLibraryResolutionReconcilesDiscoveryBeforeResolvingAgain() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = RootDiscoverySync()
    let model = RootModel(
      dependencies: makeDependencies(account: account, sync: sync))

    model.resolveLibraryIfAuthenticated()
    await model.retryLibraryResolution()

    #expect(sync.discoveryRefreshCount == 1)
    #expect(model.isNoAccessibleLibrary)
  }

  @Test func retryLibraryResolutionPullsTheCatalogueOnceALibraryBecomesAvailable() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let sync = RootDiscoverySync()
    // The recovery screen's Retry: no included library when the model resolves, one by the time
    // discovery has reconciled. Discovery only reconciles the library list, so nothing else on
    // this path populates the catalogue and the shell would stay empty until the next foreground
    // transition.
    let hasLibrary = Locked(false)
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, sync: sync, hasConfiguredIncludedLibrary: { hasLibrary.value }))

    model.resolveLibraryIfAuthenticated()
    #expect(model.isNoAccessibleLibrary)

    hasLibrary.value = true
    await model.retryLibraryResolution()

    #expect(sync.discoveryRefreshCount == 1)
    #expect(model.isNoAccessibleLibrary == false)
    // `resolveLibraryIfAuthenticated` starts the pull as an unstructured task.
    #expect(await waitUntil("catalogue pull requested") { sync.refreshCount == 1 })
  }

  @Test func zeroLibraryLogoutKeepsRecoveryForAnUntypedPreRemovalFailure() async {
    struct PreRemovalFailure: Error {}
    let account = FakeAccountLifecycle()
    account.stubLogout(throwing: PreRemovalFailure())
    let model = RootModel(dependencies: makeDependencies(account: account))

    #expect(await model.confirmLogout() == false)
  }

  @Test func recoveryOffersLibraryChoiceOnlyWhenAnAccessibleExcludedLibraryRemains() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(snapshot: Self.selectionSnapshot(included: false))
    let model = RootModel(
      dependencies: makeDependencies(account: account, librarySelectionReading: selection))

    model.resolveLibraryIfAuthenticated()

    #expect(await waitUntil { model.canChooseLibraries })
    #expect(model.isNoAccessibleLibrary)

    selection.emit(LibrarySelectionSnapshot(mode: .selected, libraries: []))
    #expect(await waitUntil { model.canChooseLibraries == false })
    #expect(model.isNoAccessibleLibrary)
  }

  @Test func selectionObservationMovesALiveShellIntoAndOutOfRecovery() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let readiness = LibrarySelectionBox(true)
    let selection = RootSelectionAccess(snapshot: Self.selectionSnapshot(included: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { readiness.value }))

    model.resolveLibraryIfAuthenticated()
    #expect(model.browseModel != nil)

    readiness.value = false
    selection.emit(Self.selectionSnapshot(included: false))
    #expect(await waitUntil { model.isNoAccessibleLibrary })
    #expect(model.canChooseLibraries)

    readiness.value = true
    selection.emit(Self.selectionSnapshot(included: true))
    #expect(await waitUntil { model.isNoAccessibleLibrary == false })
    #expect(model.browseModel != nil, "restoration retains the existing shell models")
  }

  // MARK: - Launch recovery before accepting play

  @Test func launchRecoveryRunsBeforeTheSharedPlaybackModelAcceptsAPlayIntent() async {
    let playbackSync = FakePlaybackSyncing()
    playbackSync.holdRecoverOpenSessions()
    let model = RootModel(
      dependencies: makeDependencies(playbackSync: playbackSync, hasConfiguredIncludedLibrary: { true }))

    let task = Task { await model.playback.start(itemID: "item-1") }
    await playbackSync.waitForCalls { $0.contains(.recoverOpenSessions) }
    #expect(
      playbackSync.calls.contains(.startSession(itemID: "item-1", episodeID: nil)) == false,
      "start must wait for launch recovery")

    playbackSync.releaseRecoverOpenSessions()
    await task.value

    #expect(playbackSync.calls.first == .recoverOpenSessions)
  }

  // MARK: - Removal-pending launch gate

  @Test func launchWithNoRemovalPendingNeverGatesTheShell() async {
    let model = RootModel(dependencies: makeDependencies())

    await model.resumePendingRemovalIfNeeded()

    #expect(model.navigation.presentation == .setup)
  }

  /// A removal that survived to this launch gates the whole shell until the resume completes,
  /// then lands back at the ordinary setup gate, mirroring where a completed logout lands.
  @Test func aPendingRemovalGatesTheShellUntilResumeCompletes() async {
    let account = FakeAccountLifecycle()
    account.isRemovalPendingValue = true
    let model = RootModel(dependencies: makeDependencies(account: account))

    await model.resumePendingRemovalIfNeeded()

    #expect(model.navigation.presentation == .setup)
    #expect(account.resumeRemovalCallCount == 1)
  }

  /// A blocking, retryable failure: the gate must stay up rather than silently
  /// admitting the user, and a later call re-attempts the same idempotent resume.
  @Test func aFailedResumeLeavesTheShellGatedAndIsRetryable() async {
    let account = FakeAccountLifecycle()
    account.isRemovalPendingValue = true
    account.stubResumeRemoval(throwing: AccountRemovalError.deletionFailed)
    let model = RootModel(dependencies: makeDependencies(account: account))

    await model.resumePendingRemovalIfNeeded()
    #expect(model.navigation.presentation == .removalPending)

    account.stubResumeRemoval(throwing: nil)
    await model.resumePendingRemovalIfNeeded()

    #expect(model.navigation.presentation == .setup)
    #expect(account.resumeRemovalCallCount == 2)
  }

  /// The gate must block a concurrent/re-entrant library resolution from slipping the user into
  /// the shell while removal is still pending.
  @Test func resolveLibraryIfAuthenticatedNeverEntersTheShellWhileRemovalIsPending() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    account.isRemovalPendingValue = true
    account.stubResumeRemoval(throwing: AccountRemovalError.deletionFailed)
    let model = RootModel(dependencies: makeDependencies(account: account, hasConfiguredIncludedLibrary: { true }))

    await model.resumePendingRemovalIfNeeded()
    model.resolveLibraryIfAuthenticated()

    #expect(model.navigation.presentation == .removalPending)
  }
}
