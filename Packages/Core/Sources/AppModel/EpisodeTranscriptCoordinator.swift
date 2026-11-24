import AdSkip
import Foundation
import Persistence

/// Generates the listener's transcript of a downloaded episode on request, one episode at a time,
/// and keeps the stored transcripts in step with the downloads.
///
/// A session holds the shared `TranscriberGate` for its whole life, paused or not. A hold (Low
/// Power Mode, serious heat) pauses its feed; a hold that outlasts `pauseLimit`, the app leaving
/// the foreground while nothing plays, a removed download or the listener's cancel ends it at a
/// checkpoint: what was final is saved, and a later session resumes a pad before the first
/// uncovered second. A request survives a checkpoint, and runs again once the app is in the
/// foreground and the conditions allow; a session is never started in the background, where the
/// recogniser was seen to refuse to start with the phone locked.
///
/// The transcript is user content: never log its words.
public actor EpisodeTranscriptCoordinator: CompleteEpisodeTranscriptReading {
  public struct Dependencies: Sendable {
    public var store: EpisodeTranscriptStore
    public var session: any EpisodeTranscriptSessionRunning
    public var gate: TranscriberGate
    public var fingerprinting: any AdSkipFileFingerprinting
    public var transcriberRevision: String
    /// Progress is written at most this often while a session runs, and at every checkpoint.
    public var saveInterval: TimeInterval
    /// How long a held session keeps its analyser before it checkpoints.
    public var pauseLimit: Duration
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
      store: EpisodeTranscriptStore, session: any EpisodeTranscriptSessionRunning,
      gate: TranscriberGate,
      fingerprinting: any AdSkipFileFingerprinting = FileSystemAdSkipFingerprinting(),
      transcriberRevision: String, saveInterval: TimeInterval = 10,
      pauseLimit: Duration = .seconds(300), now: @escaping @Sendable () -> Date = Date.init,
      sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
      self.store = store
      self.session = session
      self.gate = gate
      self.fingerprinting = fingerprinting
      self.transcriberRevision = transcriberRevision
      self.saveInterval = saveInterval
      self.pauseLimit = pauseLimit
      self.now = now
      self.sleep = sleep
    }
  }

  /// Counts for the debug trigger's measurement: never words.
  public struct Counts: Sendable, Equatable {
    public var sessions = 0
    public var checkpoints = 0
    public var holds = 0
    /// Leading words of a resumed session dropped as a repeat of the word before the join.
    public var joinRepeatsDropped = 0
  }

  private struct Summary: Equatable {
    var state: EpisodeTranscriptState
    var coveredThrough: Double
    var duration: Double

    var covered: Double {
      duration > 0 ? min(1, max(0, coveredThrough / duration)) : 0
    }
  }

  private struct Running {
    let identity: AdSkipEpisodeIdentity
    let task: Task<Void, Never>
    let hold: EpisodeTranscriptHold
    var pauseTimer: Task<Void, Never>?
    /// False while it waits at the gate for ad skip's call in flight.
    var hasGate = false
    /// Whether it has been held: a held analyser idles and may not survive to resume.
    var wasHeld = false
  }

  /// The transcript a session is adding to, in memory.
  private struct Active {
    let identity: AdSkipEpisodeIdentity
    let fingerprint: EpisodeTranscriptFingerprint
    var words: [TranscriptWord]
    var coveredThrough: Double
    var duration: Double
    /// Where this session's words begin: a word belongs to it when its midpoint is at or after.
    let sessionStart: Double
    /// True until the session's first kept word, which may repeat the word before the join.
    var isAtJoin: Bool
    var hasUnsavedWords = false
    var lastSaved: Date
  }

  private enum Outcome {
    case finished
    case stopped
    case deferred
    case failed
  }

  private struct Observer {
    let identity: AdSkipEpisodeIdentity
    let continuation: AsyncStream<EpisodeTranscriptStatus>.Continuation
    var last: EpisodeTranscriptStatus?
  }

  private struct IdentityObserver {
    let itemID: String
    let episodeID: String
    let continuation: AsyncStream<AdSkipEpisodeIdentity?>.Continuation
    var last: AdSkipEpisodeIdentity?
  }

  private let dependencies: Dependencies
  private var localEpisodes: [AdSkipEpisodeIdentity: AdSkipLocalEpisode] = [:]
  private var hasLocalEpisodes = false
  private var isAllowed = false
  private var isForeground = false
  private var isPlaying = false
  private var isDeferred = false
  private var requests: [AdSkipEpisodeIdentity] = []
  private var summaries: [AdSkipEpisodeIdentity: Summary] = [:]
  private var running: Running?
  private var active: Active?
  private var observers: [UInt64: Observer] = [:]
  private var identityObservers: [UInt64: IdentityObserver] = [:]
  private var completeObservers: [UInt64: AsyncStream<AdSkipEpisodeIdentity>.Continuation] = [:]
  private var nextObserverID: UInt64 = 0
  private var feeders: [Task<Void, Never>] = []
  private var cleanup: Task<Void, Never>?
  private var isCleanupOwed = false
  private var hasSwept = false
  /// True while Look Back has the recogniser: no session starts, whichever input calls `pump()`.
  private var isYielded = false
  private var startedAt: Date?
  private var counts = Counts()

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  // MARK: - Inputs

  /// Feeds the inputs from their streams for the life of the process. Idempotent.
  /// `isAllowed` is ad skip's analysis conditions without the charging rule.
  public func start(
    localEpisodes: AsyncStream<[AdSkipLocalEpisode]>, isAllowed: AsyncStream<Bool>,
    isForeground: AsyncStream<Bool>, isPlaying: AsyncStream<Bool>
  ) {
    guard feeders.isEmpty else { return }
    startedAt = dependencies.now()
    feeders = [
      Task { [weak self] in
        for await episodes in localEpisodes { await self?.setLocalEpisodes(episodes) }
      },
      Task { [weak self] in
        for await allowed in isAllowed { await self?.setAllowed(allowed) }
      },
      Task { [weak self] in
        for await foreground in isForeground { await self?.setForeground(foreground) }
      },
      Task { [weak self] in
        for await playing in isPlaying { await self?.setPlaying(playing) }
      },
    ]
  }

  public func setLocalEpisodes(_ episodes: [AdSkipLocalEpisode]) {
    if startedAt == nil { startedAt = dependencies.now() }
    localEpisodes = Dictionary(episodes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    hasLocalEpisodes = true
    requests.removeAll { isEligible($0) == false }
    if let running, isEligible(running.identity) == false {
      running.task.cancel()
    }
    scheduleCleanup()
    publish()
    publishIdentities()
    pump()
  }

  /// False under Low Power Mode or serious heat. A running session is held, not stopped.
  public func setAllowed(_ allowed: Bool) {
    isAllowed = allowed
    if allowed { isDeferred = false }
    if var running {
      if allowed {
        running.pauseTimer?.cancel()
        running.pauseTimer = nil
        running.hold.set(false)
      } else if running.hold.isHeld == false {
        running.hold.set(true)
        running.wasHeld = true
        counts.holds += 1
        running.pauseTimer = pauseTimer(for: running.identity)
      }
      self.running = running
    }
    publish()
    pump()
  }

  /// Each move to the foreground also retries a deferred request: the speech asset may have
  /// arrived meanwhile.
  public func setForeground(_ foreground: Bool) {
    isForeground = foreground
    if foreground { isDeferred = false }
    checkpointIfNotLive()
    publish()
    pump()
  }

  public func setPlaying(_ playing: Bool) {
    isPlaying = playing
    checkpointIfNotLive()
  }

  // MARK: - Listener

  /// Asks for `identity`'s transcript, or for it again after a failure. Ignored for an episode
  /// that is not eligible or is already transcribed.
  public func request(_ identity: AdSkipEpisodeIdentity) {
    guard isEligible(identity), summaries[identity]?.state != .complete else { return }
    if requests.contains(identity) == false { requests.append(identity) }
    publish()
    pump()
  }

  /// Withdraws a request; a running session checkpoints.
  public func cancel(_ identity: AdSkipEpisodeIdentity) {
    requests.removeAll { $0 == identity }
    if let running, running.identity == identity { running.task.cancel() }
    publish()
  }

  /// Makes way for Look Back: the running session, if any, stops at a checkpoint as it does on
  /// leaving the foreground (what was final is saved, the request is kept), and no session starts
  /// until `resumeAfterLookBack()`. Returns once that session has finished and released the gate.
  public func yieldForLookBack() async {
    isYielded = true
    guard let running else { return }
    running.task.cancel()
    await running.task.value
  }

  /// Ends a yield; a request stopped by it resumes a pad before its first uncovered second.
  public func resumeAfterLookBack() {
    isYielded = false
    pump()
  }

  /// Retries a request deferred for the speech asset.
  public func retry() {
    isDeferred = false
    publish()
    pump()
  }

  public func status(for identity: AdSkipEpisodeIdentity) -> EpisodeTranscriptStatus {
    guard isEligible(identity) else { return .unavailable }
    let summary = summaries[identity]
    if summary?.state == .complete { return .complete }
    let covered = summary?.covered ?? 0
    if let running, running.identity == identity {
      guard running.hasGate else { return .waiting(.queued, covered: covered) }
      return running.hold.isHeld ? .waiting(.held, covered: covered) : .generating(covered: covered)
    }
    if requests.contains(identity) {
      if isDeferred { return .waiting(.deferred, covered: covered) }
      if isAllowed == false { return .waiting(.held, covered: covered) }
      return .waiting(.queued, covered: covered)
    }
    switch summary?.state {
    case .failed: return .failed
    case .partial: return .stopped(covered: covered)
    case .complete, nil: return .notStarted
    }
  }

  /// The status now, then on every change.
  public func statusChanges(of identity: AdSkipEpisodeIdentity) -> AsyncStream<EpisodeTranscriptStatus> {
    let (stream, continuation) = AsyncStream<EpisodeTranscriptStatus>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    nextObserverID += 1
    let id = nextObserverID
    let current = status(for: identity)
    continuation.yield(current)
    observers[id] = Observer(identity: identity, continuation: continuation, last: current)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    return stream
  }

  /// The eligible downloaded episode behind the player's item and episode: now, then on every
  /// change. Nil when it is not downloaded, not eligible, or downloaded under two accounts, which
  /// identity alone cannot tell apart.
  public func identityChanges(
    itemID: String, episodeID: String
  ) -> AsyncStream<AdSkipEpisodeIdentity?> {
    let (stream, continuation) = AsyncStream<AdSkipEpisodeIdentity?>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    nextObserverID += 1
    let id = nextObserverID
    let current = eligibleIdentity(itemID: itemID, episodeID: episodeID)
    continuation.yield(current)
    identityObservers[id] = IdentityObserver(
      itemID: itemID, episodeID: episodeID, continuation: continuation, last: current)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeIdentityObserver(id) }
    }
    return stream
  }

  public func currentCounts() -> Counts { counts }

  var hasCompletedFirstCleanup: Bool { hasSwept }

  /// The words so far: the running session's in memory, else the stored transcript.
  public func transcript(for identity: AdSkipEpisodeIdentity) async throws -> StoredTranscript? {
    if let active, active.identity == identity { return stored(active) }
    return try await dependencies.store.transcript(for: identity)?.transcript
  }

  public func completeTranscript(
    for identity: AdSkipEpisodeIdentity
  ) async -> CompleteEpisodeTranscript? {
    guard let episode = localEpisodes[identity],
      let entry = try? await dependencies.store.transcript(for: identity),
      entry.record.state == .complete, let fileName = entry.record.transcriptFileName,
      let current = dependencies.fingerprinting.fingerprint(ofFileAt: episode.fileURL),
      current.byteSize == entry.record.fileByteSize,
      current.modificationTime == entry.record.fileModificationTime
    else { return nil }
    return CompleteEpisodeTranscript(fileName: fileName, transcript: entry.transcript.transcript)
  }

  public func completeTranscriptChanges() -> AsyncStream<AdSkipEpisodeIdentity> {
    let (stream, continuation) = AsyncStream<AdSkipEpisodeIdentity>.makeStream()
    nextObserverID += 1
    let id = nextObserverID
    completeObservers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeCompleteObserver(id) }
    }
    return stream
  }

  private func removeCompleteObserver(_ id: UInt64) {
    completeObservers[id] = nil
  }

  private func publishCompleteChange(_ identity: AdSkipEpisodeIdentity) {
    for continuation in completeObservers.values { continuation.yield(identity) }
  }

  // MARK: - Sessions

  private func isEligible(_ identity: AdSkipEpisodeIdentity) -> Bool {
    guard let episode = localEpisodes[identity] else { return false }
    return ShowLanguagePolicy.isAnalysable(languageTag: episode.languageTag)
  }

  private func pump() {
    requests.removeAll { summaries[$0]?.state == .complete }
    guard running == nil, isYielded == false, hasSwept, isAllowed, isForeground, isDeferred == false,
      let identity = requests.first, let episode = localEpisodes[identity]
    else { return }
    let hold = EpisodeTranscriptHold()
    running = Running(
      identity: identity, task: Task { await self.run(episode, hold: hold) }, hold: hold)
    counts.sessions += 1
    publish()
  }

  private func run(_ episode: AdSkipLocalEpisode, hold: EpisodeTranscriptHold) async {
    let identity = episode.identity
    let outcome: Outcome
    do {
      let start = try await prepare(episode)
      try await dependencies.gate.acquire(for: .session)
      running?.hasGate = true
      publish()
      do {
        try await dependencies.session.transcribe(
          fileAt: episode.fileURL, from: start, hold: hold
        ) { [weak self] event in
          await self?.handle(event, for: identity)
        }
        await dependencies.gate.release()
      } catch {
        await dependencies.gate.release()
        throw error
      }
      outcome = .finished
    } catch is CancellationError {
      outcome = .stopped
    } catch is AdSkipAnalysisDeferred {
      outcome = .deferred
    } catch {
      // A recogniser that will not start in the background is waiting for the foreground, and
      // one that did not survive a hold is owed a resume; neither is a failure of the file.
      outcome = isForeground && running?.wasHeld != true ? .failed : .stopped
    }
    // A checkpoint arrives as this task's cancellation, and the database refuses a write from a
    // cancelled task, so the save runs in a task of its own.
    await Task { await self.finish(identity, outcome) }.value
  }

  /// Loads what earlier sessions kept for this file and returns where this session starts.
  private func prepare(_ episode: AdSkipLocalEpisode) async throws -> Double {
    guard let current = dependencies.fingerprinting.fingerprint(ofFileAt: episode.fileURL) else {
      throw CancellationError()
    }
    let fingerprint = EpisodeTranscriptFingerprint(
      fileByteSize: current.byteSize, fileModificationTime: current.modificationTime)
    var words: [TranscriptWord] = []
    var coveredThrough = 0.0
    var duration = 0.0
    if let entry = try await dependencies.store.transcript(for: episode.identity),
      entry.record.fingerprint == fingerprint, entry.record.state == .partial
    {
      words = entry.transcript.words.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }
      coveredThrough = entry.transcript.coverage.first?.end ?? 0
      duration = entry.transcript.duration
    }
    try Task.checkCancellation()
    active = Active(
      identity: episode.identity, fingerprint: fingerprint, words: words,
      coveredThrough: coveredThrough, duration: duration, sessionStart: coveredThrough,
      isAtJoin: words.isEmpty == false, lastSaved: dependencies.now())
    return max(0, coveredThrough - TranscriptionWindows.padSeconds)
  }

  private func handle(_ event: EpisodeTranscriptSessionEvent, for identity: AdSkipEpisodeIdentity) async {
    guard var active, active.identity == identity else { return }
    switch event {
    case .started(let duration):
      active.duration = duration
    case .finalized(let words, let through):
      for word in words where (word.start + word.end) / 2 >= active.sessionStart {
        if active.isAtJoin {
          active.isAtJoin = false
          if let last = active.words.last, TranscriptJoin.repeats(word, last) {
            counts.joinRepeatsDropped += 1
            continue
          }
        }
        active.words.append(word)
        active.hasUnsavedWords = true
      }
      if through > active.coveredThrough {
        active.coveredThrough = through
        active.hasUnsavedWords = true
      }
    }
    self.active = active
    summaries[identity] = Summary(
      state: .partial, coveredThrough: active.coveredThrough, duration: active.duration)
    if active.hasUnsavedWords,
      dependencies.now().timeIntervalSince(active.lastSaved) >= dependencies.saveInterval
    {
      await save(isComplete: false)
    }
    publish()
  }

  private func finish(_ identity: AdSkipEpisodeIdentity, _ outcome: Outcome) async {
    running?.pauseTimer?.cancel()
    switch outcome {
    case .finished:
      if var active, active.identity == identity, isCurrent(active) {
        active.coveredThrough = max(active.coveredThrough, active.duration)
        self.active = active
        await save(isComplete: true)
      }
      requests.removeAll { $0 == identity }
    case .stopped:
      await saveIfStillCurrent(identity)
      counts.checkpoints += 1
    case .deferred:
      isDeferred = true
      await saveIfStillCurrent(identity)
    case .failed:
      requests.removeAll { $0 == identity }
      if let active, active.identity == identity {
        do {
          try await dependencies.store.markFailed(
            identity, fingerprint: active.fingerprint,
            transcriberRevision: dependencies.transcriberRevision, at: dependencies.now())
          summaries[identity] = Summary(state: .failed, coveredThrough: 0, duration: 0)
        } catch {
          summaries[identity] = nil
        }
      }
    }
    active = nil
    running = nil
    publish()
    pump()
  }

  /// A checkpoint keeps what was final, unless the download it belongs to has gone or changed.
  private func saveIfStillCurrent(_ identity: AdSkipEpisodeIdentity) async {
    guard let active, active.identity == identity, active.hasUnsavedWords, isCurrent(active) else {
      return
    }
    await save(isComplete: false)
  }

  /// Whether the download `active` is transcribing is still there, unchanged.
  private func isCurrent(_ active: Active) -> Bool {
    guard let episode = localEpisodes[active.identity],
      let current = dependencies.fingerprinting.fingerprint(ofFileAt: episode.fileURL)
    else { return false }
    return current.byteSize == active.fingerprint.fileByteSize
      && current.modificationTime == active.fingerprint.fileModificationTime
  }

  private func save(isComplete: Bool) async {
    guard var active else { return }
    do {
      try await dependencies.store.saveProgress(
        stored(active), for: active.identity, fingerprint: active.fingerprint,
        transcriberRevision: dependencies.transcriberRevision, isComplete: isComplete,
        at: dependencies.now())
      active.hasUnsavedWords = false
      active.lastSaved = dependencies.now()
      if self.active?.identity == active.identity {
        self.active?.hasUnsavedWords = false
        self.active?.lastSaved = active.lastSaved
      }
      summaries[active.identity] = Summary(
        state: isComplete ? .complete : .partial, coveredThrough: active.coveredThrough,
        duration: active.duration)
      if isComplete { publishCompleteChange(active.identity) }
    } catch {
      // Kept in memory; the next save or checkpoint tries again.
    }
  }

  private func stored(_ active: Active) -> StoredTranscript {
    StoredTranscript(
      words: active.words.map { StoredTranscriptWord(text: $0.text, start: $0.start, end: $0.end) },
      silences: [], duration: active.duration,
      coverage: [StoredTimeSpan(start: 0, end: min(active.coveredThrough, active.duration))])
  }

  private func pauseTimer(for identity: AdSkipEpisodeIdentity) -> Task<Void, Never> {
    let limit = dependencies.pauseLimit
    let sleep = dependencies.sleep
    return Task { [weak self] in
      do { try await sleep(limit) } catch { return }
      await self?.pauseLimitReached(identity)
    }
  }

  private func pauseLimitReached(_ identity: AdSkipEpisodeIdentity) {
    guard let running, running.identity == identity, running.hold.isHeld else { return }
    running.task.cancel()
  }

  /// Without the foreground or audio the process may be suspended at any moment: checkpoint now.
  private func checkpointIfNotLive() {
    guard isForeground == false, isPlaying == false, let running else { return }
    running.task.cancel()
  }

  // MARK: - Cleanup

  private func scheduleCleanup() {
    guard cleanup == nil else {
      isCleanupOwed = true
      return
    }
    cleanup = Task {
      await self.runCleanup()
    }
  }

  private func runCleanup() async {
    repeat {
      isCleanupOwed = false
      try? await cleanUp()
    } while isCleanupOwed
    cleanup = nil
    publish()
    pump()
  }

  /// Deletes rows whose download has gone or changed; on the first pass also rows whose file is
  /// missing, then files on the transcript root that no row names.
  private func cleanUp() async throws {
    let store = dependencies.store
    let records = try await store.allRecords()
    var removals: [AdSkipEpisodeIdentity] = []
    for record in records {
      guard let episode = localEpisodes[record.identity],
        let current = dependencies.fingerprinting.fingerprint(ofFileAt: episode.fileURL),
        current.byteSize == record.fileByteSize,
        current.modificationTime == record.fileModificationTime
      else {
        removals.append(record.identity)
        continue
      }
    }
    // A re-download under the same identity replaces the file the session is reading.
    if let running, let active, active.identity == running.identity, isCurrent(active) == false {
      running.task.cancel()
    }
    if removals.isEmpty == false {
      try await store.deleteEpisodes(removals)
      for identity in removals { summaries[identity] = nil }
      let complete = Set(records.filter { $0.state == .complete }.map(\.identity))
      for identity in removals where complete.contains(identity) { publishCompleteChange(identity) }
    }
    guard hasSwept == false else { return }
    let removed = Set(removals)
    for record in records where removed.contains(record.identity) == false {
      switch record.state {
      case .failed:
        summaries[record.identity] = Summary(state: .failed, coveredThrough: 0, duration: 0)
      case .partial, .complete:
        // Deletes a row whose file did not come back from a restore.
        if let entry = try await store.transcript(for: record.identity) {
          summaries[record.identity] = Summary(
            state: record.state, coveredThrough: entry.transcript.coverage.first?.end ?? 0,
            duration: entry.transcript.duration)
        }
      }
    }
    // Files this process wrote are newer than its start, so the cutoff cannot catch a save whose
    // row is still being written.
    _ = try await store.sweepFiles(modifiedBefore: startedAt ?? dependencies.now())
    hasSwept = true
  }

  // MARK: - Observers

  private func publish() {
    for (id, observer) in observers {
      let current = status(for: observer.identity)
      guard current != observer.last else { continue }
      observers[id]?.last = current
      observer.continuation.yield(current)
    }
  }

  private func removeObserver(_ id: UInt64) {
    observers[id] = nil
  }

  private func publishIdentities() {
    for (id, observer) in identityObservers {
      let current = eligibleIdentity(itemID: observer.itemID, episodeID: observer.episodeID)
      guard current != observer.last else { continue }
      identityObservers[id]?.last = current
      observer.continuation.yield(current)
    }
  }

  private func removeIdentityObserver(_ id: UInt64) {
    identityObservers[id] = nil
  }

  private func eligibleIdentity(itemID: String, episodeID: String) -> AdSkipEpisodeIdentity? {
    let matches = localEpisodes.keys.filter {
      $0.itemID == itemID && $0.episodeID == episodeID && isEligible($0)
    }
    return matches.count == 1 ? matches.first : nil
  }
}
