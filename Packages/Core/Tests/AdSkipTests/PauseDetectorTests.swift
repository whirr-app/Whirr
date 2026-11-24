import Foundation
import Testing

@testable import AdSkip

@Suite struct PauseDetectorTests {
  /// One stretch of synthetic audio: a 1 kHz tone at an RMS level in dBFS, or exact silence.
  private struct Segment {
    let seconds: Double
    let level: Double?
    var frequency: Double = 1_000
  }

  private func tone(_ seconds: Double, _ level: Double) -> Segment {
    Segment(seconds: seconds, level: level)
  }

  private func silence(_ seconds: Double) -> Segment { Segment(seconds: seconds, level: nil) }

  /// Phase-continuous across segments of the same frequency; each segment restarts at phase 0.
  private func render(_ segments: [Segment], rate: Double, phaseOffset: Double = 0) -> [Float] {
    var out: [Float] = []
    for segment in segments {
      let count = Int((segment.seconds * rate).rounded())
      guard let level = segment.level else {
        out += Array(repeating: 0, count: count)
        continue
      }
      let amplitude = pow(10, level / 20) * 2.0.squareRoot()
      out += (0..<count).map {
        Float(amplitude * sin(2 * Double.pi * segment.frequency * Double($0) / rate + phaseOffset))
      }
    }
    return out
  }

  private func detect(
    _ channels: [[Float]], rate: Double = 44_100, chunks: [Int] = []
  ) -> PauseRuns {
    var detector = PauseDetector(sampleRate: rate)
    let total = channels[0].count
    var offset = 0
    for size in chunks + [total] {
      let end = min(total, offset + size)
      if end > offset {
        let slices = channels.map { Array($0[offset..<end]) }
        withBuffers(slices) { detector.consume($0) }
      }
      offset = end
    }
    return detector.finish()
  }

  private func withBuffers(_ arrays: [[Float]], _ body: ([UnsafeBufferPointer<Float>]) -> Void) {
    func recurse(_ index: Int, _ acc: [UnsafeBufferPointer<Float>]) {
      if index == arrays.count {
        body(acc)
        return
      }
      arrays[index].withUnsafeBufferPointer { recurse(index + 1, acc + [$0]) }
    }
    recurse(0, [])
  }

  private func expectRuns(
    _ actual: [PauseRun], _ expected: [(Double, Double)], tolerance: Double = 0.011,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(actual.count == expected.count, sourceLocation: sourceLocation)
    for (run, want) in zip(actual, expected) {
      #expect(abs(run.start - want.0) <= tolerance, sourceLocation: sourceLocation)
      #expect(abs(run.end - want.1) <= tolerance, sourceLocation: sourceLocation)
    }
  }

  @Test func revisionIsThree() {
    // 2: the alignment check places short iPhone reads, so rows stored `misaligned` by revision 1
    // are analysed again.
    // 3: `misaligned` rows keep their runs, so revision 2's, stored without, are analysed again.
    #expect(PauseDetector.revision == 3)
    #expect(detect([render([tone(0.5, -20)], rate: 44_100)]).revision == 3)
  }

  @Test func toneWithGapsGivesRunsAtGapPositions() {
    for rate in [44_100.0, 48_000.0] {
      let samples = render(
        [tone(1, -20), silence(0.5), tone(1, -20), silence(0.4), tone(1, -20)], rate: rate)
      let runs = detect([samples], rate: rate)
      expectRuns(runs.runsBelow40, [(1.0, 1.5), (2.5, 2.9)])
      expectRuns(runs.runsBelow46, [(1.0, 1.5), (2.5, 2.9)])
      #expect(abs(runs.duration - 3.9) < 1e-6)
    }
  }

  @Test func runEdgesAreFrameBoundaries() {
    let rate = 44_100.0
    let runs = detect([render([tone(1, -20), silence(0.5), tone(1, -20)], rate: rate)])
    for run in runs.runsBelow40 {
      let frames = run.start * rate / 441
      #expect(abs(frames - frames.rounded()) < 1e-6)
    }
  }

  @Test func breakOfThirtyMillisecondsIsJoined() {
    // A 30 ms burst splits the silence into two 0.2 s halves. The burst frames straddle at most
    // one extra frame at each edge, so use 20 ms of tone which is certain to cost at most 3 frames.
    let samples = render(
      [tone(0.5, -20), silence(0.2), tone(0.02, -20), silence(0.2), tone(0.5, -20)], rate: 44_100)
    let runs = detect([samples])
    expectRuns(runs.runsBelow40, [(0.5, 0.92)])
  }

  @Test func breakOfFortyMillisecondsIsNotJoined() {
    // Exact frame alignment: 0.5 s is 50 frames, so a 40 ms (4 frame) tone break is four frames.
    let samples = render(
      [tone(0.5, -20), silence(0.2), tone(0.04, -20), silence(0.2), tone(0.5, -20)], rate: 44_100)
    let runs = detect([samples])
    expectRuns(runs.runsBelow40, [(0.5, 0.7), (0.74, 0.94)])
  }

  @Test func runsShorterThanAHundredMillisecondsAreDropped() {
    let samples = render(
      [tone(0.5, -20), silence(0.09), tone(0.5, -20), silence(0.1), tone(0.5, -20)], rate: 44_100)
    let runs = detect([samples])
    expectRuns(runs.runsBelow40, [(1.09, 1.19)])
  }

  @Test func levelBetweenThresholdsAppearsOnlyBelowMinusForty() {
    let samples = render([tone(1, -20), tone(0.5, -43), tone(1, -20)], rate: 44_100)
    let runs = detect([samples])
    expectRuns(runs.runsBelow40, [(1.0, 1.5)])
    #expect(runs.runsBelow46.isEmpty)
  }

  @Test func levelBelowMinusFortySixAppearsInBoth() {
    let samples = render([tone(1, -20), tone(0.5, -50), tone(1, -20)], rate: 44_100)
    let runs = detect([samples])
    expectRuns(runs.runsBelow40, [(1.0, 1.5)])
    expectRuns(runs.runsBelow46, [(1.0, 1.5)])
  }

  @Test func highPassRemovesLowRumble() {
    // A 30 Hz tone at -30 dB would fail -40 dB unfiltered; the 80 Hz high-pass takes it to about
    // -47 dB.
    var rumble = tone(0.6, -30)
    rumble.frequency = 30
    var samples = render([tone(1, -20)], rate: 44_100)
    samples += render([rumble], rate: 44_100)
    samples += render([tone(1, -20)], rate: 44_100)
    let runs = detect([samples])
    expectRuns(runs.runsBelow40, [(1.0, 1.6)], tolerance: 0.03)
  }

  @Test func levelIsMeasuredAsRMSNotPeak() {
    // A -38 dB RMS tone (peak about -35 dB) is above -40 dB and must not be a pause.
    let runs = detect([render([tone(1, -20), tone(0.5, -38), tone(1, -20)], rate: 44_100)])
    #expect(runs.runsBelow40.isEmpty)
  }

  /// The research's level track (and the listening samples cut from it) rounded levels to whole
  /// dB and tested `rounded < threshold + 0.5`, so its -40 and -46 dB were -39.5 and -45.5 dB.
  @Test func thresholdsAreTheResearchTracksEffectiveLevels() {
    for (level, in40, in46) in [(-39.8, true, false), (-39.2, false, false), (-45.8, true, true), (-45.2, true, false)]
    {
      let runs = detect([render([tone(1, -20), tone(0.5, level), tone(1, -20)], rate: 44_100)])
      #expect(runs.runsBelow40.isEmpty == !in40, "\(level) dB")
      #expect(runs.runsBelow46.isEmpty == !in46, "\(level) dB")
    }
  }

  /// Channels are summed at equal power, (L + R) / sqrt 2, as ffmpeg's stereo-to-mono downmix in
  /// the research did: identical channels read 3 dB above either one.
  @Test func channelsAreMixedAtEqualPower() {
    let rate = 44_100.0
    let quiet = render([tone(1, -20), tone(0.5, -42), tone(1, -20)], rate: rate)
    expectRuns(detect([quiet]).runsBelow40, [(1.0, 1.5)])
    #expect(detect([quiet, quiet]).runsBelow40.isEmpty)

    let gapBoth = render([tone(1, -20), silence(0.5), tone(1, -20)], rate: rate)
    expectRuns(detect([gapBoth, gapBoth]).runsBelow40, [(1.0, 1.5)])

    // Silent on the left only: the mix is 3 dB down, nowhere near a pause.
    let left = render([tone(1, -20), silence(0.5), tone(1, -20)], rate: rate)
    let right = render([tone(2.5, -20)], rate: rate)
    #expect(detect([left, right]).runsBelow40.isEmpty)

    // Opposite polarity cancels in the sum, so the whole file is a single pause.
    let steady = render([tone(1, -20)], rate: rate)
    let runs = detect([steady, steady.map { -$0 }])
    expectRuns(runs.runsBelow40, [(0, 1)], tolerance: 0.02)
  }

  @Test func resultIsIndependentOfChunking() {
    let rate = 48_000.0
    let samples = render(
      [tone(0.7, -20), silence(0.3), tone(0.04, -20), silence(0.2), tone(0.5, -45), tone(0.4, -20)],
      rate: rate)
    let whole = detect([samples], rate: rate)
    let odd = detect([samples], rate: rate, chunks: [1, 7, 333, 479, 480, 481, 5_000, 12_345, 3])
    let tiny = detect([Array(samples[0..<20_000])], rate: rate, chunks: Array(repeating: 97, count: 60))
    #expect(whole == odd)
    #expect(!whole.runsBelow40.isEmpty)
    #expect(tiny == detect([Array(samples[0..<20_000])], rate: rate))
  }

  @Test func trailingRunIsRecordedAtEndOfAudio() {
    let samples = render([tone(1, -20), silence(0.5)], rate: 44_100)
    let runs = detect([samples])
    expectRuns(runs.runsBelow40, [(1.0, 1.5)])
    #expect(abs((runs.runsBelow40.last?.end ?? 0) - runs.duration) < 1e-9)
  }

  @Test func shortTrailingRunIsDropped() {
    let runs = detect([render([tone(1, -20), silence(0.05)], rate: 44_100)])
    #expect(runs.runsBelow40.isEmpty)
  }

  @Test func finalPartialFrameIsEvaluatedAsAFrameOfItsOwn() {
    // 1 s of tone, 0.5 s of silence and 3 extra silent samples: the partial frame is silent and
    // extends the run to the exact end of the audio.
    let samples = render([tone(1, -20), silence(0.5)], rate: 44_100) + [0, 0, 0]
    let runs = detect([samples])
    #expect(runs.runsBelow40.count == 1)
    #expect(runs.runsBelow40[0].end == Double(samples.count) / 44_100)
    #expect(runs.duration == Double(samples.count) / 44_100)
  }

  @Test func emptyAudioGivesNoRuns() {
    var detector = PauseDetector(sampleRate: 44_100)
    let runs = detector.finish()
    #expect(runs.runsBelow40.isEmpty && runs.runsBelow46.isEmpty)
    #expect(runs.duration == 0)
  }

  // MARK: - Encoding

  private func sample() -> PauseRuns {
    PauseRuns(
      revision: 1, duration: 3_601.25,
      runsBelow40: [PauseRun(start: 1.5, end: 2.25), PauseRun(start: 10, end: 10.5)],
      runsBelow46: [PauseRun(start: 1.5, end: 2.0)])
  }

  @Test func encodingRoundTrips() throws {
    let runs = sample()
    let decoded = try #require(PauseRuns(encoded: runs.encoded()))
    #expect(decoded == runs)
  }

  @Test func encodingHasTheDocumentedLayout() {
    let data = sample().encoded()
    // version(1) + revision(4) + duration(8) + two counts(8) + three Float32 pairs(24)
    #expect(data.count == 1 + 4 + 8 + 8 + 24)
    #expect(data[0] == 1)
    #expect(Array(data[1..<5]) == [1, 0, 0, 0])
  }

  @Test func emptyRunsRoundTrip() throws {
    let runs = PauseRuns(revision: 1, duration: 0, runsBelow40: [], runsBelow46: [])
    #expect(try #require(PauseRuns(encoded: runs.encoded())) == runs)
  }

  @Test func decodingRejectsTruncatedAndMalformedData() {
    let data = sample().encoded()
    for length in 0..<data.count {
      #expect(PauseRuns(encoded: data.prefix(length)) == nil, "length \(length)")
    }
    #expect(PauseRuns(encoded: data + [0]) == nil)
    var wrongVersion = data
    wrongVersion[0] = 2
    #expect(PauseRuns(encoded: wrongVersion) == nil)
    // A count that claims more runs than the data holds.
    var hugeCount = data
    hugeCount[13] = 0xFF
    hugeCount[14] = 0xFF
    hugeCount[15] = 0xFF
    hugeCount[16] = 0x7F
    #expect(PauseRuns(encoded: hugeCount) == nil)
  }

  @Test func decodingWorksOnASlicedData() throws {
    let runs = sample()
    let padded = Data([9, 9, 9]) + runs.encoded()
    #expect(try #require(PauseRuns(encoded: padded.dropFirst(3))) == runs)
  }
}
