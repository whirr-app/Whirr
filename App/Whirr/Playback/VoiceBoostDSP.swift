import Accelerate
import Foundation

/// The stages of the Voice Boost chain. Production runs `.all`; tests enable one stage at a
/// time so a stage's response is measured without the others colouring it.
nonisolated struct VoiceBoostStages: OptionSet, Sendable {
  let rawValue: Int

  static let highPass = VoiceBoostStages(rawValue: 1 << 0)
  static let presence = VoiceBoostStages(rawValue: 1 << 1)
  /// The compressor and its makeup gain.
  static let compressor = VoiceBoostStages(rawValue: 1 << 2)
  static let limiter = VoiceBoostStages(rawValue: 1 << 3)
  static let lowMidCut = VoiceBoostStages(rawValue: 1 << 4)
  static let all: VoiceBoostStages = [.highPass, .lowMidCut, .presence, .compressor, .limiter]
}

/// Tuned by ear.
///
/// The compressor's threshold is on an RMS level, and makeup is set so that switching on leaves
/// typical speech close to its own level (about +1.5 dB at -18 dBFS RMS, -2.5 dB at -12): a larger
/// lift masks the tonal change, and reads as "louder", not "clearer".
nonisolated struct VoiceBoostParameters: Sendable, Equatable {
  var highPassHz = 100.0
  var lowMidHz = 280.0
  var lowMidGainDB = -2.5
  var lowMidQ = 1.0
  var presenceHz = 3_000.0
  var presenceGainDB = 5.0
  var presenceQ = 0.8
  var thresholdDB: Float = -22
  var ratio: Float = 3
  var kneeDB: Float = 6
  /// Time constant of the detector's mean-square average.
  var detectorSeconds = 0.020
  var attackSeconds = 0.010
  var releaseSeconds = 0.150
  var makeupDB: Float = 4
  var ceilingDB: Float = -1
  var limiterReleaseSeconds = 0.050
  var rampSeconds = 0.030

  static let standard = VoiceBoostParameters()
}

/// The Voice Boost signal chain over non-interleaved Float32 buffers, processed in place.
///
/// Real-time contract: every buffer is allocated in `init` (a tap calls it from `prepare`) and
/// freed in `deinit` (from `unprepare`). `process` and `reset` never allocate, lock, log or touch
/// an actor, so the render thread may call them. Noncopyable: one owner, no reference counting on
/// the render thread.
///
/// Switching is a dry/wet ramp, so flipping `isEnabled` never clicks. Once off and ramped out,
/// `process` leaves the buffers untouched (bit-exact bypass). Leaving that idle state clears
/// filter and dynamics state first, and a processor first used on audio already playing (a late
/// tap attach) ramps in from dry.
nonisolated struct VoiceBoostDSP: ~Copyable {
  let channelCount: Int
  let maxFrames: Int
  /// Read by `process` at the start of each call; the tap sets it from its atomic flag.
  var isEnabled = false

  private let stages: VoiceBoostStages
  private let ceiling: Float
  private let thresholdDB: Float
  private let kneeDB: Float
  private let slope: Float
  private let makeupDB: Float
  private let detectorCoefficient: Float
  private let attackCoefficient: Float
  private let releaseCoefficient: Float
  private let limiterReleaseCoefficient: Float
  private let rampStep: Float

  /// One `vDSP_biquad` setup holds only coefficients, so every channel shares it; each channel
  /// owns its delay line (`2 × sections + 2` floats) in `delays`. `nil` when no filter stage runs.
  private let biquad: vDSP_biquad_Setup?
  private let delayLength: Int
  private let delays: UnsafeMutablePointer<Float>
  /// The input of the block being processed, per channel, `maxFrames` each: the filters read from
  /// it and the ramp mixes back to it.
  private let dry: UnsafeMutablePointer<Float>
  /// Scratch the length of one block: the detector level, then the gain applied.
  private let level: UnsafeMutablePointer<Float>
  private let gain: UnsafeMutablePointer<Float>

  /// The compressor detector's smoothed mean square, linear.
  private var meanSquare: Float = 0
  /// The compressor's smoothed gain change, in dB (0 or below).
  private var compressorGainDB: Float = 0
  /// The limiter's smoothed linear gain (1 or below).
  private var limiterGain: Float = 1
  /// The wet share of the output, 0...1.
  private var mix: Float = 0
  private var isIdle = true

  init?(
    sampleRate: Double, channelCount: Int, maxFrames: Int, stages: VoiceBoostStages = .all,
    parameters: VoiceBoostParameters = .standard
  ) {
    guard sampleRate > 0, channelCount > 0, maxFrames > 0 else { return nil }

    var coefficients: [Double] = []
    if stages.contains(.highPass) {
      coefficients += Self.highPassCoefficients(
        frequency: parameters.highPassHz, sampleRate: sampleRate)
    }
    if stages.contains(.lowMidCut) {
      coefficients += Self.peakingCoefficients(
        frequency: parameters.lowMidHz, gainDB: parameters.lowMidGainDB, q: parameters.lowMidQ,
        sampleRate: sampleRate)
    }
    if stages.contains(.presence) {
      coefficients += Self.peakingCoefficients(
        frequency: parameters.presenceHz, gainDB: parameters.presenceGainDB, q: parameters.presenceQ,
        sampleRate: sampleRate)
    }
    let sections = coefficients.count / 5
    if sections > 0 {
      guard let setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sections)) else { return nil }
      biquad = setup
    } else {
      biquad = nil
    }

    self.channelCount = channelCount
    self.maxFrames = maxFrames
    self.stages = stages
    ceiling = Float(pow(10, Double(parameters.ceilingDB) / 20))
    thresholdDB = parameters.thresholdDB
    kneeDB = parameters.kneeDB
    slope = 1 / parameters.ratio - 1
    makeupDB = parameters.makeupDB
    detectorCoefficient = Float(exp(-1 / (parameters.detectorSeconds * sampleRate)))
    attackCoefficient = Float(exp(-1 / (parameters.attackSeconds * sampleRate)))
    releaseCoefficient = Float(exp(-1 / (parameters.releaseSeconds * sampleRate)))
    limiterReleaseCoefficient = Float(exp(-1 / (parameters.limiterReleaseSeconds * sampleRate)))
    rampStep = Float(1 / (parameters.rampSeconds * sampleRate))

    delayLength = 2 * sections + 2
    delays = .allocate(capacity: channelCount * delayLength)
    delays.initialize(repeating: 0, count: channelCount * delayLength)
    dry = .allocate(capacity: channelCount * maxFrames)
    dry.initialize(repeating: 0, count: channelCount * maxFrames)
    level = .allocate(capacity: maxFrames)
    level.initialize(repeating: 0, count: maxFrames)
    gain = .allocate(capacity: maxFrames)
    gain.initialize(repeating: 0, count: maxFrames)
  }

  deinit {
    if let biquad { vDSP_biquad_DestroySetup(biquad) }
    delays.deallocate()
    dry.deallocate()
    level.deallocate()
    gain.deallocate()
  }

  /// Returns the processor to the state of a fresh one with the same `isEnabled`.
  mutating func reset() {
    delays.update(repeating: 0, count: channelCount * delayLength)
    meanSquare = 0
    compressorGainDB = 0
    limiterGain = 1
    mix = 0
    isIdle = true
  }

  /// Processes `frameCount` frames in place. `channels` holds `channelCount` buffer pointers.
  /// Splits anything longer than `maxFrames` itself.
  mutating func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
    guard frameCount > 0 else { return }
    if !isEnabled && mix == 0 {
      isIdle = true
      return
    }
    if isIdle {
      reset()
      isIdle = false
    }
    var offset = 0
    while offset < frameCount {
      let count = min(maxFrames, frameCount - offset)
      processBlock(channels, offset: offset, count: count)
      offset += count
    }
  }

  // MARK: - One block

  private mutating func processBlock(
    _ channels: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int
  ) {
    for channel in 0..<channelCount {
      (dry + channel * maxFrames).update(from: channels[channel] + offset, count: count)
    }
    if let biquad {
      for channel in 0..<channelCount {
        vDSP_biquad(
          biquad, delays + channel * delayLength, dry + channel * maxFrames, 1,
          channels[channel] + offset, 1, vDSP_Length(count))
      }
    }
    if stages.contains(.compressor) {
      compress(channels, offset: offset, count: count)
    }
    if stages.contains(.limiter) {
      limit(channels, offset: offset, count: count)
    }
    ramp(channels, offset: offset, count: count)
    if stages.contains(.limiter) {
      clip(channels, offset: offset, count: count)
    }
  }

  /// Writes the largest absolute sample across channels, per frame, into `level`.
  private func detectPeak(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int) {
    let length = vDSP_Length(count)
    vDSP_vabs(channels[0] + offset, 1, level, 1, length)
    for channel in 1..<channelCount {
      vDSP_vabs(channels[channel] + offset, 1, gain, 1, length)
      vDSP_vmax(level, 1, gain, 1, level, 1, length)
    }
  }

  /// Stereo-linked feed-forward compressor with a soft knee, gain smoothed in dB, plus makeup.
  /// The detector is RMS, not peak: a voice's peaks sit about 12 dB above its RMS, so a peak
  /// detector compresses nearly all speech and makeup cannot give the level back.
  private mutating func compress(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int) {
    detectPeak(channels, offset: offset, count: count)
    let length = vDSP_Length(count)
    vDSP_vsq(level, 1, level, 1, length)
    var average = meanSquare
    for index in 0..<count {
      average = detectorCoefficient * average + (1 - detectorCoefficient) * level[index]
      level[index] = average
    }
    meanSquare = average
    var floor: Float = 1e-12
    vDSP_vsadd(level, 1, &floor, level, 1, length)
    var n = Int32(count)
    vvlog10f(level, level, &n)
    var ten: Float = 10
    vDSP_vsmul(level, 1, &ten, level, 1, length)

    var smoothed = compressorGainDB
    let halfKnee = kneeDB / 2
    for index in 0..<count {
      let over = level[index] - thresholdDB
      let target: Float
      if over <= -halfKnee {
        target = 0
      } else if over < halfKnee {
        let into = over + halfKnee
        target = slope * into * into / (2 * kneeDB)
      } else {
        target = slope * over
      }
      let coefficient = target < smoothed ? attackCoefficient : releaseCoefficient
      smoothed = coefficient * smoothed + (1 - coefficient) * target
      gain[index] = smoothed + makeupDB
    }
    compressorGainDB = smoothed

    // 10^(dB / 20) as e^(dB × ln 10 / 20): vForce has no base-10 exponential.
    var toNatural = Float(M_LN10 / 20)
    vDSP_vsmul(gain, 1, &toNatural, gain, 1, length)
    vvexpf(gain, gain, &n)
    for channel in 0..<channelCount {
      vDSP_vmul(channels[channel] + offset, 1, gain, 1, channels[channel] + offset, 1, length)
    }
  }

  /// Instant-attack peak limiter at `ceiling`. `clip` catches the last float's worth, after the ramp.
  private mutating func limit(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int) {
    detectPeak(channels, offset: offset, count: count)
    var current = limiterGain
    for index in 0..<count {
      let peak = level[index]
      let target = peak > ceiling ? ceiling / peak : 1
      if target < current {
        current = target
      } else {
        current = limiterReleaseCoefficient * current + (1 - limiterReleaseCoefficient) * target
      }
      gain[index] = current
    }
    limiterGain = current
    let length = vDSP_Length(count)
    for channel in 0..<channelCount {
      let samples = channels[channel] + offset
      vDSP_vmul(samples, 1, gain, 1, samples, 1, length)
    }
  }

  /// The last step whenever the processor is engaged: the ramp mixes the unlimited dry input back
  /// in, so the ceiling only holds if the clip comes after it.
  private func clip(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int) {
    var low = -ceiling
    var high = ceiling
    for channel in 0..<channelCount {
      let samples = channels[channel] + offset
      vDSP_vclip(samples, 1, &low, &high, samples, 1, vDSP_Length(count))
    }
  }

  /// Mixes the processed block with the dry input while `mix` moves towards its target.
  private mutating func ramp(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, offset: Int, count: Int) {
    let target: Float = isEnabled ? 1 : 0
    if mix == target && target == 1 { return }
    var current = mix
    for index in 0..<count {
      if current < target {
        current = min(target, current + rampStep)
      } else if current > target {
        current = max(target, current - rampStep)
      }
      gain[index] = current
    }
    mix = current
    for channel in 0..<channelCount {
      let wet = channels[channel] + offset
      let source = dry + channel * maxFrames
      for index in 0..<count {
        let share = gain[index]
        wet[index] = share == 0 ? source[index] : source[index] + share * (wet[index] - source[index])
      }
    }
  }

  // MARK: - Coefficients

  /// Second-order Butterworth high-pass (RBJ cookbook), as `b0 b1 b2 a1 a2` normalised by `a0`.
  static func highPassCoefficients(frequency: Double, sampleRate: Double) -> [Double] {
    let omega = 2 * Double.pi * frequency / sampleRate
    let cosine = cos(omega)
    let alpha = sin(omega) / (2 * (1 / 2.0.squareRoot()))
    let a0 = 1 + alpha
    return [
      (1 + cosine) / 2 / a0, -(1 + cosine) / a0, (1 + cosine) / 2 / a0, -2 * cosine / a0, (1 - alpha) / a0,
    ]
  }

  /// Peaking EQ (RBJ cookbook), as `b0 b1 b2 a1 a2` normalised by `a0`.
  static func peakingCoefficients(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> [Double] {
    let amplitude = pow(10, gainDB / 40)
    let omega = 2 * Double.pi * frequency / sampleRate
    let cosine = cos(omega)
    let alpha = sin(omega) / (2 * q)
    let a0 = 1 + alpha / amplitude
    return [
      (1 + alpha * amplitude) / a0, -2 * cosine / a0, (1 - alpha * amplitude) / a0, -2 * cosine / a0,
      (1 - alpha / amplitude) / a0,
    ]
  }
}
