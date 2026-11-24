import AdSkip
import Foundation
import Persistence

/// Audio-gated scheduling: every episode is decoded once for its silences and audio print, its
/// print is matched against the others' and the store's, and only the stretches whose audio recurs
/// (stage 1) and the look-backs before what was kept (stage 2) are transcribed.
///
/// An episode's row is `.decoded` until its first planned windows are covered, then `.analysed`,
/// and stays so if a later arrival grows its windows while the new stretch waits.
extension AdSkipCoordinator {
  /// One unit of the worker's queue.
  enum Work {
    case decode(AdSkipLocalEpisode, AdSkipEpisodeRecord?)
    case transcribe(AdSkipLocalEpisode, AdSkipEpisodeRecord, windows: [TimeSpan])

    var episode: AdSkipLocalEpisode {
      switch self {
      case .decode(let episode, _), .transcribe(let episode, _, _): episode
      }
    }

    var isTranscription: Bool {
      if case .transcribe = self { return true }
      return false
    }
  }

  enum WorkOutcome: Sendable {
    case decoded(DecodedAudio)
    case transcribed(Transcript)
  }

  // MARK: - Queue

  /// The next unit of work: the prioritized episode's decode or missing windows first, then every
  /// outstanding decode, then the oldest row's missing windows.
  /// `priorityOnly` is Check Now's queue: the prioritized episode's work and nothing after it, so
  /// the backlog never drains on battery.
  func nextWork(stored: [AdSkipEpisodeRecord], priorityOnly: Bool = false) async throws -> Work? {
    let work = try await queuedWork(stored: stored, priorityOnly: priorityOnly)
    // A priority-only read says nothing about the backlog, which may still wait.
    if priorityOnly == false {
      hasQueuedWork = work != nil
    } else if work != nil {
      hasQueuedWork = true
    }
    return work
  }

  private func queuedWork(stored: [AdSkipEpisodeRecord], priorityOnly: Bool) async throws -> Work? {
    guard let localEpisodes else { return nil }
    let rows = Self.byIdentity(stored)
    if let priority, let episode = localEpisodes[priority], isSchedulable(episode) {
      if needsDecode(episode, stored: rows[priority]) { return .decode(episode, rows[priority]) }
      if let row = rows[priority] {
        let windows = try await missingWindows(of: row)
        if windows.isEmpty == false { return .transcribe(episode, row, windows: windows) }
      }
    }
    guard priorityOnly == false else { return nil }
    let decode = localEpisodes.values
      .filter { isSchedulable($0) && needsDecode($0, stored: rows[$0.identity]) }
      .min { $0.identity.episodeKey < $1.identity.episodeKey }
    if let decode { return .decode(decode, rows[decode.identity]) }
    // `stored` is in row id order, so the oldest row's gap goes first.
    for row in stored {
      guard let episode = localEpisodes[row.identity], isSchedulable(episode) else { continue }
      let windows = try await missingWindows(of: row)
      if windows.isEmpty == false { return .transcribe(episode, row, windows: windows) }
    }
    return nil
  }

  /// `nextWork`, measured as a `replan` when a measurement is attached.
  func measuredNextWork(stored: [AdSkipEpisodeRecord], priorityOnly: Bool = false) async throws -> Work? {
    guard let measurement = dependencies.matchingMeasurement else {
      return try await nextWork(stored: stored, priorityOnly: priorityOnly)
    }
    let (queries, pairChecks) = (plans.stageOneQueries, plans.stageOnePairChecks)
    await measurement.willStart(.replan)
    do {
      let work = try await nextWork(stored: stored, priorityOnly: priorityOnly)
      await measurement.didFinish(
        .replan,
        AdSkipMatchingDetail(
          queries: plans.stageOneQueries - queries, librarySize: plans.audioLibrary?.references.count,
          pairChecks: plans.stageOnePairChecks - pairChecks))
      return work
    } catch {
      await measurement.didFinish(
        .replan,
        AdSkipMatchingDetail(
          queries: plans.stageOneQueries - queries, pairChecks: plans.stageOnePairChecks - pairChecks,
          succeeded: false))
      throw error
    }
  }

  func isSchedulable(_ episode: AdSkipLocalEpisode) -> Bool {
    Self.isAnalysable(episode) && unreadableFiles.contains(episode.identity) == false
  }

  /// Whether the episode still needs its one decode: no row, failed under an older transcriber, or
  /// transcribed in full before audio prints existed.
  func needsDecode(_ episode: AdSkipLocalEpisode, stored row: AdSkipEpisodeRecord?) -> Bool {
    guard isSchedulable(episode) else { return false }
    guard let row else { return true }
    switch row.state {
    case .failed: return row.transcriberRevision != dependencies.transcriberRevision
    case .decoded, .analysed: return row.audioPrintFileName == nil
    }
  }

  /// The wanted seconds the row's transcript does not cover yet.
  func missingWindows(of row: AdSkipEpisodeRecord) async throws -> [TimeSpan] {
    guard row.state != .failed, row.audioPrintFileName != nil, let name = row.transcriptFileName
    else { return [] }
    guard let coverage = plans.transcriptCoverage(fileName: name) else {
      // The recompute finds the transcript unreadable and has the episode decoded again.
      isRecomputePending = true
      return []
    }
    let wanted = try await wantedWindows(of: row, coverage: coverage)
    return TranscriptionWindows.missing(wanted, covered: coverage.spans)
  }

  /// Stage 1, whatever stage 2 the last recompute asked for, and the post-roll tail when its
  /// trigger fires, inside the file; the whole file under the debug switch's whole-file mode. The
  /// tail is covered-only, as stage 2 is: it never joins the index view, nor the first windows that
  /// make a row `.analysed`.
  func wantedWindows(
    of row: AdSkipEpisodeRecord, coverage: TranscriptCoverage
  ) async throws -> [TimeSpan] {
    let duration = coverage.duration
    guard let plan = try await stageOnePlan(of: row) else {
      return [TimeSpan(start: 0, end: duration)]
    }
    let tail = TranscriptionWindows.tailSilence(
      silences: coverage.silences, duration: duration, sameShow: plan.sameShowEdges
    ).map { TranscriptionWindows.tailWindow(after: $0, duration: duration) }
    return TranscriptionWindows.clamped(
      plan.windows + (plans.stageTwoWindows[row.identity] ?? []) + (tail.map { [$0] } ?? []),
      duration: duration)
  }
}
