import ABSApi
import CoreSupport
import Foundation
import Persistence
import Synchronization

/// Errors `AccountRemovalCoordinator.confirmRemoval()`/`resumeIfNeeded()` raise. A server logout
/// error is logged and swallowed after local removal; a credential-wipe `LogoutError` becomes a
/// blocking case below before any data is destroyed. Every error reaching AppModel is blocking.
public enum AccountRemovalError: Error, Sendable, Equatable {
  /// Blocking and retryable: a destructive local step (file removal or the verification sweep)
  /// failed. The journal stays, so calling `confirmRemoval()`/`resumeIfNeeded()` again re-runs the
  /// sequence without trusting partial progress.
  case deletionFailed
  /// A token or server-scoped custom-header credential could not be erased. The sequence stops
  /// before removing files or the account row, retaining the journal for a retry with identity.
  case credentialClearFailed
}

/// Full account-removal workflow and crash recovery.
///
/// The durable, non-account-owned journal (`AccountRemovalJournalRecord`) keeps the sequence
/// resumable across a crash, even once the account row is gone.
///
/// No stage is persisted: after a crash or failed step the whole sequence re-runs from the top
/// against the journal's recorded identity, and every step is safe to repeat. `Step` and the
/// crash-injection hooks exist only so `AccountRemovalCrashRecoveryTests` can prove convergence at
/// each boundary.
public actor AccountRemovalCoordinator {
  private static let logger = CoreLogging.logger(category: "account-removal")

  /// Every durable boundary the sequence crosses, in order.
  public enum Step: Sendable, Equatable, CaseIterable {
    case journalWritten
    case intentsStopped
    case quiesced
    case transfersCancelled
    case serverLogoutAttempted
    case filesRemoved
    case dbRemovedAndVerified
    case journalCleared
  }

  /// Test-only marker thrown by the crash-injection hook to abort the sequence immediately after
  /// `Step` durably commits. The caller then constructs a fresh `AccountRemovalCoordinator` over
  /// the same on-disk state (the relaunch moment) and calls `resumeIfNeeded()`. Only thrown after
  /// `setCrashAfterStepForTesting`.
  public struct SimulatedCrashForTesting: Error, Sendable, Equatable {
    public let step: Step
  }

  /// Mirrors `AccountLifecycleService.ClientFactory` (ARCHITECTURE.md §2/D12): production uses
  /// `ABSClient.production`; tests substitute a fake transport under the same decorators.
  public typealias ClientFactory = @Sendable (ABSServerConfig, any TokenStoring) -> ABSClient

  private let tokenStore: any TokenStoring
  private let customHeaderStore: any CustomHeaderStoring
  private let serverConfigFactory: ABSServerConfigFactory
  private let accountDAO: AccountDAO
  private let accountEndpointDAO: AccountEndpointDAO
  private let journalStore: AccountRemovalJournalStore
  private let accountRemover: AccountRemover
  private let makeClient: ClientFactory
  /// Logout preflight. Optional, like `SyncEngine`'s own `playback`, since not every composition
  /// cares about live playback.
  private let playback: (any PlaybackSyncing)?
  /// The transfer engine, optional for the same reason. The purge cancels every marked background
  /// transfer before deleting rows and files, so one call covers both.
  private let downloadCoordinator: DownloadCoordinator?
  /// Runtime composition supplies the live engine's `SyncEngine.shutdown()`, which cancels the
  /// traversal in flight and returns once it ends. Awaited after playback is quiesced and before
  /// the purge, credential wipe and delete, so a drained run ends with valid credentials. Cannot
  /// throw. The no-op default serves the removal-only graph, which has no engine.
  private let cancelForegroundSync: @Sendable () async -> Void
  /// Sends what the outbox still holds before the account row, and the outbox with it, is
  /// deleted. Runs once playback is quiesced (its final sync is queued by then), on a confirmed
  /// run only, for at most `outboxDrainBound`; removal never waits on the network beyond that.
  private let drainOutboxBeforeRemoval: @Sendable () async -> Void
  private let outboxDrainBound: Duration
  /// `DownloadFileStore.rootURL`, the parent of every account's `\(accountId)/` subtree.
  /// `nil` skips downloads-root removal and verification.
  private let downloadsRootURL: URL?
  /// `CoverImageClient`'s disposable cover-store directory. Not account-scoped (one account is
  /// supported), so removal and verification target the whole directory. `nil` skips it.
  private let coverCacheRootURL: URL?
  /// The app's diagnostics root (SECURITY.md §8): the problem-report bundles Settings › Report a
  /// Problem writes and the MetricKit payloads stored beside them. `nil` skips it.
  private let exportedDiagnosticsRootURL: URL?
  /// What the app publishes for its widgets: the App Group folder the extension reads (snapshot
  /// and covers) and the app-private token map. Empty skips them, like the optional roots above.
  private let widgetRootURLs: [URL]
  private let clearCachedArtwork: @Sendable () async throws -> Void

  /// In-memory only: `true` while this process is running the sequence. Distinct from
  /// `isRemovalPending()`, the durable signal that gates login/setup.
  public private(set) var isRemovalInProgress = false

  /// Actor reentrancy means a second launch-resume call can arrive while the first sequence is
  /// suspended on I/O. Every caller joins this one unstructured task; none may interpret a
  /// duplicate early return as completed removal.
  private var activeRemovalTask: Task<Void, any Error>?

  private var recordedSteps: [Step] = []
  private var crashAfterStepForTesting: Step?

  public init(
    tokenStore: any TokenStoring,
    accountDAO: AccountDAO,
    accountEndpointDAO: AccountEndpointDAO,
    journalStore: AccountRemovalJournalStore,
    accountRemover: AccountRemover,
    customHeaderStore: any CustomHeaderStoring = InMemoryCustomHeaderStore(),
    clientFactory: ClientFactory? = nil,
    playback: (any PlaybackSyncing)? = nil,
    downloadCoordinator: DownloadCoordinator? = nil,
    cancelForegroundSync: @escaping @Sendable () async -> Void = {},
    drainOutboxBeforeRemoval: @escaping @Sendable () async -> Void = {},
    outboxDrainBound: Duration = .seconds(5),
    downloadsRootURL: URL? = nil,
    coverCacheRootURL: URL? = nil,
    exportedDiagnosticsRootURL: URL? = nil,
    widgetRootURLs: [URL] = [],
    clearCachedArtwork: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.tokenStore = tokenStore
    self.customHeaderStore = customHeaderStore
    serverConfigFactory = ABSServerConfigFactory(customHeaderStore: customHeaderStore)
    self.accountDAO = accountDAO
    self.accountEndpointDAO = accountEndpointDAO
    self.journalStore = journalStore
    self.accountRemover = accountRemover
    self.makeClient =
      clientFactory ?? {
        server, tokenStore in
        ABSClient.production(
          server: server,
          tokenStore: tokenStore,
          customHeaderStore: customHeaderStore,
          clearCachedArtwork: { try? await clearCachedArtwork() })
      }
    self.playback = playback
    self.downloadCoordinator = downloadCoordinator
    self.cancelForegroundSync = cancelForegroundSync
    self.drainOutboxBeforeRemoval = drainOutboxBeforeRemoval
    self.outboxDrainBound = outboxDrainBound
    self.downloadsRootURL = downloadsRootURL
    self.coverCacheRootURL = coverCacheRootURL
    self.exportedDiagnosticsRootURL = exportedDiagnosticsRootURL
    self.widgetRootURLs = widgetRootURLs
    self.clearCachedArtwork = clearCachedArtwork
  }

  /// The durable signal that gates login/setup: `true` for as long as the removal journal exists,
  /// whichever launch is asking, including once the account row itself is gone.
  public func isRemovalPending() async throws -> Bool {
    try await journalStore.fetchAsync() != nil
  }

  /// The confirmed-removal entry point, called only once the user has confirmed. Cancelling at
  /// the warning never calls it, so no journal is written.
  public func confirmRemoval() async throws {
    try await runSequence()
  }

  /// The launch-time recovery entry point: a no-op if no journal survived a previous session,
  /// otherwise resumes the sequence `confirmRemoval()` runs. Safe to call on every launch.
  public func resumeIfNeeded() async throws {
    guard try await journalStore.fetchAsync() != nil else { return }
    try await runSequence()
  }

  /// Test-only: makes the sequence throw `SimulatedCrashForTesting(step:)` immediately after
  /// `step` durably commits, simulating a process crash at that boundary. `nil` never interrupts.
  func setCrashAfterStepForTesting(_ step: Step?) {
    crashAfterStepForTesting = step
  }

  /// Test-only: every step this instance's own run(s) have completed so far, in order.
  func recordedStepsForTesting() -> [Step] {
    recordedSteps
  }

  private func runSequence() async throws {
    if let activeRemovalTask {
      return try await activeRemovalTask.value
    }
    let task = Task { try await self.performSequence() }
    activeRemovalTask = task
    do {
      try await task.value
      activeRemovalTask = nil
    } catch {
      activeRemovalTask = nil
      throw error
    }
  }

  private func performSequence() async throws {
    isRemovalInProgress = true
    defer { isRemovalInProgress = false }

    let journal: AccountRemovalJournalRecord
    var isConfirmedRun = false
    if let existing = try await journalStore.fetchAsync() {
      // Resuming: the account row may already be gone, so every remaining step works from the
      // journal's recorded identity, never `accountDAO.fetchAsync()`.
      journal = existing
    } else {
      guard let account = try await accountDAO.fetchAsync(), let accountId = account.id else {
        // Nothing signed in and no prior journal: nothing to remove.
        return
      }
      let fresh = AccountRemovalJournalRecord(
        serverBaseURL: account.serverBaseURL,
        serverUserId: account.serverUserId,
        credentialNamespace: account.credentialNamespace,
        endpointURLs: try accountEndpointDAO.fetchAll(accountId: accountId).map(\.normalizedURL),
        accountRowId: accountId,
        downloadsRootRelativePath: String(accountId),
        createdAt: Date()
      )
      // The first durable step, before any destructive side effect.
      journal = try await journalStore.createAsync(fresh)
      isConfirmedRun = true
      try recordAndCheckCrash(.journalWritten)
    }

    await downloadCoordinator?.beginAccountRemoval()
    try recordAndCheckCrash(.intentsStopped)

    await playback?.quiesceForLogout()
    if isConfirmedRun {
      await Self.run(drainOutboxBeforeRemoval, for: outboxDrainBound)
    }
    try recordAndCheckCrash(.quiesced)

    await cancelForegroundSync()
    if let downloadCoordinator {
      do {
        try await downloadCoordinator.purgeAllDownloads(source: .accountRemoval)
      } catch {
        // A failed purge may leave a background adapter task authorized for the old account.
        // Keep the journal and retry rather than deleting credentials underneath live work.
        throw AccountRemovalError.deletionFailed
      }
    }
    try recordAndCheckCrash(.transfersCancelled)

    var serverLogoutFailed = false
    guard let serverURL = URL(string: journal.serverBaseURL) else {
      throw AccountRemovalError.credentialClearFailed
    }
    let serverConfig: ABSServerConfig
    let tokenAccount: TokenAccount
    let legacyAccounts: [(url: URL, account: TokenAccount)]
    do {
      serverConfig = try serverConfigFactory.make(for: serverURL)
      tokenAccount =
        if let credentialNamespace = journal.credentialNamespace {
          try TokenAccount(
            credentialNamespace: credentialNamespace, userID: journal.serverUserId)
        } else {
          try TokenAccount(serverURL: serverURL, userID: journal.serverUserId)
        }
      var seenURLs = Set<String>()
      legacyAccounts = try (journal.endpointURLs + [journal.serverBaseURL]).compactMap { urlString in
        guard seenURLs.insert(urlString).inserted else { return nil }
        guard let url = URL(string: urlString) else {
          throw AccountRemovalError.credentialClearFailed
        }
        return (url, try TokenAccount(serverURL: url, userID: journal.serverUserId))
      }
    } catch {
      // Validate every credential identity before deleting any item, so one malformed endpoint
      // cannot leave the account partially cleared and the journal unrecoverable.
      throw AccountRemovalError.credentialClearFailed
    }

    let client = makeClient(serverConfig, tokenStore)
    do {
      // Wipes tokens even when the server call fails (ABSApi's `logoutImpl`), so this one call
      // is both the server logout attempt and the Keychain wipe.
      try await client.logout(for: tokenAccount)
    } catch is LogoutError {
      throw AccountRemovalError.credentialClearFailed
    } catch {
      serverLogoutFailed = true
    }

    do {
      for legacy in legacyAccounts {
        try tokenStore.clear(for: legacy.account)
        try await clearCustomHeaders(for: legacy.url)
      }
      guard try tokenStore.load(for: tokenAccount) == nil else {
        throw AccountRemovalError.credentialClearFailed
      }
      for legacy in legacyAccounts {
        guard try tokenStore.load(for: legacy.account) == nil,
          try customHeaderStore.load(for: legacy.url) == nil
        else {
          throw AccountRemovalError.credentialClearFailed
        }
      }
    } catch {
      throw AccountRemovalError.credentialClearFailed
    }
    // Headerless accounts still own cached covers, decoded palettes, and persisted derived
    // palette rows. Clearing is unconditional rather than coupled to whether a header changed.
    do {
      try await clearCachedArtwork()
    } catch {
      throw AccountRemovalError.deletionFailed
    }
    try recordAndCheckCrash(.serverLogoutAttempted)

    do {
      try removeFileSystemArtifacts(journal: journal)
    } catch {
      throw AccountRemovalError.deletionFailed
    }
    try recordAndCheckCrash(.filesRemoved)

    do {
      // DB rows, the schema-driven sweep and the file-system sweep, in one call.
      try accountRemover.removeAccount(
        accountId: journal.accountRowId,
        verifyingFileSystemRootsAbsent: fileSystemRoots(journal: journal))
    } catch {
      throw AccountRemovalError.deletionFailed
    }
    try recordAndCheckCrash(.dbRemovedAndVerified)

    try await journalStore.clearAsync()
    try recordAndCheckCrash(.journalCleared)

    if serverLogoutFailed {
      Self.logger.error("Server logout was not confirmed after local account removal completed")
    }
  }

  /// Runs `operation` for at most `bound`, then cancels it and returns. It does not await the
  /// cancelled operation: a drain waiting on another caller's pass does not observe cancellation.
  private static func run(
    _ operation: @escaping @Sendable () async -> Void, for bound: Duration
  ) async {
    let gate = FirstFinishGate()
    let work = Task {
      await operation()
      gate.finish()
    }
    let timer = Task {
      try? await Task.sleep(for: bound)
      gate.finish()
    }
    await gate.wait()
    work.cancel()
    timer.cancel()
  }

  private func recordAndCheckCrash(_ step: Step) throws {
    recordedSteps.append(step)
    if crashAfterStepForTesting == step {
      throw SimulatedCrashForTesting(step: step)
    }
  }

  private func clearCustomHeaders(for serverURL: URL) async throws {
    try customHeaderStore.clear(for: serverURL)
  }

  private func removeFileSystemArtifacts(journal: AccountRemovalJournalRecord) throws {
    for root in fileSystemRoots(journal: journal) {
      try Self.removeIfPresent(root)
    }
  }

  private func fileSystemRoots(journal: AccountRemovalJournalRecord) -> [URL] {
    var roots: [URL] = []
    if let downloadsRootURL {
      roots.append(downloadsRootURL.appendingPathComponent(journal.downloadsRootRelativePath, isDirectory: true))
    }
    if let coverCacheRootURL { roots.append(coverCacheRootURL) }
    if let exportedDiagnosticsRootURL { roots.append(exportedDiagnosticsRootURL) }
    roots.append(contentsOf: widgetRootURLs)
    return roots
  }

  private static func removeIfPresent(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

/// Resumes one waiter when the first of several racers finishes. A finish that arrives before the
/// waiter is installed is kept for it.
private final class FirstFinishGate: Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<Void, Never>)
    case finishedEarly
    case done
  }

  private let state = Mutex<State>(.waiting)

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state -> Bool in
        if case .finishedEarly = state {
          state = .done
          return true
        }
        state = .installed(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func finish() {
    let continuation: CheckedContinuation<Void, Never>? = state.withLock { state in
      switch state {
      case .waiting:
        state = .finishedEarly
        return nil
      case .installed(let continuation):
        state = .done
        return continuation
      case .finishedEarly, .done:
        return nil
      }
    }
    continuation?.resume()
  }
}
