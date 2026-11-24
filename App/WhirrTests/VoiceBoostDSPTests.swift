import Foundation
import Testing

@testable import Whirr

/// The Voice Boost chain on generated signals. Each frequency or level claim is measured with only
/// the stage under test enabled, so one stage never colours another's number. Nonisolated: seconds
/// of audio processed on the main actor would stall the suites that share it.
@Suite("Voice Boost DSP")
nonisolated struct VoiceBoostDSPTests {

  private static let rate = 44_100.0

  // MARK: - Frequency stages

  @Test("the high-pass alone takes 40 Hz down by at least 15 dB, 80 Hz by 4 dB, and leaves 1 kHz alone")
  func highPassResponse() throws {
    let low = try gainDB(stages: .highPass, frequency: 40)
    let rumble = try gainDB(stages: .highPass, frequency: 80)
    let mid = try gainDB(stages: .highPass, frequency: 1_000)
    #expect(low <= -15)
    #expect(rumble <= -4)
    #expect(abs(mid) <= 0.5)
  }

  @Test("the low-mid cut alone takes 2.5 dB off 280 Hz and leaves 1 kHz and 3 kHz alone")
  func lowMidCutResponse() throws {
    let centre = try gainDB(stages: .lowMidCut, frequency: 280)
    let mid = try gainDB(stages: .lowMidCut, frequency: 1_000)
    let high = try gainDB(stages: .lowMidCut, frequency: 3_000)
    #expect(abs(centre - -2.5) <= 0.5)
    #expect(abs(mid) <= 0.5)
    #expect(abs(high) <= 0.5)
  }

  @Test("the presence lift alone adds 5 dB at 3 kHz and almost nothing at 300 Hz")
  func presenceResponse() throws {
    let centre = try gainDB(stages: .presence, frequency: 3_000)
    let low = try gainDB(stages: .presence, frequency: 300)
    #expect(abs(centre - 5) <= 0.5)
    #expect(abs(low) <= 0.5)
  }

  // MARK: - Dynamics

  @Test("the compressor leaves quiet speech below threshold at makeup gain")
  func compressorBelowThreshold() throws {
    let input = sine(frequency: 1_000, amplitude: 0.01, seconds: 1)  // -40 dBFS peak
    let output = try process([input], stages: .compressor)
    let gain = Self.db(peak(output[0], lastSeconds: 0.5) / 0.01)
    #expect(abs(gain - 4) <= 0.2)
  }

  @Test("the compressor brings a full-scale sine to about -11.7 dBFS RMS after makeup")
  func compressorAboveThreshold() throws {
    // A full-scale sine is -3 dBFS RMS: 19 dB over the -22 dBFS threshold at 3:1 is -12.7 dB,
    // and +4 dB makeup leaves -11.7 dBFS RMS. The RMS detector settles close to that.
    let input = sine(frequency: 1_000, amplitude: 1, seconds: 2)
    let output = try process([input], stages: .compressor)
    let level = Self.db(rms(tail(output[0], seconds: 0.5)))
    #expect(abs(level - -11.7) <= 1)
  }

  // MARK: - Loudness through the whole chain

  /// Podcast speech sits around -18 dBFS RMS and loudly mastered shows nearer -12. The switch
  /// should change clarity more than loudness, so typical speech stays within a few dB of its own
  /// level: slightly up at -18, and a loud show no more than 3.5 dB down.
  @Test(
    "the whole chain keeps speech-level audio near its own level",
    arguments: [(rmsDB: -18.0, atLeast: 0.0, atMost: 3.5), (rmsDB: -12.0, atLeast: -3.5, atMost: 0.0)])
  func chainStaysNearLevel(rmsDB: Double, atLeast: Double, atMost: Double) throws {
    let change = try chainGainDB(rmsDB: rmsDB)
    #expect(change >= atLeast)
    #expect(change <= atMost)
  }

  @Test("the whole chain lifts quiet passages more than loud ones")
  func chainLevels() throws {
    let quiet = try chainGainDB(rmsDB: -30)
    let loud = try chainGainDB(rmsDB: -12)
    #expect(quiet - loud >= 4)
  }

  @Test("the compressor applies one gain to every channel")
  func compressorIsLinked() throws {
    let loud = sine(frequency: 1_000, amplitude: 1, seconds: 1)
    let quiet = sine(frequency: 1_000, amplitude: 0.01, seconds: 1)
    let output = try process([loud, quiet], stages: .compressor)
    for index in stride(from: 0, to: loud.count, by: 7) where abs(quiet[index]) > 1e-4 {
      let loudGain = output[0][index] / loud[index]
      let quietGain = output[1][index] / quiet[index]
      #expect(abs(loudGain - quietGain) <= 1e-3 * max(abs(loudGain), 1e-3))
    }
  }

  @Test("no output sample exceeds the -1 dBFS ceiling, even for +6 dBFS input")
  func ceilingHolds() throws {
    var generator = Noise(seed: 7)
    let frames = Int(Self.rate)
    let tone = sine(frequency: 1_000, amplitude: 2, seconds: 1)
    let noisy = (0..<frames).map { tone[$0] * 0.5 + generator.next() * 2 }
    let output = try process([tone, noisy], stages: .all)
    let ceiling = Float(pow(10, -1.0 / 20))
    let loudest = output.flatMap { $0 }.map(abs).max() ?? 0
    #expect(loudest <= ceiling + 1e-6)
  }

  // MARK: - Switching

  @Test("switched off from the start, the processor returns its input bit for bit")
  func bypassIsBitExact() throws {
    var generator = Noise(seed: 3)
    let input = (0..<20_000).map { _ in generator.next() }
    var dsp = try makeDSP(channels: 1, stages: .all)
    dsp.isEnabled = false
    let output = run(&dsp, [input], block: 512)
    #expect(output[0] == input)
  }

  @Test("switching on ramps from dry to processed audio with no step")
  func switchingOnRamps() throws {
    let half = Int(Self.rate / 2)
    let input = sine(frequency: 220, amplitude: 0.1, seconds: 1)
    var dsp = try makeDSP(channels: 1, stages: .all)
    dsp.isEnabled = false
    let first = run(&dsp, [Array(input[..<half])], block: 512)[0]
    dsp.isEnabled = true
    let second = run(&dsp, [Array(input[half...])], block: 512)[0]
    let output = first + second

    let window = Int(0.05 * Self.rate)
    let transition = Array(output[(half - 1)..<(half + window)])
    let tail = Array(output[(output.count - Int(0.2 * Self.rate))...])
    let bound = max(maxStep(Array(input[..<half])), maxStep(tail)) + 0.001
    #expect(maxStep(transition) <= bound)
    // And the processed audio really is different from the dry signal by the end.
    let dryTail = Array(input[(input.count - tail.count)...])
    #expect(abs(Self.db(rms(tail) / rms(dryTail))) >= 1)
  }

  @Test("switching off ramps back and then returns the input bit for bit")
  func switchingOffReturnsToBypass() throws {
    let input = sine(frequency: 220, amplitude: 0.1, seconds: 1)
    let quarter = Int(Self.rate / 4)
    var dsp = try makeDSP(channels: 1, stages: .all)
    dsp.isEnabled = true
    _ = run(&dsp, [Array(input[..<quarter])], block: 512)
    dsp.isEnabled = false
    _ = run(&dsp, [Array(input[quarter..<(2 * quarter)])], block: 512)
    let later = Array(input[(2 * quarter)...])
    let output = run(&dsp, [later], block: 512)
    #expect(output[0] == later)
  }

  // MARK: - State and blocks

  @Test("reset leaves the processor exactly as a fresh one")
  func resetMatchesFresh() throws {
    var generator = Noise(seed: 11)
    let noise = (0..<10_000).map { _ in generator.next() }
    let signal = sine(frequency: 500, amplitude: 0.5, seconds: 0.5)

    var used = try makeDSP(channels: 1, stages: .all)
    used.isEnabled = true
    _ = run(&used, [noise], block: 512)
    used.reset()
    let afterReset = run(&used, [signal], block: 512)

    var fresh = try makeDSP(channels: 1, stages: .all)
    fresh.isEnabled = true
    let fromFresh = run(&fresh, [signal], block: 512)
    #expect(afterReset == fromFresh)
  }

  @Test("output does not depend on how the audio is split into blocks")
  func blockSizeInvariant() throws {
    var generator = Noise(seed: 5)
    let tone = sine(frequency: 700, amplitude: 0.6, seconds: 1)
    let input = tone.map { $0 + generator.next() * 0.2 }
    var small = try makeDSP(channels: 1, stages: .all, maxFrames: 1_024)
    small.isEnabled = true
    let bySmallBlocks = run(&small, [input], block: 256)
    var chunked = try makeDSP(channels: 1, stages: .all, maxFrames: 1_024)
    chunked.isEnabled = true
    // Larger than maxFrames: the processor must split it itself.
    let byOneCall = run(&chunked, [input], block: 8_192)
    let difference = zip(bySmallBlocks[0], byOneCall[0]).map { abs($0 - $1) }.max() ?? 0
    #expect(difference <= 1e-5)
  }

  @Test("six channels are filtered independently")
  func sixChannels() throws {
    let frequencies: [Double] = [40, 1_000, 40, 1_000, 40, 1_000]
    let input = frequencies.map { sine(frequency: $0, amplitude: 0.5, seconds: 2) }
    let output = try process(input, stages: .highPass)
    for (channel, frequency) in frequencies.enumerated() {
      let gain = Self.db(rms(tail(output[channel], seconds: 1)) / rms(tail(input[channel], seconds: 1)))
      if frequency == 40 {
        #expect(gain <= -11.5)
      } else {
        #expect(abs(gain) <= 0.5)
      }
    }
  }

  @Test("a processor cannot be built without channels, frames or a sample rate")
  func rejectsEmptyFormats() {
    // The processor is noncopyable, so each result is compared before the macro sees it.
    let noChannels = VoiceBoostDSP(sampleRate: Self.rate, channelCount: 0, maxFrames: 512) == nil
    let noFrames = VoiceBoostDSP(sampleRate: Self.rate, channelCount: 2, maxFrames: 0) == nil
    let noRate = VoiceBoostDSP(sampleRate: 0, channelCount: 2, maxFrames: 512) == nil
    #expect(noChannels)
    #expect(noFrames)
    #expect(noRate)
  }

  // MARK: - Helpers

  private func makeDSP(
    channels: Int, stages: VoiceBoostStages, maxFrames: Int = 4_096
  ) throws -> VoiceBoostDSP {
    guard
      let dsp = VoiceBoostDSP(
        sampleRate: Self.rate, channelCount: channels, maxFrames: maxFrames, stages: stages)
    else {
      throw SetupFailure()
    }
    return dsp
  }

  private struct SetupFailure: Error {}

  /// Runs the whole of `input` through a processor that is on from the start.
  private func process(_ input: [[Float]], stages: VoiceBoostStages) throws -> [[Float]] {
    var dsp = try makeDSP(channels: input.count, stages: stages)
    dsp.isEnabled = true
    return run(&dsp, input, block: 512)
  }

  /// Feeds `input` through `dsp` in blocks of `block` frames, in place, the way a tap does.
  private func run(_ dsp: inout VoiceBoostDSP, _ input: [[Float]], block: Int) -> [[Float]] {
    let frames = input[0].count
    let buffers = input.map { channel -> UnsafeMutablePointer<Float> in
      let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
      buffer.initialize(from: channel, count: frames)
      return buffer
    }
    defer { for buffer in buffers { buffer.deallocate() } }
    let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: buffers.count)
    defer { pointers.deallocate() }
    var start = 0
    while start < frames {
      let count = min(block, frames - start)
      for (channel, buffer) in buffers.enumerated() {
        (pointers + channel).initialize(to: buffer + start)
      }
      dsp.process(pointers, frameCount: count)
      start += count
    }
    return buffers.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
  }

  /// Steady-state gain of one stage at one frequency, from the RMS of the last second of two.
  private func gainDB(stages: VoiceBoostStages, frequency: Double) throws -> Double {
    let input = sine(frequency: frequency, amplitude: 0.5, seconds: 2)
    let output = try process([input], stages: stages)
    return Self.db(rms(tail(output[0], seconds: 1)) / rms(tail(input, seconds: 1)))
  }

  /// Steady-state level change of the whole chain on a 1 kHz sine at `rmsDB` dBFS RMS.
  private func chainGainDB(rmsDB: Double) throws -> Double {
    let amplitude = Float(pow(10, rmsDB / 20) * 2.0.squareRoot())
    let input = sine(frequency: 1_000, amplitude: amplitude, seconds: 2)
    let output = try process([input], stages: .all)
    return Self.db(rms(tail(output[0], seconds: 1)) / rms(tail(input, seconds: 1)))
  }

  private func sine(frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
    let frames = Int(seconds * Self.rate)
    return (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / Self.rate)) }
  }

  private func tail(_ samples: [Float], seconds: Double) -> [Float] {
    Array(samples[(samples.count - Int(seconds * Self.rate))...])
  }

  private func peak(_ samples: [Float], lastSeconds: Double) -> Float {
    tail(samples, seconds: lastSeconds).map(abs).max() ?? 0
  }

  private func rms(_ samples: [Float]) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
  }

  private func maxStep(_ samples: [Float]) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
  }

  private static func db(_ ratio: Float) -> Double { 20 * log10(Double(ratio)) }

  /// A small deterministic noise source in -1...1, so failures reproduce.
  private struct Noise {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Float(Int64(bitPattern: state >> 1) % 2_000_001 - 1_000_000) / 1_000_000
    }
  }
}
