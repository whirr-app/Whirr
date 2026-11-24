import AVFoundation
import AdSkip
import Foundation
import Testing

@testable import Whirr

/// Writes small float WAV files so the decoder is exercised through real `AVAudioFile` decoding.
/// Levels are constant so every silence edge falls on an exact frame. Nonisolated: writing and
/// printing seconds of audio on the main actor would stall the timing tests that share it.
@Suite("Audio file analysis decoder")
nonisolated struct AudioFileAnalysisDecoderTests {

  private static let rate = 8_000.0

  /// Each segment is (seconds, level per channel).
  private func writeFile(_ segments: [(Double, [Float])]) throws -> URL {
    try writeFile(channels: segments[0].1.count, rate: Self.rate) { write in
      for (seconds, levels) in segments {
        let frames = Int((seconds * Self.rate).rounded())
        try write(levels.map { [Float](repeating: $0, count: frames) })
      }
    }
  }

  /// Writes whatever `body` hands its writer: one sample array per channel at a time.
  private func writeFile(
    channels: Int, rate: Double,
    _ body: (_ write: ([[Float]]) throws -> Void) throws -> Void
  ) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("silence-\(UUID().uuidString).wav")
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate,
        channels: AVAudioChannelCount(channels), interleaved: false))
    let file = try AVAudioFile(
      forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    try body { samples in
      let frames = AVAudioFrameCount(samples[0].count)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
      buffer.frameLength = frames
      let data = try #require(buffer.floatChannelData)
      for channel in 0..<channels {
        for frame in 0..<Int(frames) { data[channel][frame] = samples[channel][frame] }
      }
      try file.write(from: buffer)
    }
    return url
  }

  private func silences(_ url: URL) async throws -> [Silence] {
    try await AudioFileAnalysisDecoder().decode(fileAt: url).silences
  }

  @Test("finds a silence between two loud stretches")
  func findsAnInteriorSilence() async throws {
    let url = try writeFile([(1, [0.5, 0.5]), (1, [0, 0]), (1, [0.5, 0.5])])
    defer { try? FileManager.default.removeItem(at: url) }

    let silences = try await silences(url)

    #expect(silences == [Silence(start: 1, end: 2)])
  }

  @Test("closes a silence that runs to the end of the file")
  func closesATrailingSilence() async throws {
    let url = try writeFile([(1, [0.5]), (1.5, [0])])
    defer { try? FileManager.default.removeItem(at: url) }

    let silences = try await silences(url)

    #expect(silences == [Silence(start: 1, end: 2.5)])
  }

  @Test("needs every channel to be quiet")
  func oneLoudChannelIsNotSilence() async throws {
    let url = try writeFile([(1, [0.5, 0.5]), (1, [0, 0.5]), (1, [0.5, 0.5])])
    defer { try? FileManager.default.removeItem(at: url) }

    let silences = try await silences(url)

    #expect(silences.isEmpty)
  }

  @Test("ignores quiet stretches shorter than 0.3 s")
  func shortQuietIsNotSilence() async throws {
    let url = try writeFile([(1, [0.5]), (0.25, [0]), (1, [0.5])])
    defer { try? FileManager.default.removeItem(at: url) }

    let silences = try await silences(url)

    #expect(silences.isEmpty)
  }

  @Test("reads past one buffer without losing frames")
  func spansSeveralBuffers() async throws {
    // 20 s at 8 kHz is 160,000 frames, more than two of the detector's 65,536-frame reads.
    let url = try writeFile([(9, [0.5]), (2, [0]), (9, [0.5])])
    defer { try? FileManager.default.removeItem(at: url) }

    let silences = try await silences(url)

    #expect(silences == [Silence(start: 9, end: 11)])
  }

  @Test("a cancelled task stops with CancellationError", .timeLimit(.minutes(1)))
  func cancellation() async throws {
    let url = try writeFile([(3, [0.5])])
    defer { try? FileManager.default.removeItem(at: url) }

    // The task cancels itself, so the decode starts already cancelled with no wait.
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AudioFileAnalysisDecoder().decode(fileAt: url)
    }

    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test("throws for a file that is not audio")
  func nonAudioThrows() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("silence-\(UUID().uuidString).mp3")
    try Data("not audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: (any Error).self) {
      try await AudioFileAnalysisDecoder().decode(fileAt: url)
    }
  }

  // MARK: - Audio prints

  /// A tone sweep with noise, so every band's energy moves.
  private static func sweep(seconds: Double, rate: Double, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<Int(seconds * rate)).map { i in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let noise = Double(state >> 40) / Double(1 << 24) - 0.5
      let t = Double(i) / rate
      return Float(0.3 * sin(2 * .pi * (400 + 200 * t) * t) + 0.05 * noise)
    }
  }

  @Test("a print has fp.py's frame count at 5,512 Hz, and the duration is the file's")
  func printLengthAndDuration() async throws {
    let rate = 44_100.0
    let samples = Self.sweep(seconds: 10, rate: rate, seed: 1)
    let url = try writeFile(channels: 1, rate: rate) { try $0([samples]) }
    defer { try? FileManager.default.removeItem(at: url) }

    let decoded = try await AudioFileAnalysisDecoder().decode(fileAt: url)

    #expect(abs(decoded.duration - 10) < 1e-9)
    // 55,120 samples at 5,512 Hz give (55,120 - 2,048) / 64 = 829 frames and 828 words; the
    // resampler may round the sample count by a few.
    #expect(abs(decoded.audioPrint.count - 828) <= 1)
  }

  @Test("a stereo file's print is its channels' mean")
  func stereoIsMixedToMono() async throws {
    let rate = 22_050.0
    let samples = Self.sweep(seconds: 6, rate: rate, seed: 2)
    let mono = try writeFile(channels: 1, rate: rate) { try $0([samples]) }
    let stereo = try writeFile(channels: 2, rate: rate) {
      try $0([samples.map { $0 * 1.5 }, samples.map { $0 * 0.5 }])
    }
    defer {
      try? FileManager.default.removeItem(at: mono)
      try? FileManager.default.removeItem(at: stereo)
    }

    let a = try await AudioFileAnalysisDecoder().decode(fileAt: mono).audioPrint.words
    let b = try await AudioFileAnalysisDecoder().decode(fileAt: stereo).audioPrint.words

    #expect(a.count == b.count)
    let differing = zip(a, b).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    #expect(differing <= a.count * 32 / 1000)
  }

  @Test("the Accelerate spectrum gives fp.py's words for the harness's golden signal")
  func accelerateMatchesTheHarness() {
    var printer = AudioPrinter(spectrum: AccelerateSpectrum())
    Self.goldenSignal().withUnsafeBufferPointer { printer.consume($0) }
    let words = printer.finish().words
    #expect(words.count == Self.goldenWords.count)
    let differing = zip(words, Self.goldenWords).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    // Float32 against numpy's float64 may flip a bit whose energy difference is near zero.
    #expect(differing <= 4, "\(differing) bits differ")
  }

  /// `AudioPrinterTests.signal()`: one second of two tones and noise, as `printgolden.py` makes it.
  private static func goldenSignal() -> [Float] {
    var state: UInt64 = 7
    func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    let rate = 5512.0
    return (0..<5512).map { i in
      let t = Double(i) / rate
      let noise = (Double(next() >> 11) / 9_007_199_254_740_992 - 0.5) * 2000
      return Float(
        1000 * sin(2 * Double.pi * 440 * t) + 700 * sin(2 * Double.pi * (900 + 300 * t) * t)
          + noise)
    }
  }

  /// `AudioPrinterTests.expected`: `fp.py`'s words for the golden signal.
  private static let goldenWords: [UInt32] = [
    0xE398_7754, 0xA399_734C, 0xA399_734D, 0xA39B_7365, 0xE39F_7365, 0x631F_5B65, 0x6B1E_5B65,
    0x6B1E_5B35, 0x6B5E_5B35, 0xE95A_5B31, 0xED5A_5BB1, 0xCD6A_5992, 0xCD6A_5992, 0xCD6B_5D9A,
    0xCD6B_5D8A, 0xDD6B_7DAA, 0xD56B_6DAA, 0x956B_6DAA, 0x156B_ADAA, 0x15AB_ACAA, 0x15A3_ACAA,
    0x35A5_ACA2, 0x34B5_ACA2, 0x34B5_AEB6, 0x34B5_AED6, 0x3A95_A6D6, 0x3A95_A6D4, 0x3A95_A6D5,
    0x3A95_96D5, 0x2AD5_92D5, 0xAAD5_9255, 0xAAD5_9255, 0xAAD4_F255, 0xEAD6_7755, 0xEAE2_777D,
    0xEAE2_777D, 0xEAEA_777D, 0xEB6A_376D, 0xAB6A_176D, 0xAB6A_176D, 0xAB6A_172A, 0xAB4A_572A,
    0xAB4A_572A, 0x8B4A_57AA, 0x8B5A_D7AA, 0x8B5A_DFAA, 0xDB5A_CFBA, 0xDD58_CBBA, 0xD518_CBBA,
    0x5498_C9BA, 0x549C_E9B2, 0x549C_E992, 0x749C_A990,
  ]
}
