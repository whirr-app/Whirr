import Foundation
import Persistence
import SyncEngine
import Testing

/// Test double for the automatic-download selection boundary. It keeps the candidate list live so
/// a successful `markDecided` removes that identity from later fetches, matching the real store's
/// convergence contract while exposing the limits and call counts the coordinator tests inspect.
public actor FakePodcastAutoDownloadSelecting: PodcastAutoDownloadSelecting {
  public struct DecidedKey: Hashable, Sendable {
    public let itemID: String
    public let episodeID: String

    public init(itemID: String, episodeID: String) {
      self.itemID = itemID
      self.episodeID = episodeID
    }
  }

  private var remaining: [PodcastAutoDownloadCandidate]
  public private(set) var decided: Set<DecidedKey> = []
  public private(set) var fetchCallCount = 0
  public private(set) var repairCallCount = 0
  public private(set) var lastMaxPerShow: Int?
  public private(set) var lastMaxPerPass: Int?

  public init(candidates: [PodcastAutoDownloadCandidate] = []) {
    remaining = candidates
  }

  public func fetchCandidates(maxPerShow: Int, maxPerPass: Int) async throws
    -> [PodcastAutoDownloadCandidate]
  {
    fetchCallCount += 1
    lastMaxPerShow = maxPerShow
    lastMaxPerPass = maxPerPass
    return remaining
  }

  public func markDecided(itemID: String, episodeID: String) async throws {
    decided.insert(DecidedKey(itemID: itemID, episodeID: episodeID))
    remaining.removeAll { $0.itemID == itemID && $0.episodeID == episodeID }
  }

  public func repairDecidedStamps() async throws -> Int {
    repairCallCount += 1
    return 0
  }
}

/// Test double for the automatic episode planning boundary. Failures persist per episode until
/// `clearFailures` is called, and happen after the optional gate so tests can distinguish a
/// planner rejection from a pass that is still coalescing or being cancelled.
public actor FakeAutomaticEpisodeDownloadPlanning: AutomaticEpisodeDownloadPlanning {
  public struct Request: Equatable, Sendable {
    public let itemID: String
    public let episodeID: String

    public init(itemID: String, episodeID: String) {
      self.itemID = itemID
      self.episodeID = episodeID
    }
  }

  public private(set) var requests: [Request] = []
  public var callCount: Int { requests.count }
  private var failures: [String: Error] = [:]
  private let gate: PlannerGate?

  public init(gate: PlannerGate? = nil) {
    self.gate = gate
  }

  public func stubFailure(episodeID: String, error: Error) {
    failures[episodeID] = error
  }

  public func clearFailures() {
    failures.removeAll()
  }

  public func requestAutomaticEpisodeDownload(itemID: String, episodeID: String) async throws {
    requests.append(Request(itemID: itemID, episodeID: episodeID))
    if let gate {
      await gate.waitForRelease(episodeID: episodeID)
    }
    if let error = failures[episodeID] {
      throw error
    }
  }
}

/// Test double for the reap candidate store. `setCandidates` models the real store no longer
/// returning an identity after a successful purge, while `callCount` keeps trigger wiring
/// assertions independent from the candidate contents.
///
/// Each read snapshots the candidates before it parks on `readGate`, so a held read returns the
/// list it started with even if the test changes the candidates meanwhile.
public actor FakePodcastAutoDownloadReapCandidateProviding:
  PodcastAutoDownloadReapCandidateProviding
{
  private var candidates: [EpisodeDownloadKey]
  private var readError: Error?
  public private(set) var callCount = 0

  /// Holds a read in flight after it has taken its candidate snapshot.
  public nonisolated let readGate = TestGate<Void>(
    label: "FakePodcastAutoDownloadReapCandidateProviding.reapCandidates")

  public init(candidates: [EpisodeDownloadKey] = []) {
    self.candidates = candidates
  }

  public func reapCandidates() async throws -> [EpisodeDownloadKey] {
    callCount += 1
    if let readError { throw readError }
    let snapshot = candidates
    await readGate.pass()
    return snapshot
  }

  public func setCandidates(_ candidates: [EpisodeDownloadKey]) {
    self.candidates = candidates
  }

  /// Makes every following read throw `error`; `nil` restores normal reads.
  public func failReads(with error: Error?) {
    readError = error
  }
}

public enum FakePodcastAutoDownloadPurgingError: Error, Equatable, Sendable {
  case failed
}

/// Test double for the narrow purge boundary. Calls are retained in order, and failures can be
/// injected for selected identities without changing the outcome of any other purge.
public actor FakePodcastAutoDownloadPurging: PodcastAutoDownloadPurging {
  public private(set) var calls: [EpisodeDownloadKey] = []
  private var failingIdentities: Set<EpisodeDownloadKey> = []
  private var afterPurge: (@Sendable (Int) async -> Void)?

  public init() {}

  /// Runs `hook` after each purge is recorded, with the number of calls so far, so a test can act
  /// at an exact call (cancel the reaper after the third, say). The hook runs before any injected
  /// failure is thrown.
  public func setAfterPurge(_ hook: (@Sendable (Int) async -> Void)?) {
    afterPurge = hook
  }

  public func failPurge(itemID: String, episodeID: String) {
    failingIdentities.insert(EpisodeDownloadKey(itemID: itemID, episodeID: episodeID))
  }

  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {
    let key = EpisodeDownloadKey(itemID: itemID, episodeID: episodeID)
    calls.append(key)
    await afterPurge?(calls.count)
    if failingIdentities.contains(key) {
      throw FakePodcastAutoDownloadPurgingError.failed
    }
  }
}

/// A planner gate that can hold one or more episode calls until the test releases an identity.
/// Both waits are bounded (`WaitableState`): a forgotten release or start fails the test instead of
/// hanging the whole suite.
public actor PlannerGate {
  private struct State: Sendable {
    var started: Set<String> = []
    var released: Set<String> = []
    var waitingForRelease: [String: Int] = [:]
  }

  private let state = WaitableState(State(), label: "PlannerGate") { state in
    "started \(state.started.sorted()); released \(state.released.sorted())"
  }

  public init() {}

  @discardableResult
  public func waitForRelease(
    episodeID: String,
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> TestWaitOutcome {
    state.mutate { state in
      state.started.insert(episodeID)
      state.waitingForRelease[episodeID, default: 0] += 1
    }
    defer { state.mutate { $0.waitingForRelease[episodeID, default: 1] -= 1 } }
    return await state.waitUntil(
      "releasing \(episodeID)", timeout: timeout, sourceLocation: sourceLocation
    ) { $0.released.contains(episodeID) }
  }

  @discardableResult
  public func waitUntilStarted(
    episodeID: String,
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> TestWaitOutcome {
    await state.waitUntil(
      "starting \(episodeID)", timeout: timeout, sourceLocation: sourceLocation
    ) { $0.started.contains(episodeID) }
  }

  public func isWaitingForRelease(episodeID: String) -> Bool {
    state.value.waitingForRelease[episodeID, default: 0] > 0
  }

  public func release(episodeID: String) {
    state.mutate { _ = $0.released.insert(episodeID) }
  }
}
