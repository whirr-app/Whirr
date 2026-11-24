/// One recogniser result run: text with the audio time range it was attributed to.
public struct TimedRun: Sendable, Equatable {
  public let text: String
  public let start: Double
  public let end: Double

  public init(text: String, start: Double, end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}

/// The harness's `AdHarnessSpeech` word split, ported so device transcripts are built the same way.
public enum WordSplitter {
  /// Splits each run on whitespace. A run holding several words shares its time range out in
  /// proportion to each word's length in Characters. The result is ordered by start with the same
  /// standard-library sort the harness used.
  public static func words(from runs: [TimedRun]) -> [TranscriptWord] {
    var words: [TranscriptWord] = []
    for run in runs {
      let pieces = run.text.split(whereSeparator: \.isWhitespace).map(String.init)
      guard !pieces.isEmpty else { continue }
      let totalLength = Double(pieces.reduce(0) { $0 + $1.count })
      var cursor = run.start
      for piece in pieces {
        let share = (run.end - run.start) * Double(piece.count) / max(totalLength, 1)
        words.append(TranscriptWord(text: piece, start: cursor, end: cursor + share))
        cursor += share
      }
    }
    return words.sorted { $0.start < $1.start }
  }
}
