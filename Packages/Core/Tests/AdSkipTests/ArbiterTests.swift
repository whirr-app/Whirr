import Testing

@testable import AdSkip

@Suite struct ArbiterTests {
  private func transcript(duration: Double, words: [TranscriptWord] = []) -> Transcript {
    Transcript(words: words, duration: duration)
  }

  @Test func stepsAreFiveSecondsTruncatedAtDuration() {
    let steps = Arbiter.steps(for: transcript(duration: 12))
    #expect(steps.map(\.start) == [0, 5, 10])
    #expect(steps.map(\.end) == [5, 10, 12])
    #expect(Arbiter.steps(for: transcript(duration: 10)).count == 2)
    #expect(Arbiter.steps(for: transcript(duration: 0)).isEmpty)
  }

  @Test func emptyContextIsAnUnderscore() {
    let steps = Arbiter.steps(for: transcript(duration: 10))
    #expect(steps.map(\.text) == ["_", "_"])
  }

  @Test func textUsesRawWordsAndTheContextWindow() {
    // Step [5, 10): window midpoint range is [-2.5, 17.5). Midpoint = (start + end) / 2.
    let words = [
      TranscriptWord(text: "Raw,", start: 0, end: 1),  // midpoint 0.5
      TranscriptWord(text: "Edge", start: 17, end: 18),  // midpoint 17.5: excluded (strict <)
      TranscriptWord(text: "Last", start: 16.9, end: 17.7),  // midpoint 17.3: included
    ]
    let steps = Arbiter.steps(for: transcript(duration: 30, words: words))
    #expect(steps[1].text == "Raw, Last")
    // Step [0, 5): window [-7.5, 12.5). A word with midpoint exactly -7.5 would be included.
    let early = [
      TranscriptWord(text: "Left", start: -8, end: -7),  // midpoint -7.5: included (<=)
      TranscriptWord(text: "Right", start: 12, end: 13),  // midpoint 12.5: excluded
    ]
    let first = Arbiter.steps(for: transcript(duration: 30, words: early))[0]
    #expect(first.text == "Left")
  }

  /// The sweep over time-ordered words and the plain filter must agree, including when a long
  /// word's midpoint falls after a later word's (the filter keeps transcript order).
  @Test func stepTextIsTheSameWhenMidpointsAreOutOfOrder() {
    let words = [
      TranscriptWord(text: "long", start: 0, end: 20),  // midpoint 10
      TranscriptWord(text: "short", start: 1, end: 2),  // midpoint 1.5
      TranscriptWord(text: "late", start: 30, end: 31),
    ]
    let steps = Arbiter.steps(for: transcript(duration: 40, words: words))
    // Step 1's window [-2.5, 17.5) holds both midpoints; the filter keeps transcript order.
    #expect(steps[1].text == "long short")
    #expect(steps[4].text == "late")
    let ordered = Fixture.words("w", count: 200, step: 0.37, length: 0.3)
    let fast = Arbiter.steps(for: transcript(duration: 80, words: ordered))
    let slow = (0..<16).map { i -> String in
      let s = Double(i) * 5
      let e = min(s + 5, 80)
      let text = ordered.filter {
        let m = ($0.start + $0.end) / 2
        return s - 7.5 <= m && m < e + 7.5
      }.map(\.text)
      return text.isEmpty ? "_" : text.joined(separator: " ")
    }
    #expect(fast.map(\.text) == slow)
  }

  @Test func overlappingStepsIsStrictOnBothEnds() {
    let steps = Arbiter.steps(for: transcript(duration: 30))
    // [5, 10] touches step 0 only at 5 (excluded) and step 2 only at 10 (excluded).
    #expect(Arbiter.stepIndices(overlapping: [CandidateRange(start: 5, end: 10)], in: steps) == [1])
    let both = [CandidateRange(start: 4.9, end: 10.1), CandidateRange(start: 9, end: 16)]
    #expect(Arbiter.stepIndices(overlapping: both, in: steps) == [0, 1, 2, 3])
  }

  @Test func keepsAtExactlyTheThreshold() {
    let t = transcript(duration: 10)
    let steps = Arbiter.steps(for: t)
    let candidate = CandidateRange(start: 0, end: 10)
    let at = Arbiter.keep([candidate], transcript: t, steps: steps, probabilities: [0: 0.06, 1: 0.06])
    #expect(at.count == 1)
    #expect(at[0].meanAdProbability == 0.06)
    let below = Arbiter.keep(
      [candidate], transcript: t, steps: steps, probabilities: [0: 0.059, 1: 0.06])
    #expect(below.isEmpty)
  }

  @Test func vetoesACandidateWithNoSteps() {
    let t = transcript(duration: 10)
    let steps = Arbiter.steps(for: t)
    let off = CandidateRange(start: 20, end: 30)
    #expect(Arbiter.keep([off], transcript: t, steps: steps, probabilities: [:]).isEmpty)
  }

  @Test func endsItemWhenNoWordStartsAfterTheRange() {
    let words = [
      TranscriptWord(text: "a", start: 0, end: 1),
      TranscriptWord(text: "b", start: 8, end: 9),
    ]
    let t = transcript(duration: 10, words: words)
    let steps = Arbiter.steps(for: t)
    let probs = [0: 1.0, 1: 1.0]
    let kept = Arbiter.keep(
      [
        CandidateRange(start: 0, end: 7.9), CandidateRange(start: 0, end: 8),
        CandidateRange(start: 0, end: 10),
      ],
      transcript: t, steps: steps, probabilities: probs)
    #expect(kept.map(\.endsItem) == [false, true, true])
  }

  @Test func pythonSumCompensatesRounding() {
    #expect(Arbiter.pythonSum(Array(repeating: 0.1, count: 10)) == 1.0)
    #expect(Array(repeating: 0.1, count: 10).reduce(0, +) != 1.0)
    #expect(Arbiter.pythonSum([1e100, 1.0, -1e100]) == 1.0)
    #expect(Arbiter.pythonSum([]) == 0)
    #expect(Arbiter.pythonSum([.infinity, 1]) == .infinity)
  }
}
