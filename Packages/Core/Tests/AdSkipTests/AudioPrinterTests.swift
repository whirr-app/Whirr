import Foundation
import Testing

@testable import AdSkip

@Suite struct AudioPrinterTests {
  /// A plain radix-2 FFT in doubles, keeping the bins the bands read; the App uses Accelerate
  /// instead. A direct DFT gives the same words but, unoptimised, took over twenty seconds.
  struct ReferenceSpectrum: AudioPrintSpectrum {
    mutating func powerSpectrum(
      of frame: UnsafeBufferPointer<Float>, into power: UnsafeMutableBufferPointer<Float>
    ) {
      let n = frame.count
      precondition(n & (n - 1) == 0, "the frame length must be a power of two")
      var re = frame.map { Double($0) }
      var im = [Double](repeating: 0, count: n)

      var reversed = 0
      for i in 1..<n {
        var bit = n >> 1
        while reversed & bit != 0 {
          reversed ^= bit
          bit >>= 1
        }
        reversed ^= bit
        if i < reversed { re.swapAt(i, reversed) }
      }

      var length = 2
      while length <= n {
        let half = length / 2
        let angle = -2 * Double.pi / Double(length)
        let (stepRe, stepIm) = (cos(angle), sin(angle))
        for start in stride(from: 0, to: n, by: length) {
          var (twiddleRe, twiddleIm) = (1.0, 0.0)
          for k in 0..<half {
            let a = start + k
            let b = a + half
            let productRe = re[b] * twiddleRe - im[b] * twiddleIm
            let productIm = re[b] * twiddleIm + im[b] * twiddleRe
            re[b] = re[a] - productRe
            im[b] = im[a] - productIm
            re[a] += productRe
            im[a] += productIm
            (twiddleRe, twiddleIm) = (
              twiddleRe * stepRe - twiddleIm * stepIm, twiddleRe * stepIm + twiddleIm * stepRe
            )
          }
        }
        length *= 2
      }

      for bin in 0..<power.count {
        power[bin] = (112..<744).contains(bin) ? Float(re[bin] * re[bin] + im[bin] * im[bin]) : 0
      }
    }
  }

  /// One second of two tones and noise, as `printgolden.py` makes it.
  static func signal() -> [Float] {
    var random = SplitMix64(seed: 7)
    let rate = 5512.0
    return (0..<5512).map { i in
      let t = Double(i) / rate
      let noise = (Double(random.next() >> 11) / 9_007_199_254_740_992 - 0.5) * 2000
      return Float(1000 * sin(2 * Double.pi * 440 * t) + 700 * sin(2 * Double.pi * (900 + 300 * t) * t) + noise)
    }
  }

  /// `fp.py`'s words for the same signal (numpy's FFT in float64).
  static let expected: [UInt32] = [
    0xE398_7754, 0xA399_734C, 0xA399_734D, 0xA39B_7365, 0xE39F_7365, 0x631F_5B65, 0x6B1E_5B65,
    0x6B1E_5B35, 0x6B5E_5B35, 0xE95A_5B31, 0xED5A_5BB1, 0xCD6A_5992, 0xCD6A_5992, 0xCD6B_5D9A,
    0xCD6B_5D8A, 0xDD6B_7DAA, 0xD56B_6DAA, 0x956B_6DAA, 0x156B_ADAA, 0x15AB_ACAA, 0x15A3_ACAA,
    0x35A5_ACA2, 0x34B5_ACA2, 0x34B5_AEB6, 0x34B5_AED6, 0x3A95_A6D6, 0x3A95_A6D4, 0x3A95_A6D5,
    0x3A95_96D5, 0x2AD5_92D5, 0xAAD5_9255, 0xAAD5_9255, 0xAAD4_F255, 0xEAD6_7755, 0xEAE2_777D,
    0xEAE2_777D, 0xEAEA_777D, 0xEB6A_376D, 0xAB6A_176D, 0xAB6A_176D, 0xAB6A_172A, 0xAB4A_572A,
    0xAB4A_572A, 0x8B4A_57AA, 0x8B5A_D7AA, 0x8B5A_DFAA, 0xDB5A_CFBA, 0xDD58_CBBA, 0xD518_CBBA,
    0x5498_C9BA, 0x549C_E9B2, 0x549C_E992, 0x749C_A990,
  ]

  @Test func matchesTheHarnessInAnyBufferSizes() {
    let signal = Self.signal()
    for sizes in [[5512], [1, 2047, 64, 3000], [700, 700, 700]] {
      var printer = AudioPrinter(spectrum: ReferenceSpectrum())
      var offset = 0
      for size in sizes + [signal.count] where offset < signal.count {
        let end = min(signal.count, offset + size)
        signal[offset..<end].withUnsafeBufferPointer { printer.consume($0) }
        offset = end
      }
      let words = printer.finish().words
      #expect(words.count == 53)
      let differing = zip(words, Self.expected).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
      // Float rounding may flip a bit whose energy difference is near zero, never more.
      #expect(differing <= 2, "\(differing) bits differ for buffers \(sizes)")
    }
  }

  @Test func takesOneFewerFrameThanFitsAsTheHarness() {
    // `(len - FRAME) // HOP` frames: exactly one frame's samples give no frames and no words.
    var printer = AudioPrinter(spectrum: ReferenceSpectrum())
    [Float](repeating: 0.1, count: 2048 + 64 * 2).withUnsafeBufferPointer { printer.consume($0) }
    #expect(printer.finish().count == 1)
    var short = AudioPrinter(spectrum: ReferenceSpectrum())
    [Float](repeating: 0.1, count: 100).withUnsafeBufferPointer { short.consume($0) }
    #expect(short.finish().isEmpty)
  }
}
