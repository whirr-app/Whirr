import AVFoundation
import AdSkip
import AppModel
import CoreMedia
import Foundation
import Speech

/// Reads a slice of a downloaded file, converts it to the analyser's format and stamps each buffer
/// on the player's clock: the feed `SpeechEpisodeTranscriber` and the transcript session share. One
/// read at a time, so a caller can pace it; not `Sendable`, since it owns the reader and converter.
///
/// The slice is read through `AVAssetReader` on the asset the player builds, not `AVAudioFile`,
/// because the two disagree on where a time is. A file joined from parts carries packets whose
/// container duration is shorter than what they decode to, often a single tick; a seek honours
/// those durations while `AVAudioFile` counts decoded frames. On one 14-hour audiobook that put
/// `AVAudioFile` 6 s ahead of the player by mid-book, so a tapped sentence played seconds late.
/// Starting each slice with the player's own seek keeps a slice's words on the player's clock,
/// apart from joins inside the slice itself.
nonisolated struct SpeechAudioFeed {
  enum Failure: Error, Equatable {
    case unreadable
  }

  /// Output frames each `next()` gathers before handing them over.
  static let framesPerRead: AVAudioFrameCount = 1 << 15

  private let reader: AVAssetReader?
  private let output: AVAssetReaderTrackOutput?
  /// What the reader decodes to: float samples at the analyser's rate and channel count.
  private let decoded: AVAudioFormat
  private let target: AVAudioFormat
  private let converter: AVAudioConverter
  /// Whole output samples from the file's start. Consecutive buffers abut exactly; rounded
  /// seconds make the analyser reject a buffer as overlapping the one before.
  private var stamp: Int64
  private var isFinished: Bool

  /// File time, in seconds, through which audio has been handed out.
  var fedThroughSeconds: Double { Double(stamp) / target.sampleRate }

  /// The asset's duration in seconds, on the player's clock. `AVAudioFile` counts decoded frames,
  /// which drifts from the player on a file joined from parts; this is the clock the feed reads on.
  static func duration(ofFileAt url: URL) async throws -> Double {
    let asset = AVURLAsset(
      url: url, options: CompositionTrimPreparer.sourceOptions(forFileURL: url, timing: .estimated))
    let duration = try await asset.load(.duration)
    guard duration.isNumeric else { throw Failure.unreadable }
    return duration.seconds
  }

  /// Opens `url` as the player does. `slice` is clamped to the asset's duration.
  static func open(url: URL, target: AVAudioFormat, slice: TimeSpan) async throws -> SpeechAudioFeed {
    let asset = AVURLAsset(
      url: url, options: CompositionTrimPreparer.sourceOptions(forFileURL: url, timing: .estimated))
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw Failure.unreadable
    }
    let duration = try await asset.load(.duration)
    guard duration.isNumeric else { throw Failure.unreadable }
    return try SpeechAudioFeed(asset: asset, track: track, duration: duration.seconds, target: target, slice: slice)
  }

  private init(
    asset: AVAsset, track: AVAssetTrack, duration: Double, target: AVAudioFormat, slice: TimeSpan
  ) throws {
    guard
      let decoded = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: target.sampleRate,
        channels: target.channelCount, interleaved: true),
      let converter = AVAudioConverter(from: decoded, to: target)
    else { throw AudioFileAnalysisDecoder.Failure.converter }
    self.decoded = decoded
    self.target = target
    self.converter = converter
    let start = max(0, slice.start)
    let end = min(duration, slice.end)
    self.stamp = Int64((start * target.sampleRate).rounded())
    guard end > start else {
      reader = nil
      output = nil
      isFinished = true
      return
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
        AVSampleRateKey: target.sampleRate,
        AVNumberOfChannelsKey: target.channelCount,
      ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    let scale = CMTimeScale(target.sampleRate)
    reader.timeRange = CMTimeRange(
      start: CMTime(value: stamp, timescale: scale),
      end: CMTime(value: CMTimeValue((end * target.sampleRate).rounded(.up)), timescale: scale))
    guard reader.startReading() else { throw reader.error ?? Failure.unreadable }
    self.reader = reader
    self.output = output
    self.isFinished = false
  }

  /// The next read's buffers, or nil once the slice or the file has ended. The read that reaches
  /// the slice's end also drains the converter's tail.
  mutating func next() throws -> [AnalyzerInput]? {
    guard isFinished == false, let reader, let output else { return nil }
    var converted: [AVAudioPCMBuffer] = []
    var gathered: AVAudioFrameCount = 0
    while gathered < Self.framesPerRead {
      guard let sample = output.copyNextSampleBuffer() else {
        if reader.status == .failed { throw reader.error ?? Failure.unreadable }
        converted += try AdSkipAudioConversion.convert(nil, with: converter, to: target)
        isFinished = true
        break
      }
      guard let input = try pcmBuffer(from: sample) else { continue }
      gathered += input.frameLength
      converted += try AdSkipAudioConversion.convert(input, with: converter, to: target)
    }
    guard converted.isEmpty == false else { return isFinished ? nil : [] }
    let timescale = CMTimeScale(target.sampleRate)
    var inputs: [AnalyzerInput] = []
    for buffer in converted {
      inputs.append(
        AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: stamp, timescale: timescale)))
      stamp += Int64(buffer.frameLength)
    }
    return inputs
  }

  private func pcmBuffer(from sample: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0 else { return nil }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: decoded, frameCapacity: AVAudioFrameCount(frames))
    else { throw AudioFileAnalysisDecoder.Failure.converter }
    buffer.frameLength = AVAudioFrameCount(frames)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
    guard status == noErr else { throw Failure.unreadable }
    return buffer
  }
}
