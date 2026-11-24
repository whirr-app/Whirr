import AVFoundation
import Accelerate
import AdSkip
import AppModel
import CoreSupport
import Foundation

/// Decodes a downloaded episode with `AVAudioFile`, finds its pauses, and checks that the player's
/// own timeline for the file matches the decode.
nonisolated struct AudioFilePauseAnalyser: PauseAnalysing {

  enum Failure: Error {
    case unexpectedFormat
    case unreadableTrack
  }

  static let checkPointCount = 8
  static let minimumUsablePoints = 4
  static let windowSeconds = 1.0
  static let lagSeconds = 0.05
  /// The most a read may come back short at its start and still be placed: about four MP3 frames.
  static let slackSeconds = 0.1
  static let passingCorrelation: Float = 0.9
  static let quietPeak: Float = 0.01

  func analyse(fileAt url: URL) async throws -> PauseAnalysis {
    #if DEBUG
      let started = ContinuousClock.now
    #endif
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let rate = format.sampleRate
    let needsCheck = Self.needsAlignmentCheck(file.fileFormat.streamDescription.pointee.mFormatID)
    var windows = needsCheck ? Self.makeWindows(length: Int(file.length), rate: rate) : []
    var detector = PauseDetector(sampleRate: rate)
    var mono = [Float](repeating: 0, count: Int(AudioFileReadLoop.framesPerRead))
    var position = 0

    try AudioFileReadLoop.forEachBuffer(in: file, failure: Failure.unexpectedFormat) {
      channels, count in
      guard channels.isEmpty == false else { return false }
      detector.consume(channels)
      if windows.isEmpty == false {
        Self.mixToMono(channels, into: &mono)
        for index in windows.indices {
          windows[index].absorb(mono, count: count, at: position)
        }
      }
      position += count
      return true
    }
    let runs = detector.finish()
    let aligned =
      needsCheck ? try await Self.isAligned(windows: windows, url: url, rate: rate) : true
    #if DEBUG
      // The device pass's cost figure: seconds of work per hour of audio.
      let elapsed = (ContinuousClock.now - started).components
      let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      let audioHours = Double(position) / rate / 3_600
      DeviceTraceLog.emit(
        "WHIRRTRIM analyse audioSeconds=\(Int(Double(position) / rate)) seconds=\(seconds) "
          + "perAudioHour=\(audioHours > 0 ? seconds / audioHours : 0) checked=\(needsCheck ? 1 : 0) "
          + "aligned=\(aligned ? 1 : 0)")
    #endif
    return PauseAnalysis(runs: runs, isAligned: aligned)
  }

  // MARK: - Alignment check

  /// Formats with a sample table give the player exact positions, so only the rest are checked.
  static func needsAlignmentCheck(_ formatID: AudioFormatID) -> Bool {
    switch formatID {
    case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
      kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
      kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_Spatial, kAudioFormatAppleLossless:
      false
    default:
      true
    }
  }

  /// The decoded mono around one check point: `pad` frames either side of the read's one second,
  /// and `slack` more after it, for a read that comes back short at its start.
  struct Window {
    /// First frame of the read.
    let start: Int
    let pad: Int
    let length: Int
    let slack: Int
    var samples: [Float]
    var filled = 0

    init(start: Int, pad: Int, length: Int, slack: Int) {
      self.start = start
      self.pad = pad
      self.length = length
      self.slack = slack
      samples = [Float](repeating: 0, count: length + 2 * pad + slack)
    }

    var isComplete: Bool { filled == samples.count }

    mutating func absorb(_ mono: [Float], count: Int, at position: Int) {
      let first = max(position, start - pad)
      let last = min(position + count, start + length + pad + slack)
      guard first < last else { return }
      for frame in first..<last { samples[frame - (start - pad)] = mono[frame - position] }
      filled += last - first
    }
  }

  static func makeWindows(length: Int, rate: Double) -> [Window] {
    let span = Int(windowSeconds * rate)
    let pad = Int(lagSeconds * rate)
    let slack = Int(slackSeconds * rate)
    guard length >= span + 2 * pad + slack else { return [] }
    return (0..<checkPointCount).map { index in
      let point = Int(Double(length) * (Double(index) + 0.5) / Double(checkPointCount))
      return Window(
        start: min(max(point, pad), length - span - pad - slack), pad: pad, length: span,
        slack: slack)
    }
  }

  /// Equal-power mix: any consistent mix does, because the correlation is normalised.
  static func mixToMono(_ channels: [UnsafeBufferPointer<Float>], into mono: inout [Float]) {
    let count = channels[0].count
    let n = vDSP_Length(count)
    mono.withUnsafeMutableBufferPointer { out in
      guard let destination = out.baseAddress else { return }
      destination.update(from: channels[0].baseAddress!, count: count)
      for channel in channels.dropFirst() {
        vDSP_vadd(destination, 1, channel.baseAddress!, 1, destination, 1, n)
      }
      if channels.count > 1 {
        var scale = 1 / Float(channels.count).squareRoot()
        vDSP_vsmul(destination, 1, &scale, destination, 1, n)
      }
    }
  }

  static func isAligned(windows: [Window], url: URL, rate: Double) async throws -> Bool {
    var usable = 0
    for window in windows where window.isComplete {
      try Task.checkCancellation()
      let read = try await readWindow(url: url, startFrame: window.start, length: window.length, rate: rate)
      switch judge(read: read, window: window) {
      case .unusable: continue
      case .passes: usable += 1
      case .fails: return false
      }
    }
    return usable >= minimumUsablePoints
  }

  enum PointResult: Equatable {
    case unusable, passes, fails
  }

  /// Whether one read lands on the decode within ±`pad`. On an iPhone a mid-file MP3 read drops
  /// one to three frames of decoder preroll but still reports the requested start, so a read that
  /// comes back short holds the audio from `start + lost`. Judging it there measures the file, not
  /// the reader; trimmed playback has the same habit and Trim Silences' lead-in absorbs it
  /// (`PauseTrimPlanner.leadIn`).
  static func judge(read: [Float], window: Window) -> PointResult {
    let lost = window.length - read.count
    guard lost >= 0, lost <= window.slack, read.isEmpty == false else { return .unusable }
    if (read.map { abs($0) }.max() ?? 0) < quietPeak { return .unusable }
    let decoded = Array(window.samples[lost..<(lost + read.count + 2 * window.pad)])
    let best = bestCorrelation(read: read, decoded: decoded, maxLag: window.pad)
    return best >= passingCorrelation ? .passes : .fails
  }

  /// Reads one second through a fresh asset, as the player's item does, without precise timing. An
  /// asset learns exact positions as it reads, so one is never shared between points.
  static func readWindow(url: URL, startFrame: Int, length: Int, rate: Double) async throws -> [Float] {
    // A file whose type the extension does not settle fails here, and so is never trimmed.
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw Failure.unreadableTrack
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 1,
      ])
    reader.add(output)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: Double(startFrame) / rate, preferredTimescale: 600_000),
      duration: CMTime(seconds: Double(length) / rate, preferredTimescale: 600_000))
    guard reader.startReading() else {
      throw reader.error ?? Failure.unreadableTrack
    }
    var samples: [Float] = []
    samples.reserveCapacity(length)
    while samples.count < length, let sampleBuffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let bytes = CMBlockBufferGetDataLength(block)
      var chunk = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
      let status = chunk.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { throw Failure.unreadableTrack }
      samples.append(contentsOf: chunk)
    }
    if reader.status == .failed { throw reader.error ?? Failure.unreadableTrack }
    return Array(samples.prefix(length))
  }

  /// The best Pearson correlation of `read` against `decoded` at every lag in ±`maxLag` samples.
  /// `decoded` holds `maxLag` extra samples on each side of a stretch as long as `read`; lag zero
  /// aligns `read` with the middle. One `vDSP_dotpr` per lag over the mean-removed read (about
  /// 4,400 lags × 44,100 samples for a second at 44.1 kHz), with the decoded segment's mean and
  /// energy from prefix sums, so no decimation is needed.
  static func bestCorrelation(read: [Float], decoded: [Float], maxLag: Int) -> Float {
    let n = read.count
    guard n > 0, decoded.count >= n + 2 * maxLag else { return 0 }
    let readMean = vDSP.mean(read)
    let centred = vDSP.add(-readMean, read)
    let readNorm = vDSP.sumOfSquares(centred).squareRoot()
    guard readNorm > 0 else { return 0 }

    var sums = [Double](repeating: 0, count: decoded.count + 1)
    var squares = sums
    for index in decoded.indices {
      let value = Double(decoded[index])
      sums[index + 1] = sums[index] + value
      squares[index + 1] = squares[index] + value * value
    }
    var best: Float = -1
    centred.withUnsafeBufferPointer { r in
      decoded.withUnsafeBufferPointer { d in
        for lag in -maxLag...maxLag {
          let from = maxLag + lag
          let sum = sums[from + n] - sums[from]
          let energy = squares[from + n] - squares[from] - sum * sum / Double(n)
          guard energy > 1e-12 else { continue }
          var dot: Float = 0
          vDSP_dotpr(r.baseAddress!, 1, d.baseAddress! + from, 1, &dot, vDSP_Length(n))
          best = max(best, dot / (readNorm * Float(energy.squareRoot())))
        }
      }
    }
    return best
  }
}
