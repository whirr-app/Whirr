import AdSkip
import Foundation
import Synchronization

/// What a transcript session reports, in order.
public enum EpisodeTranscriptSessionEvent: Sendable, Equatable {
  /// The file is open: its duration on the transcriber's clock.
  case started(duration: Double)
  /// Final words in time order, on the file's clock, and the file time recognition is now final
  /// through. Final results never change, so they are kept as they arrive.
  case finalized(words: [TranscriptWord], through: Double)
}

/// Whether a running session's feed is held. The coordinator sets it on a heat or Low Power Mode
/// hold; the session reads it between feeds. A held session gives its analyser nothing more, so
/// the analyser finishes the lead it has and idles in the same session: a hold leaves no join.
public final class EpisodeTranscriptHold: Sendable {
  private let held = Mutex(false)

  public init() {}

  public var isHeld: Bool { held.withLock { $0 } }

  public func set(_ isHeld: Bool) { held.withLock { $0 = isHeld } }
}

/// One paced, pausable recognition of a downloaded file. The
/// App's adapter feeds one analyser a short lead ahead of what it has finished, so holding the
/// feed pauses it and cancelling stops it within about a second.
public protocol EpisodeTranscriptSessionRunning: Sendable {
  /// Transcribes `url` from `start` (file seconds) to the end of the file, delivering `events`
  /// one at a time, and returns once the end is final. Cancelling the calling task stops the
  /// analyser at once and throws `CancellationError`; what `events` already delivered stands.
  /// Throws `AdSkipAnalysisDeferred` when recognition cannot start yet (no recogniser or speech
  /// asset).
  func transcribe(
    fileAt url: URL, from start: Double, hold: EpisodeTranscriptHold,
    events: @escaping @Sendable (EpisodeTranscriptSessionEvent) async -> Void
  ) async throws
}

/// Where an episode's listener transcript stands.
public enum EpisodeTranscriptStatus: Sendable, Equatable {
  public enum Waiting: Sendable, Equatable {
    /// Behind another request, ad skip's call in flight, or the app's return to the foreground.
    case queued
    /// Low Power Mode or serious heat.
    case held
    /// The recogniser or its speech asset is not available yet.
    case deferred
  }

  /// Not a downloaded episode of an English show.
  case unavailable
  /// Eligible, never transcribed.
  case notStarted
  /// Requested and not running. `covered` is the fraction of the file transcribed so far.
  case waiting(Waiting, covered: Double)
  case generating(covered: Double)
  /// Part transcribed and no longer requested.
  case stopped(covered: Double)
  case complete
  case failed
}
