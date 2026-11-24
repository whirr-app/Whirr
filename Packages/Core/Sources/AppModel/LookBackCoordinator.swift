import AdSkip
import Foundation

/// What a Look Back run reports while it works.
public enum LookBackEvent: Sendable, Equatable {
  /// Queued at the shared recogniser behind another analysis.
  case waiting
  /// Holds the recogniser.
  case started
  /// `segment` has landed: every word so far, on the book's clock, earliest first.
  case chunk(LookBackSegment, words: [TranscriptWord])
}

/// Look Back stopped because the device reached critical thermal state.
public struct LookBackTooHot: Error, Equatable {
  public init() {}
}

/// Runs a Look Back window's chunks on the shared recogniser. It takes the gate once for the whole run, so no ad-skip call slips in between chunks,
/// and calls the ungated transcriber. A running podcast transcript session is asked to make way
/// first and to resume afterwards, however the run ends.
///
/// The text is user content: never log it.
public struct LookBackCoordinator: Sendable {
  public struct Dependencies: Sendable {
    public var gate: TranscriberGate
    /// The ungated transcriber: the run already holds the gate.
    public var transcriber: any EpisodeTranscribing
    public var yieldTranscripts: @Sendable () async -> Void
    public var resumeTranscripts: @Sendable () async -> Void
    /// Checked before each chunk: Look Back ignores Low Power Mode and charging, and stops only
    /// at critical thermal state.
    public var isTooHot: @Sendable () -> Bool

    public init(
      gate: TranscriberGate, transcriber: any EpisodeTranscribing,
      yieldTranscripts: @escaping @Sendable () async -> Void = {},
      resumeTranscripts: @escaping @Sendable () async -> Void = {},
      isTooHot: @escaping @Sendable () -> Bool = { false }
    ) {
      self.gate = gate
      self.transcriber = transcriber
      self.yieldTranscripts = yieldTranscripts
      self.resumeTranscripts = resumeTranscripts
      self.isTooHot = isTooHot
    }
  }

  private let dependencies: Dependencies

  public init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// Transcribes `chunks` (newest first) and joins each, as it lands, before `words`. Returns
  /// every word, earliest first. Throws `CancellationError` when cancelled, after the gate is
  /// released; words already reported stay valid.
  public func run(
    _ chunks: [LookBackSegment], before words: [TranscriptWord],
    events: @Sendable (LookBackEvent) async -> Void
  ) async throws -> [TranscriptWord] {
    guard chunks.isEmpty == false else { return words }
    await dependencies.yieldTranscripts()
    do {
      await events(.waiting)
      try await dependencies.gate.acquire(for: .lookBack)
    } catch {
      await dependencies.resumeTranscripts()
      throw error
    }
    do {
      await events(.started)
      var joined = words
      for chunk in chunks {
        try Task.checkCancellation()
        if dependencies.isTooHot() { throw LookBackTooHot() }
        let transcript = try await dependencies.transcriber.transcript(
          ofFileAt: chunk.fileURL, windows: [chunk.localWindow])
        try Task.checkCancellation()
        let shifted = transcript.words.map {
          TranscriptWord(
            text: $0.text, start: $0.start + chunk.startOffset, end: $0.end + chunk.startOffset)
        }
        joined = Self.join(shifted, before: joined)
        await events(.chunk(chunk, words: joined))
      }
      await finish()
      return joined
    } catch {
      await finish()
      throw error
    }
  }

  private func finish() async {
    await dependencies.gate.release()
    await dependencies.resumeTranscripts()
  }

  /// Puts an earlier chunk's words before the later ones, dropping the earlier chunk's last word
  /// when the later chunk's first word is a second recognition of it.
  static func join(_ earlier: [TranscriptWord], before later: [TranscriptWord]) -> [TranscriptWord] {
    var earlier = earlier
    if let last = earlier.last, let first = later.first, TranscriptJoin.repeats(first, last) {
      earlier.removeLast()
    }
    return earlier + later
  }
}
