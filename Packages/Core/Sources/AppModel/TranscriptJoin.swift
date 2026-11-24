import AdSkip
import Foundation

/// Repair at the join between two separate recognitions of neighbouring audio. The slice padding
/// and the midpoint rule decide which side keeps a word, but a word cut by the join can be
/// recognised on both sides with slightly different times, and so be kept twice.
enum TranscriptJoin {
  /// Two recognitions either side of a join can both keep a word cut by it: the same text,
  /// overlapping in time.
  static func repeats(_ word: TranscriptWord, _ previous: TranscriptWord) -> Bool {
    word.start < previous.end
      && word.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        == previous.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
  }
}
