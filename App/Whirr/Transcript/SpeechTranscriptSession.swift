import AdSkip
import AppModel
import CoreMedia
import Foundation
import Speech
import Synchronization

/// The listener's transcript session: one analyser for the rest of the file, fed a short lead
/// ahead of its final results so the coordinator can hold it by starving it of input
/// (`SpeechAnalyzer` has no pause). Speech's own priority, which held up under a sustained thermal soak.
nonisolated struct SpeechTranscriptSession: EpisodeTranscriptSessionRunning {
  /// How long the feed waits between checks of the analyser's progress. Short: at about 60× real
  /// time, a 30 s lead lasts the analyser half a second.
  static let pollInterval: Duration = .milliseconds(25)
  static let heldPollInterval: Duration = .milliseconds(500)

  func transcribe(
    fileAt url: URL, from start: Double, hold: EpisodeTranscriptHold,
    // `@concurrent` matches the requirement as AppModel (Swift 6 mode) states it.
    events: @escaping @Sendable @concurrent (EpisodeTranscriptSessionEvent) async -> Void
  ) async throws {
    let ready = try await AdSkipSpeech.readiness()
    // The player's duration, not `AVAudioFile`'s decoded-frame count: the feed exists because the
    // two disagree on a file joined from parts.
    let duration = try await SpeechAudioFeed.duration(ofFileAt: url)
    var feed = try await SpeechAudioFeed.open(
      url: url, target: ready.target, slice: TimeSpan(start: min(start, duration), end: duration))
    await events(.started(duration: duration))

    let finalized = Mutex(start)
    var pacer = TranscriptFeedPacer()
    let started = ContinuousClock.now

    try await SpeechAnalysisRun.perform(
      feed: &feed,
      transcriber: ready.transcriber,
      beforeFeed: { fedThrough in
        let elapsed = ContinuousClock.now - started
        let decision = pacer.decide(
          at: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
          fed: fedThrough, finalized: finalized.withLock { $0 }, isHeld: hold.isHeld)
        switch decision {
        case .feed: return .feed
        case .waitForProgress: return .wait(Self.pollInterval)
        case .hold: return .wait(Self.heldPollInterval)
        }
      },
      onResult: { result in
        let words = WordSplitter.words(
          from: SpeechEpisodeTranscriber.timedRuns(in: result.text))
        let through = Self.finalizedThrough(result)
        finalized.withLock { $0 = max($0, through) }
        await events(.finalized(words: words, through: through))
      })
  }

  /// Where a final result says recognition is final through, on the file clock.
  private static func finalizedThrough(_ result: SpeechTranscriber.Result) -> Double {
    let times = [result.resultsFinalizationTime, result.range.end].filter(\.isNumeric)
    return times.map(\.seconds).max() ?? 0
  }
}
