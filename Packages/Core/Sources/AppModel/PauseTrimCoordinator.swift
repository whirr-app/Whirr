import AdSkip
import CoreSupport
import Foundation
import Persistence

/// Finds the pauses in downloaded podcast episodes for Trim Silences and answers the player with
/// them. Separate from `AdSkipCoordinator`: neither feature's gate or queue depends on the other's.
///
/// Analyses a download only while its show resolves to a strength and the injected conditions allow
/// (outside Low Power Mode, below serious heat; charging not required). An analysis lives as long
/// as its download: a removed download or changed file deletes the row, but switching a show off
/// keeps it, so switching back on is instant.
public actor PauseTrimCoordinator {
  public struct Dependencies: Sendable {
    public var store: PauseTrimEpisodeStore
    public var analyser: any PauseAnalysing
    public var fingerprinting: any AdSkipFileFingerprinting
    public var now: @Sendable () -> Date

    public init(
      store: PauseTrimEpisodeStore, analyser: any PauseAnalysing,
      fingerprinting: any AdSkipFileFingerprinting = FileSystemAdSkipFingerprinting(),
      now: @escaping @Sendable () -> Date = Date.init
    ) {
      self.store = store
      self.analyser = analyser
      self.fingerprinting = fingerprinting
      self.now = now
    }
  }

  static let log = CoreLogging.logger(category: "TrimSilences")

  let dependencies: Dependencies

  private var localEpisodes: [AdSkipEpisodeIdentity: AdSkipLocalEpisode]?
  private var defaultSetting: TrimSilencesDefault?
  private var overrides: [String: TrimSilencesShowOverride] = [:]
  private var isAllowed = false
  private var priority: AdSkipEpisodeIdentity?

  private var inFlight: (identity: AdSkipEpisodeIdentity, task: Task<PauseAnalysis, Error>)?
  let changes = SkipRangeChangeBroadcaster()

  /// One pass analyses at most one episode and asks for another, so the queue drains the backlog.
  private lazy var queue = SerialAnalysisQueue(
    hooks: .init(pass: { [weak self] in try await self?.reconcile() }),
    reporting: .init(
      cancelled: { Self.log.debug("Pause analysis cancelled") },
      failed: {
        Self.log.error(
          "Pause analysis pass failed: \(String(describing: type(of: $0)), privacy: .public)")
      }))

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  // MARK: - Inputs

  /// Feeds the coordinator for the life of the launch. `isAllowed` is
  /// `AdSkipAnalysisConditions.changesIgnoringCharging()`.
  public func start(
    localEpisodes: AsyncStream<[AdSkipLocalEpisode]>,
    defaults: AsyncStream<TrimSilencesDefault>,
    overrides: AsyncStream<[String: TrimSilencesShowOverride]>,
    isAllowed: AsyncStream<Bool>
  ) async {
    _ = await queue.installFeeders {
      [
        Task { [weak self] in
          for await episodes in localEpisodes { await self?.setLocalEpisodes(episodes) }
        },
        Task { [weak self] in
          for await value in defaults { await self?.setDefault(value) }
        },
        Task { [weak self] in
          for await values in overrides { await self?.setOverrides(values) }
        },
        Task { [weak self] in
          for await allowed in isAllowed { await self?.setAllowed(allowed) }
        },
      ]
    }
  }

  public func stop() async {
    await queue.stop()
    inFlight?.task.cancel()
  }

  public func setLocalEpisodes(_ episodes: [AdSkipLocalEpisode]) async {
    let byIdentity = Dictionary(
      episodes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    guard byIdentity != localEpisodes else { return }
    localEpisodes = byIdentity
    if let inFlight, byIdentity[inFlight.identity] == nil { inFlight.task.cancel() }
    // The player asks again: an ask before the downloads arrived was answered "not analysed".
    changes.signal()
    await wake()
  }

  public func setDefault(_ value: TrimSilencesDefault) async {
    guard value != defaultSetting else { return }
    defaultSetting = value
    cancelInFlightIfUnwanted()
    await wake()
  }

  public func setOverrides(_ values: [String: TrimSilencesShowOverride]) async {
    guard values != overrides else { return }
    overrides = values
    cancelInFlightIfUnwanted()
    await wake()
  }

  public func setAllowed(_ allowed: Bool) async {
    guard allowed != isAllowed else { return }
    isAllowed = allowed
    if allowed == false { inFlight?.task.cancel() }
    await wake()
  }

  /// Returns once the queue has nothing left it may do.
  func waitUntilIdle() async {
    await queue.waitUntilIdle()
  }

  // MARK: - Worker

  private func wake() async {
    await queue.wake()
  }

  /// Removes what no longer has its download or its file, then analyses the next wanted episode.
  /// Each pass analyses at most one, and asks for another pass after it.
  private func reconcile() async throws {
    guard let localEpisodes else { return }
    let stored = try await dependencies.store.allSummaries()
    let removals = stored.filter { row in
      guard let local = localEpisodes[row.identity] else { return true }
      // A missing file is left until the download tables say it is gone.
      guard let current = dependencies.fingerprinting.fingerprint(ofFileAt: local.fileURL) else {
        return false
      }
      return current != row.fingerprint
    }.map(\.identity)
    if removals.isEmpty == false {
      try await dependencies.store.deleteEpisodes(removals)
      changes.signal()
    }

    guard isAllowed, let next = nextWork(stored: stored, removed: Set(removals)) else { return }
    try await analyse(next)
    await queue.requestPass()
  }

  /// The loaded episode first, then the rest in the reader's identity order. An episode is wanted
  /// while its show resolves to a strength and it has no current analysis.
  private func nextWork(
    stored: [PauseTrimEpisodeSummary], removed: Set<AdSkipEpisodeIdentity>
  ) -> AdSkipLocalEpisode? {
    guard let localEpisodes, let defaultSetting else { return nil }
    let current = Dictionary(
      stored.filter { removed.contains($0.identity) == false }.map { ($0.identity, $0) },
      uniquingKeysWith: { first, _ in first })
    func isWanted(_ episode: AdSkipLocalEpisode) -> Bool {
      let showOverride = overrides[episode.identity.itemID] ?? .inherit
      guard TrimSilencesResolution.strength(default: defaultSetting, showOverride: showOverride) != nil
      else { return false }
      guard let row = current[episode.identity] else { return true }
      return row.detectorRevision != PauseDetector.revision
    }
    if let priority, let episode = localEpisodes[priority], isWanted(episode) { return episode }
    return localEpisodes.values.sorted { Self.isOrderedBefore($0.identity, $1.identity) }
      .first(where: isWanted)
  }

  private func analyse(_ episode: AdSkipLocalEpisode) async throws {
    guard let fingerprint = dependencies.fingerprinting.fingerprint(ofFileAt: episode.fileURL)
    else {
      // Gone between the reader and here: the next reader update removes it.
      return
    }
    let analyser = dependencies.analyser
    let url = episode.fileURL
    let task = Task { try await analyser.analyse(fileAt: url) }
    inFlight = (episode.identity, task)
    defer { inFlight = nil }

    let state: PauseTrimAnalysisState
    let runs: Data?
    do {
      let analysis = try await task.value
      state = analysis.isAligned ? .analysed : .misaligned
      // A misaligned file is still trimmed, through precise timing, so it keeps its runs.
      runs = analysis.runs.encoded()
    } catch {
      if task.isCancelled || error is CancellationError { throw CancellationError() }
      Self.log.error(
        "Pause analysis failed: \(String(describing: type(of: error)), privacy: .public)")
      state = .failed
      runs = nil
    }
    // A file replaced while it was decoded is analysed again on the next pass.
    guard dependencies.fingerprinting.fingerprint(ofFileAt: url) == fingerprint,
      localEpisodes?[episode.identity] != nil
    else { return }
    try await dependencies.store.save(
      PauseTrimEpisodeRecord(
        source: episode.identity.source, accountId: episode.identity.accountId,
        itemID: episode.identity.itemID, episodeID: episode.identity.episodeID,
        fileByteSize: fingerprint.byteSize, fileModificationTime: fingerprint.modificationTime,
        detectorRevision: PauseDetector.revision, state: state, runs: runs,
        analysedAt: dependencies.now()))
    changes.signal()
  }

  /// A show switched off mid-decode stops the decode; its download stays queued for when it is on.
  private func cancelInFlightIfUnwanted() {
    guard let inFlight, let defaultSetting,
      let episode = localEpisodes?[inFlight.identity]
    else { return }
    let showOverride = overrides[episode.identity.itemID] ?? .inherit
    if TrimSilencesResolution.strength(default: defaultSetting, showOverride: showOverride) == nil {
      inFlight.task.cancel()
    }
  }

  private static func isOrderedBefore(
    _ lhs: AdSkipEpisodeIdentity, _ rhs: AdSkipEpisodeIdentity
  ) -> Bool {
    if lhs.source != rhs.source { return lhs.source.rawValue < rhs.source.rawValue }
    if (lhs.accountId ?? 0) != (rhs.accountId ?? 0) {
      return (lhs.accountId ?? 0) < (rhs.accountId ?? 0)
    }
    if lhs.itemID != rhs.itemID { return lhs.itemID < rhs.itemID }
    return lhs.episodeID < rhs.episodeID
  }

  // MARK: - The player's source

  fileprivate func localEpisode(matching request: PlaybackSkipRangeRequest) -> AdSkipLocalEpisode? {
    guard let episodeID = request.episodeID, let localEpisodes else { return nil }
    let matches = localEpisodes.values.filter {
      $0.identity.itemID == request.itemID && $0.identity.episodeID == episodeID
    }
    guard matches.count > 1 else { return matches.first }
    let path = request.fileURL.standardizedFileURL.path
    return matches.first { $0.fileURL.standardizedFileURL.path == path }
  }

  fileprivate func prioritize(_ identity: AdSkipEpisodeIdentity) async {
    guard identity != priority else { return }
    priority = identity
    await wake()
  }

  fileprivate func requestAnalysis() async { await wake() }
}

extension PauseTrimCoordinator: PlaybackTrimSource {
  /// The loaded file's runs, or why there are none. Asking puts the episode first in the queue.
  public func trimAnswer(for request: PlaybackSkipRangeRequest) async -> PlaybackTrimAnswer {
    guard request.episodeID != nil else { return .notApplicable }
    guard let local = localEpisode(matching: request) else { return .notAnalysed }
    await prioritize(local.identity)
    guard let row = try? await dependencies.store.episode(for: local.identity),
      row.detectorRevision == PauseDetector.revision,
      dependencies.fingerprinting.fingerprint(ofFileAt: request.fileURL)
        == AdSkipFileFingerprint(
          byteSize: row.fileByteSize, modificationTime: row.fileModificationTime)
    else {
      // A stale row is replaced by the queue, which this wakes.
      await requestAnalysis()
      return .notAnalysed
    }
    let timing: PlaybackTrimTiming
    switch row.state {
    case .analysed: timing = .estimated
    case .misaligned: timing = .precise
    case .failed: return .unavailable(.unreadable)
    }
    guard let data = row.runs, let runs = PauseRuns(encoded: data) else {
      return .unavailable(.unreadable)
    }
    return .runs(runs, timing: timing)
  }

  public nonisolated func trimChanges() -> AsyncStream<Void> { changes.stream() }
}

extension PauseTrimEpisodeSummary {
  fileprivate var fingerprint: AdSkipFileFingerprint {
    AdSkipFileFingerprint(byteSize: fileByteSize, modificationTime: fileModificationTime)
  }
}
