import AVFoundation
import Accelerate
import AdSkip
import Foundation

/// Decodes a downloaded episode once with `AVAudioFile`. `SilenceScanner` runs over the
/// native-rate channels and a mono mix resampled to 5,512 Hz feeds `AudioPrinter`. `AVAudioFile`
/// is also what the transcriber reads, so silences, prints and words share one clock.
nonisolated struct AudioFileAnalysisDecoder: AudioPrinting {

  enum Failure: Error {
    case unexpectedFormat
    case converter
  }

  func decode(fileAt url: URL) async throws -> DecodedAudio {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
      format.channelCount > 0,
      let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1,
        interleaved: false),
      let mono = AVAudioPCMBuffer(
        pcmFormat: monoFormat, frameCapacity: AudioFileReadLoop.framesPerRead),
      let printFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioPrint.sampleRate), channels: 1,
        interleaved: false),
      let converter = AVAudioConverter(from: monoFormat, to: printFormat)
    else { throw Failure.unexpectedFormat }
    // Nearest to ffmpeg's resampler, which made the harness's prints: against `fp.py` on hold-out
    // 4 the default quality gives a 2.0% bit error rate, this 0.9%, for about 5% more
    // decode time. The mastering algorithm is no closer and fifteen times slower.
    converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
    // The harness's duration: the file's (for MP3, estimated) length, not the decoded frames.
    let duration = Double(file.length) / format.sampleRate
    var scanner = SilenceScanner(sampleRate: format.sampleRate)
    var printer = AudioPrinter(spectrum: AccelerateSpectrum())

    try AudioFileReadLoop.forEachBuffer(in: file, failure: Failure.unexpectedFormat) {
      channels, count in
      guard channels.isEmpty == false, let mixed = mono.floatChannelData?[0] else {
        throw Failure.unexpectedFormat
      }
      let channelCount = channels.count
      scanner.consume(channels)

      // ffmpeg's `-ac 1`: the mean of the channels.
      var output = UnsafeMutableBufferPointer(start: mixed, count: count)
      if channelCount == 1 {
        _ = output.initialize(from: channels[0])
      } else {
        vDSP.add(channels[0], channels[1], result: &output)
        for channel in channels.dropFirst(2) { vDSP.add(output, channel, result: &output) }
        vDSP.multiply(1 / Float(channelCount), output, result: &output)
      }
      mono.frameLength = AVAudioFrameCount(count)
      for resampled in try AdSkipAudioConversion.convert(mono, with: converter, to: printFormat) {
        printer.consume(Self.samples(of: resampled))
      }
      return true
    }
    for resampled in try AdSkipAudioConversion.convert(nil, with: converter, to: printFormat) {
      printer.consume(Self.samples(of: resampled))
    }
    return DecodedAudio(silences: scanner.finish(), audioPrint: printer.finish(), duration: duration)
  }

  private static func samples(of buffer: AVAudioPCMBuffer) -> UnsafeBufferPointer<Float> {
    UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength))
  }
}

/// The `AVAudioFile` read the decoder and the pause analyser share: one buffer of `framesPerRead`
/// frames at a time, at the file's native format and rate. An MP3's length is an estimate, so a
/// read past the real end (`eofErr`) ends the file.
nonisolated enum AudioFileReadLoop {
  static let framesPerRead: AVAudioFrameCount = 1 << 16

  /// Reads `file` from its current position to its end, handing each read's channels to
  /// `consumer`, which returns false to stop early. Throws `failure` when the processing format is
  /// not non-interleaved float32 or a read buffer cannot be made. A read with no channel data
  /// reaches `consumer` as no channels, so each caller keeps its own answer to that.
  static func forEachBuffer(
    in file: AVAudioFile,
    framesPerRead: AVAudioFrameCount = framesPerRead,
    failure: any Error,
    consumer: (_ channels: [UnsafeBufferPointer<Float>], _ count: Int) throws -> Bool
  ) throws {
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
      format.channelCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerRead)
    else { throw failure }
    let channelCount = Int(format.channelCount)

    while file.framePosition < file.length {
      try Task.checkCancellation()
      do {
        try file.read(into: buffer)
      } catch let error as NSError
        where error.domain == NSOSStatusErrorDomain && error.code == -39
      {
        // An MP3's length is an estimate; reading past the real end throws eofErr.
        break
      }
      let count = Int(buffer.frameLength)
      guard count > 0 else { break }
      guard let data = buffer.floatChannelData else {
        guard try consumer([], count) else { return }
        continue
      }
      let channels = (0..<channelCount).map { UnsafeBufferPointer(start: data[$0], count: count) }
      guard try consumer(channels, count) else { return }
    }
  }
}

/// `|rfft(frame)|²` from vDSP's real FFT. `vDSP_fft_zrip` scales by two, which a
/// print does not see: it compares energies only with each other.
nonisolated final class AccelerateSpectrum: AudioPrintSpectrum {
  private let log2n: vDSP_Length
  private let setup: FFTSetup
  private var real: [Float]
  private var imaginary: [Float]

  init(length: Int = AudioPrint.frameLength) {
    log2n = vDSP_Length(log2(Double(length)))
    setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    real = [Float](repeating: 0, count: length / 2)
    imaginary = [Float](repeating: 0, count: length / 2)
  }

  deinit {
    vDSP_destroy_fftsetup(setup)
  }

  func powerSpectrum(
    of frame: UnsafeBufferPointer<Float>, into power: UnsafeMutableBufferPointer<Float>
  ) {
    let half = frame.count / 2
    real.withUnsafeMutableBufferPointer { re in
      imaginary.withUnsafeMutableBufferPointer { im in
        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
        frame.withMemoryRebound(to: DSPComplex.self) { pairs in
          vDSP_ctoz(pairs.baseAddress!, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        // Bin 0 packs DC in the real part and Nyquist in the imaginary part.
        power[0] = re[0] * re[0]
        power[half] = im[0] * im[0]
        for bin in 1..<half { power[bin] = re[bin] * re[bin] + im[bin] * im[bin] }
      }
    }
  }
}

/// Buffer-at-a-time `AVAudioConverter` use shared by the decoder and the transcriber.
nonisolated enum AdSkipAudioConversion {
  /// Converts one buffer, or with nil drains the converter's tail at the end of the input.
  static func convert(
    _ input: AVAudioPCMBuffer?, with converter: AVAudioConverter, to target: AVAudioFormat
  ) throws -> [AVAudioPCMBuffer] {
    let frames = input.map { Double($0.frameLength) } ?? 0
    let ratio = target.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount(frames * ratio) + 1024
    var supplied = false
    var buffers: [AVAudioPCMBuffer] = []
    while true {
      guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
        throw AudioFileAnalysisDecoder.Failure.converter
      }
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        guard let input, supplied == false else {
          inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
          return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return input
      }
      if let error { throw error }
      if output.frameLength > 0 { buffers.append(output) }
      switch status {
      case .haveData: continue
      case .inputRanDry, .endOfStream: return buffers
      case .error: throw AudioFileAnalysisDecoder.Failure.converter
      @unknown default: return buffers
      }
    }
  }
}
