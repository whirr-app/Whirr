import Foundation

/// The two views of one stored transcript. The harness indexed only words inside stage-1 windows,
/// but gave the arbiter and the phrase start the whole transcript; on a device the nearest thing
/// to the whole transcript is every word transcribed so far.
public struct TranscriptViews: Sendable {
  /// Stage-1 words only, by the wholly-inside rule: shingles, the library index, matching, the
  /// repetition stage's edges, learning and Undo tombstones.
  public let index: PreparedTranscript
  /// Every covered word (stage 1, 2a and 2b): the arbiter's steps and keep, and the phrase start.
  public let covered: PreparedTranscript
  /// The stretches transcribed so far.
  public let coverage: [TimeSpan]

  /// `stageOne` nil means the episode was transcribed in full (rules before audio gating, or the
  /// debug switch's whole-file mode): both views are the whole transcript.
  public init(
    transcript: Transcript, silences: [Silence], coverage: [TimeSpan], stageOne: [TimeSpan]?
  ) {
    covered = PreparedTranscript(
      transcript: transcript, silences: silences, stretchStarts: coverage.map(\.start))
    if let stageOne {
      index = PreparedTranscript(
        transcript: Transcript(
          words: TranscriptionWindows.indexWords(transcript.words, stageOne: stageOne),
          duration: transcript.duration),
        silences: silences)
    } else {
      index = covered
    }
    self.coverage = coverage
  }

  /// `endsItem` under partial coverage: a kept range ends the item only when no covered word
  /// follows it and the coverage reaches the end of the file from its end, so a range in an
  /// episode's last window never finishes the episode on the strength of untranscribed audio.
  public func confirmingEndsItem(_ kept: [KeptRange]) -> [KeptRange] {
    kept.map { range in
      guard range.endsItem,
        TranscriptionWindows.covers(coverage, from: range.end, toEndOf: covered.transcript.duration)
          == false
      else { return range }
      return KeptRange(
        start: range.start, end: range.end, meanAdProbability: range.meanAdProbability,
        endsItem: false)
    }
  }
}
