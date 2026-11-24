import AVFoundation
import AdSkip
import CoreMedia
import Foundation
import Speech
import Synchronization

/// The recogniser configuration the rules and model were tuned on (ad-harness `AdHarnessSpeech`).
nonisolated enum AdSkipSpeech {
  /// Pinned whatever the show's English variant or the phone's locale.
  static let localeIdentifier = "en-US"

  /// Everything a run needs before it opens a file: the pinned recogniser and its format.
  struct Ready {
    let locale: Locale
    let transcriber: SpeechTranscriber
    let target: AVAudioFormat
  }

  static func locale() async -> Locale? {
    await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier))
  }

  static func transcriber(for locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: [.audioTimeRange])
  }

  /// The prologue both speech adapters share: availability, the pinned locale, the asset and the
  /// analyser's input format. Throws `AdSkipAnalysisDeferred` when recognition cannot start yet, so
  /// callers wait rather than record a failure.
  static func readiness() async throws -> Ready {
    guard SpeechTranscriber.isAvailable, let locale = await locale() else {
      throw AdSkipAnalysisDeferred()
    }
    let transcriber = AdSkipSpeech.transcriber(for: locale)
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
      throw AdSkipAnalysisDeferred()
    }
    guard
      let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else { throw SpeechEpisodeTranscriber.Failure.noAudioFormat }
    return Ready(locale: locale, transcriber: transcriber, target: target)
  }
}

/// Transcribes windows of a downloaded episode on device; a port of ad-harness `transcribeSlices`,
/// held to the whole-file transcriber's output. One analyser per padded slice, fed buffers stamped
/// on the file's clock. Never downloads the speech asset: `SpeechAssetInstaller` does, with the
/// listener's consent.
nonisolated struct SpeechEpisodeTranscriber: EpisodeTranscribing {

  enum Failure: Error, Equatable {
    case unavailable
    case unsupportedLocale
    case noAudioFormat
  }

  /// Bump when this adapter's output can change. With the OS build it forms the transcriber
  /// revision: a change retries failed episodes and leaves stored transcripts alone.
  static let adapterVersion = 2

  static var revision: String {
    "speech-\(adapterVersion) \(ProcessInfo.processInfo.operatingSystemVersionString)"
  }

  /// Throws `AdSkipAnalysisDeferred` when no recogniser or asset is available yet, so the
  /// coordinator waits rather than recording the file as failed.
  func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
    let ready = try await AdSkipSpeech.readiness()
    // The player's duration, not `AVAudioFile`'s decoded-frame count: the feed exists because the
    // two disagree on a file joined from parts.
    let duration = try await SpeechAudioFeed.duration(ofFileAt: url)
    var words: [TranscriptWord] = []
    for window in windows {
      try Task.checkCancellation()
      let slice = TranscriptionWindows.slice(for: window, duration: duration)
      let runs = try await Self.timedRuns(ofFileAt: url, slice: slice, ready: ready)
      words += TranscriptionWindows.words(WordSplitter.words(from: runs), keptBy: window)
    }
    return Transcript(
      words: words.sorted { ($0.start, $0.end) < ($1.start, $1.end) }, duration: duration)
  }

  /// The timed runs a fresh analyser hears in `[slice.start, slice.end)` of the file at `url`, on
  /// the player's clock.
  private static func timedRuns(
    ofFileAt url: URL, slice: TimeSpan, ready: AdSkipSpeech.Ready
  ) async throws -> [TimedRun] {
    // A fresh module per window, as before: only the session holds one analyser for a whole file.
    let transcriber = AdSkipSpeech.transcriber(for: ready.locale)
    var feed = try await SpeechAudioFeed.open(url: url, target: ready.target, slice: slice)
    let runs = Mutex<[TimedRun]>([])
    try await SpeechAnalysisRun.perform(feed: &feed, transcriber: transcriber) { result in
      runs.withLock { $0.append(contentsOf: Self.timedRuns(in: result.text)) }
    }
    return runs.withLock { $0 }
  }

  /// The timed runs of one result. Text without a usable time range is dropped, so every word the
  /// splitter makes has finite times.
  static func timedRuns(in text: AttributedString) -> [TimedRun] {
    text.runs.compactMap { run in
      guard let range = run.audioTimeRange, range.start.isNumeric, range.end.isNumeric else {
        return nil
      }
      return TimedRun(
        text: String(text[run.range].characters),
        start: range.start.seconds,
        end: range.end.seconds)
    }
  }
}

/// Runs one analyser over a feed: starts it, feeds it, finalizes it and finishes it, and stops it
/// at once on cancellation or a throw. The caller decides when to feed and what a final result
/// means.
nonisolated enum SpeechAnalysisRun {
  /// What a run does before the next read.
  enum Step: Sendable, Equatable {
    /// Hand the analyser the feed's next read.
    case feed
    /// Wait before deciding again, so a caller can pace or pause the feed.
    case wait(Duration)
    /// Stop feeding: the caller is done with this run.
    case end
  }

  static func perform(
    feed: inout SpeechAudioFeed,
    transcriber: SpeechTranscriber,
    beforeFeed: (_ fedThroughSeconds: Double) async throws -> Step = { _ in .feed },
    onResult: @escaping @Sendable (SpeechTranscriber.Result) async -> Void
  ) async throws {
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collector = Task {
      for try await result in transcriber.results where result.isFinal {
        await onResult(result)
      }
    }
    let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()

    // Feeding takes seconds and the analyser then works through the queued audio inside
    // `finalizeAndFinishThroughEndOfInput()`, which does not observe cancellation. Without the
    // stop, a heat hold would let the window run on and the coordinator would discard it.
    try await SpeechAnalysisCancellation.run {
      do {
        try await analyzer.start(inputSequence: inputs)
        var fed = false
        feeding: while true {
          try Task.checkCancellation()
          switch try await beforeFeed(feed.fedThroughSeconds) {
          case .end:
            break feeding
          case .wait(let duration):
            try await Task.sleep(for: duration)
          case .feed:
            guard let next = try feed.next() else { break feeding }
            for input in next {
              continuation.yield(input)
              fed = true
            }
          }
        }
        continuation.finish()
        if fed {
          try await analyzer.finalizeAndFinishThroughEndOfInput()
        } else {
          await analyzer.cancelAndFinishNow()
        }
      } catch {
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        collector.cancel()
        throw error
      }
      try await collector.value
    } stop: {
      await analyzer.cancelAndFinishNow()
      collector.cancel()
    }
  }
}

/// Runs analysis work so that cancelling the calling task stops it at once through `stop`, rather
/// than when the work next checks, then reports the cancellation as `CancellationError`.
nonisolated enum SpeechAnalysisCancellation {
  static func run<Value: Sendable>(
    _ work: () async throws -> Value,
    stop: @escaping @Sendable () async -> Void
  ) async throws -> Value {
    let value = try await withTaskCancellationHandler {
      try await work()
    } onCancel: {
      Task { await stop() }
    }
    try Task.checkCancellation()
    return value
  }
}
