import Foundation

@testable import AdSkip

/// Synthetic fixtures: made-up words at a fixed cadence.
enum Fixture {
  /// `count` words named `prefix0`, `prefix1`, …; normalisation keeps the digits, so each is distinct.
  static func words(
    _ prefix: String, count: Int, from start: Double = 0, step: Double = 0.5, length: Double = 0.4
  ) -> [TranscriptWord] {
    (0..<count).map { i in
      let s = start + Double(i) * step
      return TranscriptWord(text: "\(prefix)\(i)", start: s, end: s + length)
    }
  }

  static func prepared(
    _ words: [TranscriptWord], silences: [Silence] = [], duration: Double? = nil
  ) -> PreparedTranscript {
    PreparedTranscript(
      transcript: Transcript(words: words, duration: duration ?? ((words.last?.end ?? 0) + 1)),
      silences: silences)
  }
}

/// Deterministic generator for randomized tests.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
