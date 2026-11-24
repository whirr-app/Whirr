import AVFoundation
import AdSkip
import AppModel
import Foundation
import Testing

@testable import Whirr

/// Nonisolated: decoding and correlating seconds of audio on the main actor would stall the timing
/// tests that share it.
@Suite("Audio file pause analyser")
nonisolated struct AudioFilePauseAnalyserTests {

  private static let rate = 8_000.0

  private enum FixtureError: Error {
    case missing(String)
  }

  private func fixtureURL(_ name: String, extension fileExtension: String) throws -> URL {
    let bundle = Bundle(for: BundleToken.self)
    if let url = bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures") {
      return url
    }
    if let url = bundle.url(forResource: name, withExtension: fileExtension) { return url }
    throw FixtureError.missing(name)
  }

  /// Band-limited deterministic noise: unrelated seeds give unrelated signals.
  private func signal(seed: UInt64, count: Int) -> [Float] {
    var state = seed
    var previous: Float = 0
    return (0..<count).map { _ in
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let white = Float(Int64(bitPattern: state) >> 40) / Float(1 << 23)
      previous = 0.7 * previous + 0.3 * white
      return previous
    }
  }

  private func writeFile(tone toneSeconds: Double, gap: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pause-analyser-\(UUID().uuidString).wav")
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false))
    let file = try AVAudioFile(
      forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    var phase = 0
    func write(seconds: Double, level: Float) throws {
      let frames = AVAudioFrameCount(seconds * Self.rate)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
      buffer.frameLength = frames
      let data = try #require(buffer.floatChannelData)[0]
      for frame in 0..<Int(frames) {
        let t = Double(phase + frame) / Self.rate
        data[frame] = level * Float(sin(2 * .pi * 440 * t) + 0.5 * sin(2 * .pi * 1_130 * t))
      }
      phase += Int(frames)
      try file.write(from: buffer)
    }
    try write(seconds: toneSeconds, level: 0.3)
    try write(seconds: gap, level: 0)
    try write(seconds: toneSeconds, level: 0.3)
    return url
  }

  private func covers(_ runs: [PauseRun], _ start: Double, _ end: Double) -> Bool {
    runs.contains { $0.start <= start + 0.1 && $0.end >= end - 0.1 }
  }

  // MARK: - Correlation

  @Test("a signal shifted by 20 ms still correlates")
  func shiftWithinRangePasses() {
    let pad = 400
    let n = 8_000
    let full = signal(seed: 1, count: n + 4 * pad)
    let decoded = Array(full[0..<(n + 2 * pad)])
    let shift = 160  // 20 ms
    let read = Array(full[(pad + shift)..<(pad + shift + n)])
    let best = AudioFilePauseAnalyser.bestCorrelation(read: read, decoded: decoded, maxLag: pad)
    #expect(best >= 0.9)
  }

  @Test("an unrelated signal does not correlate")
  func unrelatedFails() {
    let pad = 400
    let n = 8_000
    let decoded = signal(seed: 1, count: n + 2 * pad)
    let read = signal(seed: 2, count: n)
    #expect(AudioFilePauseAnalyser.bestCorrelation(read: read, decoded: decoded, maxLag: pad) < 0.9)
  }

  @Test("a shift of 80 ms is outside the range")
  func shiftOutsideRangeFails() {
    let pad = 400
    let n = 8_000
    let full = signal(seed: 1, count: n + 4 * pad)
    let decoded = Array(full[0..<(n + 2 * pad)])
    let shift = 640  // 80 ms
    let read = Array(full[(pad + shift)..<(pad + shift + n)])
    let best = AudioFilePauseAnalyser.bestCorrelation(read: read, decoded: decoded, maxLag: pad)
    #expect(best < 0.9)
  }

  // MARK: - One check point

  /// A window over `full` whose read starts at `pad`, as `makeWindows` lays one out.
  private func window(over full: [Float], pad: Int, length: Int, slack: Int)
    -> AudioFilePauseAnalyser.Window
  {
    var window = AudioFilePauseAnalyser.Window(start: pad, pad: pad, length: length, slack: slack)
    window.absorb(full, count: full.count, at: 0)
    return window
  }

  @Test("a read that lost its first frames is judged where its audio starts")
  func shortReadIsPlacedByWhatItLost() {
    // The iPhone's reader drops one to three MP3 frames at a mid-file start but keeps the
    // requested timestamp, so the audio it returns starts that much later.
    let (pad, n, slack, lost) = (400, 8_000, 800, 600)  // 50 ms, 1 s, 100 ms, 75 ms at 8 kHz
    let full = signal(seed: 3, count: n + 2 * pad + slack)
    let window = window(over: full, pad: pad, length: n, slack: slack)
    #expect(window.isComplete)
    let read = Array(full[(pad + lost)..<(pad + n)])
    #expect(AudioFilePauseAnalyser.judge(read: read, window: window) == .passes)
  }

  @Test("a short read whose audio did not move fails")
  func shortReadAtTheRequestedStartFails() {
    let (pad, n, slack, lost) = (400, 8_000, 800, 600)
    let full = signal(seed: 3, count: n + 2 * pad + slack)
    let window = window(over: full, pad: pad, length: n, slack: slack)
    let read = Array(full[pad..<(pad + n - lost)])
    #expect(AudioFilePauseAnalyser.judge(read: read, window: window) == .fails)
  }

  @Test("a full read is judged as before")
  func fullReadsAreJudgedAtTheirStart() {
    let (pad, n, slack) = (400, 8_000, 800)
    let full = signal(seed: 4, count: n + 2 * pad + slack + 1_000)
    let window = window(over: full, pad: pad, length: n, slack: slack)
    #expect(AudioFilePauseAnalyser.judge(read: Array(full[pad..<(pad + n)]), window: window) == .passes)
    let late = Array(full[(pad + 640)..<(pad + 640 + n)])  // 80 ms off, outside ±50 ms
    #expect(AudioFilePauseAnalyser.judge(read: late, window: window) == .fails)
  }

  @Test("a read that lost more than the slack, or a quiet one, is not used")
  func unusableReads() {
    let (pad, n, slack) = (400, 8_000, 800)
    let full = signal(seed: 5, count: n + 2 * pad + slack)
    let window = window(over: full, pad: pad, length: n, slack: slack)
    let tooShort = Array(full[(pad + slack + 1)..<(pad + n)])
    #expect(AudioFilePauseAnalyser.judge(read: tooShort, window: window) == .unusable)
    let quiet = [Float](repeating: 0.001, count: n)
    #expect(AudioFilePauseAnalyser.judge(read: quiet, window: window) == .unusable)
  }

  // MARK: - Files

  @Test("finds the silence in a generated file and reports it aligned", .timeLimit(.minutes(1)))
  func generatedFile() async throws {
    let url = try writeFile(tone: 3, gap: 1)
    defer { try? FileManager.default.removeItem(at: url) }

    let analysis = try await AudioFilePauseAnalyser().analyse(fileAt: url)

    #expect(covers(analysis.runs.runsBelow40, 3, 4))
    #expect(covers(analysis.runs.runsBelow46, 3, 4))
    #expect(analysis.isAligned)
  }

  @Test("finds the gaps in a CBR MP3 and reports it aligned", .timeLimit(.minutes(1)))
  func cbrMP3() async throws {
    let url = try fixtureURL("trim-silences-cbr", extension: "mp3")

    let analysis = try await AudioFilePauseAnalyser().analyse(fileAt: url)

    // Tone 0-2.5 s, gap 2.5-3.5 s, tone 3.5-6.5 s, gap 6.5-7.5 s, tone from 7.5 s.
    #expect(covers(analysis.runs.runsBelow40, 2.5, 3.5))
    #expect(covers(analysis.runs.runsBelow40, 6.5, 7.5))
    #expect(covers(analysis.runs.runsBelow46, 2.5, 3.5))
    #expect(covers(analysis.runs.runsBelow46, 6.5, 7.5))
    #expect(analysis.isAligned)
  }

  @Test("a file that is not audio throws at open", .timeLimit(.minutes(1)))
  func nonAudioThrows() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pause-analyser-\(UUID().uuidString).mp3")
    try Data("not audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    await #expect(throws: (any Error).self) {
      try await AudioFilePauseAnalyser().analyse(fileAt: url)
    }
  }

  @Test("a cancelled task stops with CancellationError", .timeLimit(.minutes(1)))
  func cancellation() async throws {
    let url = try writeFile(tone: 3, gap: 1)
    defer { try? FileManager.default.removeItem(at: url) }

    // The task cancels itself, so the analysis starts already cancelled with no wait.
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AudioFilePauseAnalyser().analyse(fileAt: url)
    }

    await #expect(throws: CancellationError.self) { try await task.value }
  }
}

private final class BundleToken {}
