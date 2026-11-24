import Foundation

/// Streaming silence detector that reproduces ffmpeg 8.1.1's
/// `-af silencedetect=noise=-35dB:d=0.3` (with `mono=0`) on decoded float PCM.
///
/// A frame is silent only when every channel's sample has `abs(x) < threshold` (strict). A run of
/// at least `0.3 * sampleRate` consecutive silent frames is a silence: `start` is its first frame,
/// `end` the first non-silent frame after, both divided by the sample rate. End of stream, as in
/// ffmpeg 8.1.1: a qualifying run still open at `finish()` ends at the total frame count over the
/// sample rate; a shorter open run is dropped.
///
/// Only counters and the silences found so far are kept, so memory does not grow with the audio.
public struct SilenceScanner: Sendable {
  /// `-35 dB` as a linear amplitude, about 0.0177828.
  public static let threshold: Double = pow(10.0, -35.0 / 20.0)
  /// Minimum silence length in seconds (ffmpeg's `d=0.3`).
  public static let minimumDuration: Double = 0.3

  private let sampleRate: Double
  private let minimumFrames: Int
  private var frameIndex = 0
  /// Frame index where the current silent run began; meaningful only while `runLength > 0`.
  private var runStart = 0
  private var runLength = 0
  private var silences: [Silence] = []

  public init(sampleRate: Double) {
    precondition(sampleRate > 0, "sampleRate must be positive")
    self.sampleRate = sampleRate
    self.minimumFrames = Int((Self.minimumDuration * sampleRate).rounded())
  }

  /// One buffer of deinterleaved samples; every channel holds the same number of frames.
  public mutating func consume(_ channels: [UnsafeBufferPointer<Float>]) {
    precondition(!channels.isEmpty, "at least one channel is required")
    let count = channels[0].count
    for channel in channels {
      precondition(channel.count == count, "channels must hold the same number of frames")
    }
    let threshold = Self.threshold
    let channelCount = channels.count
    var index = frameIndex
    var start = runStart
    var length = runLength
    for frame in 0..<count {
      var silent = true
      var channelIndex = 0
      while channelIndex < channelCount {
        if !(Double(abs(channels[channelIndex][frame])) < threshold) {
          silent = false
          break
        }
        channelIndex += 1
      }
      if silent {
        if length == 0 { start = index }
        length += 1
      } else if length > 0 {
        if length >= minimumFrames {
          silences.append(
            Silence(start: Double(start) / sampleRate, end: Double(index) / sampleRate))
        }
        length = 0
      }
      index += 1
    }
    frameIndex = index
    runStart = start
    runLength = length
  }

  /// Closes any open run and returns all silences in time order.
  public mutating func finish() -> [Silence] {
    if runLength >= minimumFrames, runLength > 0 {
      silences.append(
        Silence(start: Double(runStart) / sampleRate, end: Double(frameIndex) / sampleRate))
    }
    runLength = 0
    return silences
  }
}
