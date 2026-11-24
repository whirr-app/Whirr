import Foundation

/// One stretch of audio quieter than a pause threshold, in seconds from the start of the audio.
public struct PauseRun: Sendable, Equatable {
  public let start: Double
  public let end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

/// What `PauseDetector` found: pause runs at two thresholds, so both trim strengths come from one
/// pass over the audio.
public struct PauseRuns: Sendable, Equatable {
  /// `PauseDetector.revision` at the time of analysis; a stored result with an older revision is
  /// stale.
  public let revision: Int
  /// Seconds of audio consumed.
  public let duration: Double
  public let runsBelow40: [PauseRun]
  public let runsBelow46: [PauseRun]

  public init(
    revision: Int, duration: Double, runsBelow40: [PauseRun], runsBelow46: [PauseRun]
  ) {
    self.revision = revision
    self.duration = duration
    self.runsBelow40 = runsBelow40
    self.runsBelow46 = runsBelow46
  }

  // MARK: - Storage encoding

  /// Layout, little-endian: format version (UInt8 = 1), revision (UInt32), duration (Float64),
  /// count of -40 dB runs (UInt32), count of -46 dB runs (UInt32), then every -40 dB run and
  /// every -46 dB run as a Float32 start and end pair.
  private static let formatVersion: UInt8 = 1
  private static let headerSize = 1 + 4 + 8 + 4 + 4

  public func encoded() -> Data {
    var data = Data()
    data.reserveCapacity(Self.headerSize + 8 * (runsBelow40.count + runsBelow46.count))
    data.append(Self.formatVersion)
    Self.append(UInt32(truncatingIfNeeded: revision), to: &data)
    Self.append(duration.bitPattern, to: &data)
    Self.append(UInt32(runsBelow40.count), to: &data)
    Self.append(UInt32(runsBelow46.count), to: &data)
    for run in runsBelow40 + runsBelow46 {
      Self.append(Float(run.start).bitPattern, to: &data)
      Self.append(Float(run.end).bitPattern, to: &data)
    }
    return data
  }

  /// Nil for truncated or oversized data, an unknown format version, or a non-finite duration.
  public init?(encoded data: Data) {
    let bytes = Array(data)
    guard bytes.count >= Self.headerSize, bytes[0] == Self.formatVersion else { return nil }
    let revision = Self.read(UInt32.self, bytes, at: 1)
    let duration = Double(bitPattern: Self.read(UInt64.self, bytes, at: 5))
    let count40 = Int(Self.read(UInt32.self, bytes, at: 13))
    let count46 = Int(Self.read(UInt32.self, bytes, at: 17))
    guard duration.isFinite,
      bytes.count == Self.headerSize + 8 * (count40 + count46)  // Int is 64-bit; no overflow.
    else { return nil }
    var offset = Self.headerSize
    func runs(_ count: Int) -> [PauseRun] {
      var out: [PauseRun] = []
      out.reserveCapacity(count)
      for _ in 0..<count {
        let start = Float(bitPattern: Self.read(UInt32.self, bytes, at: offset))
        let end = Float(bitPattern: Self.read(UInt32.self, bytes, at: offset + 4))
        out.append(PauseRun(start: Double(start), end: Double(end)))
        offset += 8
      }
      return out
    }
    self.revision = Int(revision)
    self.duration = duration
    self.runsBelow40 = runs(count40)
    self.runsBelow46 = runs(count46)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }

  private static func read<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], at offset: Int)
    -> T
  {
    var value: T = 0
    for index in 0..<MemoryLayout<T>.size {
      value |= T(bytes[offset + index]) << (8 * index)
    }
    return value
  }
}

/// Streaming pause detector, fed native-rate channels buffer by buffer like `SilenceScanner`.
///
/// Signal: channels are summed to mono at equal power, (L + R) / sqrt 2, high-passed with an
/// 80 Hz second-order Butterworth biquad (RBJ, Q = 1/sqrt 2; state carries across `consume`
/// calls), and the RMS is taken over non-overlapping 10 ms frames, in dBFS (silence is -infinity).
/// A pause run is consecutive frames strictly below a threshold; runs separated by a break of
/// 30 ms or less are joined, and a joined run is kept at 0.1 s or longer. Runs are tracked at the
/// "-40 dB" and "-46 dB" thresholds at once.
///
/// The mix and thresholds reproduce the research level track that the strengths were chosen from
/// and the listening samples cut from: ffmpeg's stereo-to-mono downmix, and levels rounded to
/// whole dB then tested against `threshold + 0.5`, so the effective thresholds are -39.5 and
/// -45.5 dB. A plain channel mean with exact -40/-46 dB saved about 1 point more than the research
/// across its 217 episodes.
///
/// A run still open at `finish()` ends at the end of the audio. A final frame shorter than 10 ms
/// is evaluated at its own length, with run edges at the exact end of the audio.
///
/// Only the filter state, one frame accumulator and one open run per threshold are kept.
public struct PauseDetector: Sendable {
  /// Bumped whenever the stored analysis could change for the same audio: the detector's runs, or
  /// the app's alignment verdict stored beside them. 2: short iPhone reads are placed.
  /// 3: misaligned rows keep their runs.
  public static let revision: Int = 3

  private static let frameSeconds = 0.01
  private static let highPassHz = 80.0
  private static let thresholds: (high: Double, low: Double) = (-39.5, -45.5)
  private static let maxJoinedBreakFrames = 3
  private static let minimumRunSeconds = 0.1
  /// Absorbs floating-point error in the 0.1 s comparison.
  private static let epsilon = 1e-9

  private let sampleRate: Double
  private let frameLength: Int

  // High-pass biquad, direct form I, normalised by a0.
  private let b0: Double
  private let b1: Double
  private let b2: Double
  private let a1: Double
  private let a2: Double
  private var x1 = 0.0
  private var x2 = 0.0
  private var y1 = 0.0
  private var y2 = 0.0

  private var totalSamples = 0
  private var frameFill = 0
  private var frameSumSquares = 0.0
  private var frameIndex = 0

  private var below40: RunTracker
  private var below46: RunTracker

  public init(sampleRate: Double) {
    precondition(sampleRate > 0, "sampleRate must be positive")
    self.sampleRate = sampleRate
    self.frameLength = max(1, Int((sampleRate * Self.frameSeconds).rounded()))

    let omega = 2 * Double.pi * Self.highPassHz / sampleRate
    let alpha = sin(omega) / (2 * (1 / 2.0.squareRoot()))
    let cosOmega = cos(omega)
    let a0 = 1 + alpha
    self.b0 = (1 + cosOmega) / 2 / a0
    self.b1 = -(1 + cosOmega) / a0
    self.b2 = (1 + cosOmega) / 2 / a0
    self.a1 = -2 * cosOmega / a0
    self.a2 = (1 - alpha) / a0

    self.below40 = RunTracker(threshold: Self.thresholds.high)
    self.below46 = RunTracker(threshold: Self.thresholds.low)
  }

  /// One buffer of deinterleaved samples; every channel holds the same number of frames. Any
  /// chunk size is accepted and the result does not depend on it.
  public mutating func consume(_ channels: [UnsafeBufferPointer<Float>]) {
    precondition(!channels.isEmpty, "at least one channel is required")
    let count = channels[0].count
    for channel in channels {
      precondition(channel.count == count, "channels must hold the same number of frames")
    }
    let mixGain = 1 / Double(channels.count).squareRoot()
    for index in 0..<count {
      var sum = 0.0
      for channel in channels { sum += Double(channel[index]) }
      let x0 = sum * mixGain
      let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
      x2 = x1
      x1 = x0
      y2 = y1
      y1 = y0

      frameSumSquares += y0 * y0
      frameFill += 1
      if frameFill == frameLength { closeFrame(length: frameLength) }
    }
    totalSamples += count
  }

  /// Closes the final partial frame and any open runs, and returns the result.
  public mutating func finish() -> PauseRuns {
    if frameFill > 0 { closeFrame(length: frameFill) }
    let duration = Double(totalSamples) / sampleRate
    let minimumSamples = Self.minimumRunSeconds * sampleRate - Self.epsilon * sampleRate
    below40.finish(
      endSample: totalSamples, minimumSamples: minimumSamples, sampleRate: sampleRate)
    below46.finish(
      endSample: totalSamples, minimumSamples: minimumSamples, sampleRate: sampleRate)
    return PauseRuns(
      revision: Self.revision, duration: duration,
      runsBelow40: below40.runs, runsBelow46: below46.runs)
  }

  private mutating func closeFrame(length: Int) {
    let rms = (frameSumSquares / Double(length)).squareRoot()
    let level = rms > 0 ? 20 * log10(rms) : -Double.infinity
    let startSample = frameIndex * frameLength
    let endSample = startSample + length
    let minimumSamples = Self.minimumRunSeconds * sampleRate - Self.epsilon * sampleRate
    below40.add(
      frame: frameIndex, startSample: startSample, endSample: endSample, level: level,
      maxBreak: Self.maxJoinedBreakFrames, minimumSamples: minimumSamples,
      sampleRate: sampleRate)
    below46.add(
      frame: frameIndex, startSample: startSample, endSample: endSample, level: level,
      maxBreak: Self.maxJoinedBreakFrames, minimumSamples: minimumSamples,
      sampleRate: sampleRate)
    frameIndex += 1
    frameFill = 0
    frameSumSquares = 0
  }

  /// Joins below-threshold frames into runs for one threshold. A run is closed lazily, when the
  /// next below-threshold frame is more than `maxBreak` frames away or the audio ends.
  private struct RunTracker: Sendable {
    let threshold: Double
    var runs: [PauseRun] = []
    /// First sample of the open run and the exclusive end of its last below-threshold frame.
    private var open: (start: Int, end: Int, lastFrame: Int)?

    init(threshold: Double) { self.threshold = threshold }

    mutating func add(
      frame: Int, startSample: Int, endSample: Int, level: Double, maxBreak: Int,
      minimumSamples: Double, sampleRate: Double
    ) {
      guard level < threshold else { return }
      if let current = open, frame - current.lastFrame - 1 <= maxBreak {
        open = (current.start, endSample, frame)
        return
      }
      if let current = open { close(current.start, current.end, minimumSamples, sampleRate) }
      open = (startSample, endSample, frame)
    }

    mutating func finish(endSample: Int, minimumSamples: Double, sampleRate: Double) {
      if let current = open { close(current.start, current.end, minimumSamples, sampleRate) }
      open = nil
    }

    private mutating func close(
      _ start: Int, _ end: Int, _ minimumSamples: Double, _ sampleRate: Double
    ) {
      guard Double(end - start) >= minimumSamples else { return }
      runs.append(PauseRun(start: Double(start) / sampleRate, end: Double(end) / sampleRate))
    }
  }
}
