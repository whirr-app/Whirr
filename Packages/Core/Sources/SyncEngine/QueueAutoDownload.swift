import Foundation
import Persistence

// MARK: - Download request boundary

/// The ordinary download intents the Up Next policy can reach. Keeping this narrower than
/// `DownloadIntents` makes the policy independent of pause, purge, ebook, and storage controls.
public protocol QueueAutoDownloadRequesting: Sendable {
  func requestDownload(itemID: String) async throws
  func requestEpisodeDownload(itemID: String, episodeID: String) async throws
}

/// Sends the request selected by a queue identity. `false` means an RSS identity could not be
/// serialized into the item namespace; callers keep their existing diagnostic policy for that
/// local validation failure.
private func requestQueueDownload(
  for identity: ListeningIdentity,
  using requesting: any QueueAutoDownloadRequesting
) async throws -> Bool {
  switch identity.source {
  case .audiobook(let itemID):
    try await requesting.requestDownload(itemID: itemID)
  case .podcastEpisode(let itemID, let episodeID):
    try await requesting.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
  case .rssEpisode(let feedID, let episodeID):
    guard let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId else { return false }
    try await requesting.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }
  return true
}

extension DownloadCoordinator: QueueAutoDownloadRequesting {}

/// Default request boundary for compositions that have not wired a download coordinator yet.
public struct NoOpQueueAutoDownloadRequesting: QueueAutoDownloadRequesting, Sendable {
  public init() {}
  public func requestDownload(itemID: String) async throws {}
  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {}
}

/// Explicit no-op policy provider for callers that do not yet have a device preference store.
public struct NoOpQueueAutoDownloadPolicyProviding: QueueAutoDownloadPolicyProviding, Sendable {
  public init() {}
  public var queueAutoDownloadPolicy: QueueAutoDownloadPolicy { .never }
}

// MARK: - Queue decorator

/// Adds best-effort download requests to successful Up Next mutations. The wrapped queue commits
/// first; a request failure is recorded as a bounded download diagnostic and never changes the
/// already-committed queue result.
public struct QueueAutoDownload: ListeningQueueStoring, Sendable {
  private let store: any ListeningQueueStoring
  private let requesting: any QueueAutoDownloadRequesting
  private let preferences: any QueueAutoDownloadPolicyProviding
  private let networkConditions: any NetworkConditions
  private let diagnostics: any DiagnosticsRecording
  private let accountId: Int64?
  private let declines: (any ListeningQueueDownloadDeclineReading)?
  private let now: @Sendable () -> Date

  /// `declines` keeps an entry whose download the listener removed by hand from being requested
  /// again by Play Next or a chapter change. A new entry has no decline.
  public init(
    store: any ListeningQueueStoring,
    requesting: any QueueAutoDownloadRequesting = NoOpQueueAutoDownloadRequesting(),
    preferences: any QueueAutoDownloadPolicyProviding = NoOpQueueAutoDownloadPolicyProviding(),
    networkConditions: any NetworkConditions,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    accountId: Int64? = nil,
    declines: (any ListeningQueueDownloadDeclineReading)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.requesting = requesting
    self.preferences = preferences
    self.networkConditions = networkConditions
    self.diagnostics = diagnostics
    self.accountId = accountId
    self.declines = declines
    self.now = now
  }

  /// A chapter row's identity is the book, so its download is the whole book.
  @discardableResult
  public func append(
    identity: ListeningIdentity, chapter: ListeningQueueChapter?
  ) async throws -> ListeningQueueAppendOutcome {
    let outcome = try await store.append(identity: identity, chapter: chapter)
    switch outcome {
    case .appended, .replaced: await requestIfAllowed(identity: identity)
    case .alreadyQueued: break
    }
    return outcome
  }

  public func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {
    try await store.insertNext(identity: identity, chapter: chapter)
    await requestIfAllowed(identity: identity)
  }

  @discardableResult
  public func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] {
    let skipped = try await store.insertNext(identities: identities)
    var seen = Set(skipped)
    for identity in identities where seen.insert(identity).inserted {
      await requestIfAllowed(identity: identity)
    }
    return skipped
  }

  public func remove(identity: ListeningIdentity) async throws {
    try await store.remove(identity: identity)
  }

  public func remove(rowID: Int64) async throws {
    try await store.remove(rowID: rowID)
  }

  public func move(rowID: Int64, to position: Int) async throws {
    try await store.move(rowID: rowID, to: position)
  }

  public func clear() async throws -> ListeningQueueRestoreToken {
    try await store.clear()
  }

  public func restore(token: ListeningQueueRestoreToken) async throws {
    try await store.restore(token: token)
  }

  public func peekNextLive() async -> ListeningQueueItem? {
    await store.peekNextLive()
  }

  public func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {
    try await store.acknowledgeStarted(identity: identity, rowID: rowID)
  }

  public func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool {
    let returned = try await store.acknowledgeStarted(
      identity: identity, rowID: rowID, returning: displaced)
    if returned { await requestIfAllowed(identity: displaced) }
    return returned
  }

  private func requestIfAllowed(identity: ListeningIdentity) async {
    guard
      queueAutoDownloadAdmissionAllowed(
        preferences: preferences, networkConditions: networkConditions)
    else { return }
    guard await isDeclined(identity, by: declines) == false else { return }
    let startedAt = now()
    do {
      if try await requestQueueDownload(for: identity, using: requesting) == false {
        await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
      }
    } catch {
      await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
    }
  }

  private func recordDiagnostic(statusClass: DiagnosticsStatusClass, startedAt: Date) async {
    guard let accountId else { return }
    await diagnostics.record(
      DiagnosticsEvent(
        category: .download, statusClass: statusClass,
        durationMilliseconds: SyncEngine.durationMilliseconds(startedAt: startedAt, endedAt: now())),
      accountId: accountId)
  }
}

// MARK: - Reconciler

/// Reconciles durable Up Next state with download rows. A queue entry added under `wifiOnly` on
/// cellular is therefore picked up after a later allowed-network trigger, without a timer or a
/// detached task. Concurrent callers share one in-flight pass.
public actor QueueAutoDownloadReconciler: CoalescedPassHost {
  private let candidateProvider: any ListeningQueueDownloadCandidateReading
  private let requesting: any QueueAutoDownloadRequesting
  private let preferences: any QueueAutoDownloadPolicyProviding
  private let networkConditions: any NetworkConditions
  private let diagnostics: any DiagnosticsRecording
  private let accountId: Int64?
  private let declines: (any ListeningQueueDownloadDeclineReading)?
  private let now: @Sendable () -> Date

  var passSlot = CoalescedPassSlot<Void>()

  /// Test evidence that a concurrent trigger reached the existing flight rather than starting a
  /// second pass.
  var joinedFlightCount: Int { passSlot.joinedCount }

  public init(
    candidateProvider: any ListeningQueueDownloadCandidateReading,
    requesting: any QueueAutoDownloadRequesting = NoOpQueueAutoDownloadRequesting(),
    preferences: any QueueAutoDownloadPolicyProviding = NoOpQueueAutoDownloadPolicyProviding(),
    networkConditions: any NetworkConditions,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    accountId: Int64? = nil,
    declines: (any ListeningQueueDownloadDeclineReading)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.candidateProvider = candidateProvider
    self.requesting = requesting
    self.preferences = preferences
    self.networkConditions = networkConditions
    self.diagnostics = diagnostics
    self.accountId = accountId
    self.declines = declines
    self.now = now
  }

  /// Runs one reconciliation pass. Concurrent callers coalesce onto the same in-flight pass.
  public func run() async {
    await runCoalescedPass(policy: .shareInFlight) { await self.perform() }
  }

  private func perform() async {
    let startedAt = now()
    guard
      queueAutoDownloadAdmissionAllowed(
        preferences: preferences, networkConditions: networkConditions)
    else { return }

    let candidates: [ListeningIdentity]
    do {
      candidates = try await candidateProvider.fetchQueueIdentitiesWithoutDownloads()
    } catch {
      await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
      return
    }

    var failureCount = 0
    for candidate in candidates {
      guard Task.isCancelled == false else { break }
      // The candidates were read before this loop's requests, which each await; a hand removal
      // can land meanwhile. Checking each one narrows that window to a single request.
      guard await isDeclined(candidate, by: declines) == false else { continue }
      do {
        if try await requestQueueDownload(for: candidate, using: requesting) == false {
          failureCount += 1
        }
      } catch {
        failureCount += 1
      }
    }

    await recordDiagnostic(
      statusClass: failureCount == 0 ? .success : .clientError, startedAt: startedAt)
  }

  private func recordDiagnostic(statusClass: DiagnosticsStatusClass, startedAt: Date) async {
    guard let accountId else { return }
    await diagnostics.record(
      DiagnosticsEvent(
        category: .download, statusClass: statusClass,
        durationMilliseconds: SyncEngine.durationMilliseconds(startedAt: startedAt, endedAt: now())),
      accountId: accountId)
  }
}

/// A failed read counts as not declined, so Download Up Next keeps its behaviour before declines.
private func isDeclined(
  _ identity: ListeningIdentity, by declines: (any ListeningQueueDownloadDeclineReading)?
) async -> Bool {
  guard let declines else { return false }
  return (try? await declines.isDownloadDeclined(identity)) == true
}

private func queueAutoDownloadAdmissionAllowed(
  preferences: any QueueAutoDownloadPolicyProviding,
  networkConditions: any NetworkConditions
) -> Bool {
  switch preferences.queueAutoDownloadPolicy {
  case .never: false
  case .wifiOnly: networkConditions.isConstrainedOrCellular == false
  case .always: true
  }
}
