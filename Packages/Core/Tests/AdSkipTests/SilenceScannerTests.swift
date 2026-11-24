import Foundation
import Testing

@testable import AdSkip

@Suite struct SilenceScannerTests {
  /// Scans deinterleaved channels, feeding them in the given chunk sizes (the last chunk takes
  /// whatever remains).
  private func scan(
    _ channels: [[Float]], rate: Double = 100, chunks: [Int] = []
  ) -> [Silence] {
    var scanner = SilenceScanner(sampleRate: rate)
    let total = channels[0].count
    var offset = 0
    for size in chunks + [total] {
      let end = min(total, offset + size)
      if end > offset {
        feed(&scanner, channels, offset..<end)
      }
      offset = end
    }
    return scanner.finish()
  }

  private func feed(_ scanner: inout SilenceScanner, _ channels: [[Float]], _ range: Range<Int>) {
    let slices = channels.map { Array($0[range]) }
    withBuffers(slices) { scanner.consume($0) }
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

  private func loud(_ count: Int) -> [Float] { Array(repeating: 0.5, count: count) }
  private func quiet(_ count: Int) -> [Float] { Array(repeating: 0, count: count) }

  @Test func thresholdMatchesMinusThirtyFiveDecibels() {
    #expect(abs(SilenceScanner.threshold - 0.0177827941) < 1e-9)
  }

  @Test func reportsRunOfExactlyMinimumFrames() {
    let samples = loud(10) + quiet(30) + loud(10)
    #expect(scan([samples]) == [Silence(start: 0.1, end: 0.4)])
  }

  @Test func ignoresRunOneFrameShortOfMinimum() {
    let samples = loud(10) + quiet(29) + loud(10)
    #expect(scan([samples]).isEmpty)
  }

  @Test func ignoresShortRunOpenAtEndOfStream() {
    #expect(scan([loud(10) + quiet(29)]).isEmpty)
  }

  @Test func valueAtThresholdIsNotSilent() {
    let atThreshold = Float(SilenceScanner.threshold)
    // Float rounding may land either side of the Double threshold, so compare via Double.
    let notSilent =
      Double(atThreshold) < SilenceScanner.threshold ? atThreshold.nextUp : atThreshold
    #expect(Double(notSilent) >= SilenceScanner.threshold)
    #expect(scan([quiet(5) + Array(repeating: notSilent, count: 30) + quiet(5)]).isEmpty)
  }

  @Test func valueJustBelowThresholdIsSilent() {
    var below = Float(SilenceScanner.threshold)
    while Double(below) >= SilenceScanner.threshold { below = below.nextDown }
    #expect(scan([Array(repeating: below, count: 30)]) == [Silence(start: 0, end: 0.3)])
  }

  @Test func negativeValuesUseAbsoluteValue() {
    let small: Float = -0.001
    let large: Float = -0.5
    #expect(scan([Array(repeating: small, count: 30)]) == [Silence(start: 0, end: 0.3)])
    #expect(scan([Array(repeating: large, count: 40)]).isEmpty)
  }

  @Test func oneLoudChannelBreaksSilence() {
    let left = quiet(100)
    var right = quiet(100)
    right[50] = 0.5
    let result = scan([left, right])
    // 50 silent frames before the loud one, 49 after: both qualify.
    #expect(result == [Silence(start: 0, end: 0.5), Silence(start: 0.51, end: 1.0)])
  }

  @Test func bothChannelsQuietIsSilent() {
    #expect(scan([quiet(40), quiet(40)]) == [Silence(start: 0, end: 0.4)])
  }

  @Test func runSplitAcrossThreeConsumesGivesOneSilence() {
    let samples = loud(7) + quiet(100) + loud(3)
    // Boundaries at 20 and 60 land inside the silent run.
    let result = scan([samples], chunks: [20, 40])
    #expect(result == [Silence(start: 0.07, end: 1.07)])
  }

  @Test func chunkingNeverChangesTheResult() {
    let samples = loud(5) + quiet(40) + loud(3) + quiet(35) + loud(2) + quiet(12) + loud(4)
    let whole = scan([samples])
    #expect(whole.count == 2)
    for size in [1, 2, 3, 7, 13, 31] {
      let chunks = Array(repeating: size, count: samples.count / size + 1)
      #expect(scan([samples], chunks: chunks) == whole)
    }
  }

  @Test func silenceAtStartStartsAtZero() {
    #expect(scan([quiet(50) + loud(10)]) == [Silence(start: 0, end: 0.5)])
  }

  @Test func silenceOpenAtEndEndsAtTotalFrames() {
    #expect(scan([loud(10) + quiet(50)]) == [Silence(start: 0.1, end: 0.6)])
  }

  @Test func severalSilencesComeBackInTimeOrder() {
    let samples = quiet(30) + loud(5) + quiet(40) + loud(5) + quiet(31)
    let result = scan([samples], chunks: [17, 29])
    #expect(
      result == [
        Silence(start: 0, end: 0.3),
        Silence(start: 0.35, end: 0.75),
        Silence(start: 0.8, end: 1.11),
      ])
  }

  @Test func emptyStreamHasNoSilences() {
    var scanner = SilenceScanner(sampleRate: 100)
    #expect(scanner.finish().isEmpty)
  }

  @Test func toneThenSilenceAtCdRate() {
    let rate = 44_100
    var samples = [Float]()
    samples.reserveCapacity(rate * 2)
    for index in 0..<rate {
      samples.append(Float(0.5 * sin(2 * Double.pi * 440 * Double(index) / Double(rate))))
    }
    samples += Array(repeating: 0, count: rate)
    // The tone's last sample is 0.5 × sin(−2π × 440 / 44100) ≈ −0.031, above the threshold, so
    // the run starts at exactly 1 s. It stays open to the end of the stream and ends at 2 s.
    let result = scan([samples], rate: Double(rate), chunks: [4096, 10_000])
    #expect(result == [Silence(start: 1, end: 2)])
  }
}
