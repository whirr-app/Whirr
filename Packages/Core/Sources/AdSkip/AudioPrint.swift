import Foundation

// Audio prints for audio-gated transcription: a port of ad-harness
// `Scripts/research/audiofp/fp.py`. "Audio print" is this concept's name everywhere;
// "fingerprint" is the file-identity check.

/// One episode's (or one learned ad's) audio print: a Haitsma-Kalker 32-bit word per 64-sample hop
/// of mono 5,512 Hz audio. The words are little-endian in `data`, so a print can be read straight
/// from a memory-mapped file without copying it into dirty memory.
public struct AudioPrint: Sendable, Equatable {
  public static let sampleRate = 5512
  public static let frameLength = 2048
  public static let hopLength = 64
  /// `fp.py`'s `HOP / SR`, in the harness's float order.
  public static let hopSeconds = 64.0 / 5512.0
  /// `fp.py`'s `FRAME / SR`.
  public static let frameSeconds = 2048.0 / 5512.0

  public let data: Data

  public init(words: [UInt32]) {
    data = words.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
  }

  /// `data` must hold whole little-endian words.
  public init?(littleEndianData data: Data) {
    guard data.count % 4 == 0 else { return nil }
    self.data = data
  }

  public var count: Int { data.count / 4 }

  public var isEmpty: Bool { data.isEmpty }

  /// The words, in host order. Apple platforms are little-endian, so a mapped file is read in
  /// place unless it is misaligned.
  public func withWords<R>(_ body: (UnsafeBufferPointer<UInt32>) throws -> R) rethrows -> R {
    try data.withUnsafeBytes { raw in
      if let base = raw.baseAddress, Int(bitPattern: base) % MemoryLayout<UInt32>.alignment == 0 {
        return try body(raw.bindMemory(to: UInt32.self))
      }
      let copy = [UInt32](unsafeUninitializedCapacity: count) { buffer, initialised in
        _ = raw.copyBytes(to: buffer)
        initialised = count
      }
      return try copy.withUnsafeBufferPointer(body)
    }
  }

  public var words: [UInt32] {
    withWords { Array($0) }
  }

  /// Frames `[from, to)`, clamped to the print. `data` may be a slice of a mapped file, so byte
  /// offsets count from its `startIndex`, not from zero.
  public func slice(from: Int, to: Int) -> AudioPrint {
    let lower = max(0, min(from, count))
    let upper = max(lower, min(to, count))
    let base = data.startIndex
    return AudioPrint(unchecked: data.subdata(in: (base + lower * 4)..<(base + upper * 4)))
  }

  private init(unchecked data: Data) {
    self.data = data
  }

  /// The time `audiocand.py` gives frame `k`: `k * HOP + FRAME_S / 2`.
  public static func time(ofFrame frame: Int) -> Double {
    Double(frame) * hopSeconds + frameSeconds / 2
  }

  /// The frame `replaycost.py` takes for a time: `int(t / HOP)`, truncating toward zero.
  public static func frame(atTime time: Double) -> Int {
    Int(time / hopSeconds)
  }
}

/// Computes a frame's power spectrum. The App supplies an Accelerate FFT; the
/// harness and tests supply their own, so the framing, bands and bits below are shared.
public protocol AudioPrintSpectrum {
  /// Writes `|rfft(frame)|²` for bins `0...frame.count / 2` into `power`. Any positive scale is
  /// allowed: a print compares energies only with each other.
  mutating func powerSpectrum(
    of frame: UnsafeBufferPointer<Float>, into power: UnsafeMutableBufferPointer<Float>)
}

/// Streams mono 5,512 Hz samples into an audio print (`fp.py` `fingerprint`): 2,048-sample Hann
/// frames every 64 samples, energies in 33 log-spaced bands from 300 to 2,000 Hz, and one bit per
/// band pair from the sign of the energy difference across frequency and time, band 0 in the top
/// bit.
public struct AudioPrinter<Spectrum: AudioPrintSpectrum> {
  /// `fp.py`'s band bins: `rfftfreq(2048, 1 / 5512)` within `geomspace(300, 2000, 34)`, as
  /// half-open bin ranges. Computed by numpy rather than here, so float rounding at an edge can
  /// never move a bin.
  public static var bands: [Range<Int>] {
    [
      112..<119, 119..<126, 126..<133, 133..<141, 141..<149, 149..<158, 158..<167, 167..<177,
      177..<188, 188..<199, 199..<210, 210..<223, 223..<236, 236..<250, 250..<265, 265..<280,
      280..<297, 297..<314, 314..<333, 333..<352, 352..<373, 373..<395, 395..<419, 419..<443,
      443..<470, 470..<497, 497..<527, 527..<558, 558..<591, 591..<626, 626..<663, 663..<702,
      702..<744,
    ]
  }

  private var spectrum: Spectrum
  private let window: [Float]
  private let bands = AudioPrinter.bands
  /// Samples not yet consumed by a frame.
  private var pending: [Float] = []
  private var totalSamples = 0
  /// The previous frame's band energies.
  private var previousRow: [Double]?
  private var words: [UInt32] = []
  private var frame: [Float]
  private var power: [Float]
  private var row: [Double]

  public init(spectrum: Spectrum) {
    self.spectrum = spectrum
    let n = AudioPrint.frameLength
    // `np.hanning(2048).astype(np.float32)`: the symmetric Hann window.
    window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
    frame = [Float](repeating: 0, count: n)
    power = [Float](repeating: 0, count: n / 2 + 1)
    row = [Double](repeating: 0, count: 33)
  }

  /// Appends samples. Frames are cut as soon as they are complete.
  public mutating func consume(_ samples: UnsafeBufferPointer<Float>) {
    pending.append(contentsOf: samples)
    totalSamples += samples.count
    let n = AudioPrint.frameLength
    let hop = AudioPrint.hopLength
    var offset = 0
    while pending.count - offset >= n {
      computeRow(from: offset)
      offset += hop
    }
    if offset > 0 { pending.removeFirst(offset) }
  }

  /// The print. `fp.py` takes `(len - FRAME) // HOP` frames, one fewer than fit when the length
  /// divides evenly, and a word from each consecutive pair.
  public mutating func finish() -> AudioPrint {
    let n = AudioPrint.frameLength
    let frames = totalSamples >= n ? (totalSamples - n) / AudioPrint.hopLength : 0
    let wordCount = max(0, frames - 1)
    return AudioPrint(words: Array(words.prefix(wordCount)))
  }

  private mutating func computeRow(from offset: Int) {
    let n = AudioPrint.frameLength
    for index in 0..<n { frame[index] = pending[offset + index] * window[index] }
    frame.withUnsafeBufferPointer { input in
      power.withUnsafeMutableBufferPointer { output in
        spectrum.powerSpectrum(of: input, into: output)
      }
    }
    for (band, bins) in bands.enumerated() {
      var sum = 0.0
      for bin in bins { sum += Double(power[bin]) }
      row[band] = sum
    }
    if let previous = previousRow {
      var word: UInt32 = 0
      for band in 0..<32 {
        let difference = (row[band] - row[band + 1]) - (previous[band] - previous[band + 1])
        if difference > 0 { word |= 1 << UInt32(31 - band) }
      }
      words.append(word)
    }
    previousRow = row
  }
}
