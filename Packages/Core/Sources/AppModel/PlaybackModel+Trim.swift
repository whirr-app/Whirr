import AdSkip
import Foundation
import Persistence
import PlayerCore
import SyncEngine
import Synchronization

/// What Trim Silences will do for one load: the status the card shows, and the map PlayerCore
/// should cut by. A map is present only once the engine holds its composition.
struct PlaybackTrimPlan: Sendable, Equatable {
  var status: PlaybackTrimStatus
  var map: PlayerTrimMap?

  static let off = PlaybackTrimPlan(status: .off, map: nil)
}

/// The trim work started before a `.load`: its plan if it finished inside the budget, and
/// the task that finishes it otherwise.
struct PendingPlaybackTrim {
  var request: PlaybackSkipRangeRequest?
  var task: Task<PlaybackTrimPlan, Never>
  var ready: PlaybackTrimPlan?
}

/// Trim Silences for the loaded episode. Before each load the model resolves the show's strength,
/// asks for the file's pauses, plans the cuts and has the engine prepare them, within a budget: a
/// map ready in time rides on `.load`, a late one follows as `.setTrimMap` for the same generation
/// only. While playing, a change to the default, the show's setting or the analysis sends the new
/// map.
extension PlaybackModel {

  // MARK: - Before and after the load

  /// Starts the trim work for `prepared` and waits for it up to the budget. Nil without trim
  /// dependencies. The caller checks ownership again after this returns.
  internal func prepareTrimBeforeLoad(for prepared: PreparedPlayback) async -> PendingPlaybackTrim? {
    guard let trim else { return nil }
    let request = Self.trimRequest(for: prepared)
    let itemID = prepared.itemID
    let task = Task { await Self.plan(itemID: itemID, request: request, trim: trim, current: nil) }
    let ready = await Self.value(of: task, within: trim.preparationBudget)
    return PendingPlaybackTrim(request: request, task: task, ready: ready)
  }

  /// Takes over the work `prepareTrimBeforeLoad` started, after `.load` and `setLoaded`. A plan
  /// that missed the budget is applied when it finishes, if this generation is still loaded.
  internal func adoptTrim(_ pending: PendingPlaybackTrim?, generation: Int) {
    guard let trim, let pending, let itemID = loadedItemID else { return }
    observeTrimChanges(trim)
    hasLoadedTrimTarget = true
    loadedTrimRequest = pending.request
    if let ready = pending.ready {
      loadedTrimMap = ready.map
      applyTrimStatus(ready.status)
      return
    }
    applyTrimStatus(.preparing)
    let episodeID = loadedEpisodeID
    trimTask = Task { [weak self] in
      let plan = await pending.task.value
      guard Task.isCancelled == false, let self,
        self.ownsLoadedTrim(itemID: itemID, episodeID: episodeID, generation: generation)
      else { return }
      self.apply(plan, itemID: itemID, episodeID: episodeID)
    }
  }

  /// Clears what a previous load set up; `setLoaded` calls it for every change of source.
  internal func resetTrim() {
    trimTask?.cancel()
    trimTask = nil
    hasLoadedTrimTarget = false
    loadedTrimRequest = nil
    loadedTrimMap = nil
    trimSavedThisEpisode = 0
    applyTrimStatus(.off)
  }

  /// Adds a progress event's saved time, at the listener's rate, to the episode's figure.
  internal func noteTrimmed(in event: PlaybackProgressEvent) {
    guard event.trimmedDelta > 0 else { return }
    trimSavedThisEpisode += event.trimmedDelta
    if case .trimming = trimStatus { applyTrimStatus(.trimming(savedThisEpisode: 0)) }
  }

  // MARK: - While loaded

  /// Plans again for the loaded episode, and sends the map if it changed.
  internal func refreshLoadedTrim() {
    guard let trim, hasLoadedTrimTarget, let itemID = loadedItemID,
      let generation = loadedPlaybackGeneration
    else { return }
    let episodeID = loadedEpisodeID
    let request = loadedTrimRequest
    let current = loadedTrimMap
    trimTask?.cancel()
    trimTask = Task { [weak self] in
      let plan = await Self.plan(itemID: itemID, request: request, trim: trim, current: current)
      guard Task.isCancelled == false, let self,
        self.ownsLoadedTrim(itemID: itemID, episodeID: episodeID, generation: generation)
      else { return }
      self.apply(plan, itemID: itemID, episodeID: episodeID)
    }
  }

  private func apply(_ plan: PlaybackTrimPlan, itemID: String, episodeID: String?) {
    if plan.map != loadedTrimMap {
      loadedTrimMap = plan.map
      // The reducer ignores a map for any item but the loaded one.
      player.send(.setTrimMap(itemID: itemID, episodeID: episodeID, map: plan.map))
    }
    applyTrimStatus(plan.status)
  }

  private func applyTrimStatus(_ status: PlaybackTrimStatus) {
    let next: PlaybackTrimStatus =
      if case .trimming = status { .trimming(savedThisEpisode: trimSavedThisEpisode) } else { status }
    if trimStatus != next { trimStatus = next }
  }

  private func ownsLoadedTrim(itemID: String, episodeID: String?, generation: Int) -> Bool {
    hasLoadedTrimTarget && loadedItemID == itemID && loadedEpisodeID == episodeID
      && loadedPlaybackGeneration == generation && isQuiescedForLogout == false
  }

  /// One observation of each input for the model's lifetime, opened on the first load. The streams
  /// only say that something changed; the plan reads the current values itself.
  private func observeTrimChanges(_ trim: PlaybackTrimDependencies) {
    guard trimObservationTasks.isEmpty else { return }
    let defaults = trim.defaults.observeDefault()
    let overrides = trim.showSettings.observeTrimSilencesOverrides()
    let analyses = trim.source.trimChanges()
    trimObservationTasks = [
      Task { [weak self] in
        for await _ in defaults { self?.refreshLoadedTrim() }
      },
      Task { [weak self] in
        for await _ in overrides { self?.refreshLoadedTrim() }
      },
      Task { [weak self] in
        for await _ in analyses { self?.refreshLoadedTrim() }
      },
    ]
  }

  // MARK: - Planning

  /// Only a single-file local podcast episode qualifies, as for ad-skip: the analysis is of the
  /// downloaded file, and a stream can carry different dynamic ads.
  static func trimRequest(for prepared: PreparedPlayback) -> PlaybackSkipRangeRequest? {
    guard prepared.source == .local, prepared.episodeID != nil, prepared.tracks.count == 1,
      let track = prepared.tracks.first, track.url.isFileURL
    else { return nil }
    return PlaybackSkipRangeRequest(
      itemID: prepared.itemID, episodeID: prepared.episodeID, fileURL: track.url)
  }

  /// Resolves the show's strength, asks for the file's pauses, plans the cuts, and has the engine
  /// prepare them unless they are the map already in force.
  nonisolated static func plan(
    itemID: String, request: PlaybackSkipRangeRequest?, trim: PlaybackTrimDependencies,
    current: PlayerTrimMap?
  ) async -> PlaybackTrimPlan {
    let overrides = (try? await trim.showSettings.fetchTrimSilencesOverrides()) ?? [:]
    guard
      let strength = TrimSilencesResolution.strength(
        default: trim.defaults.current, showOverride: overrides[itemID] ?? .inherit)
    else { return .off }
    guard let request else { return PlaybackTrimPlan(status: .notApplicable, map: nil) }
    switch await trim.source.trimAnswer(for: request) {
    case .runs(let runs, let timing):
      let map = PauseTrimPlanner.map(for: runs, strength: strength)
      // An episode without a pause worth cutting plays whole, and saves nothing.
      guard map.isEmpty == false else { return PlaybackTrimPlan(status: .trimming(savedThisEpisode: 0), map: nil) }
      if map == current { return PlaybackTrimPlan(status: .trimming(savedThisEpisode: 0), map: map) }
      guard await trim.preparer.prepare(map: map, forFileURL: request.fileURL, timing: timing) else {
        return PlaybackTrimPlan(status: .unavailable, map: nil)
      }
      return PlaybackTrimPlan(status: .trimming(savedThisEpisode: 0), map: map)
    case .notAnalysed:
      return PlaybackTrimPlan(status: .preparing, map: nil)
    case .unavailable:
      return PlaybackTrimPlan(status: .unavailable, map: nil)
    case .notApplicable:
      return PlaybackTrimPlan(status: .notApplicable, map: nil)
    }
  }

  /// The task's value if it arrives within `budget`, otherwise nil. The task keeps running.
  nonisolated static func value<Value: Sendable>(
    of task: Task<Value, Never>, within budget: Duration
  ) async -> Value? {
    let once = ResumeOnce<Value?>()
    let timer = Task {
      try? await Task.sleep(for: budget)
      once.resume(nil)
    }
    defer { timer.cancel() }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        once.install(continuation)
        Task { once.resume(await task.value) }
      }
    } onCancel: {
      once.resume(nil)
    }
  }
}

/// Resumes a continuation with whichever value arrives first, and ignores the rest. A value that
/// arrives before the continuation is installed is kept for it.
private final class ResumeOnce<Value: Sendable>: Sendable {
  private enum State {
    case waiting
    case installed(CheckedContinuation<Value, Never>)
    case early(Value)
    case done
  }

  private let state = Mutex<State>(.waiting)

  func install(_ continuation: CheckedContinuation<Value, Never>) {
    let early: Value? = state.withLock { state in
      switch state {
      case .waiting:
        state = .installed(continuation)
        return nil
      case .early(let value):
        state = .done
        return value
      case .installed, .done:
        return nil
      }
    }
    if let early { continuation.resume(returning: early) }
  }

  func resume(_ value: Value) {
    let continuation: CheckedContinuation<Value, Never>? = state.withLock { state in
      switch state {
      case .waiting:
        state = .early(value)
        return nil
      case .installed(let continuation):
        state = .done
        return continuation
      case .early, .done:
        return nil
      }
    }
    continuation?.resume(returning: value)
  }
}
