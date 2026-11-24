import AVFoundation
import MediaToolbox
import TestSupport
import Testing

@testable import Whirr

/// The tap's own state, driven directly, then a real tap on a real `AVPlayerItem` playing audio
/// generated at test time.
@MainActor
@Suite("Voice Boost tap")
struct VoiceBoostTapTests {

  private static let rate = 44_100.0

  // MARK: - Tap state, without a player

  @Test("a format the chain does not process passes through untouched and is counted")
  func unsupportedFormatBypasses() {
    let factory = VoiceBoostTapFactory()
    factory.isEnabled = true
    let storage = factory.makeStorage()
    defer { VoiceBoostTapFactory.releaseStorage(storage) }

    var int16 = Self.floatFormat(channels: 2)
    int16.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved
    int16.mBitsPerChannel = 16
    storage.pointee.prepare(format: int16, maxFrames: 512)

    let isProcessing = storage.pointee.isProcessing

    #expect(!isProcessing)
    #expect(factory.formatBypasses == 1)
    let input = Self.sine(frames: 512, amplitude: 0.5)
    let output = Self.render(storage, channels: [input, input])
    #expect(output == [input, input])
  }

  @Test("a late-attached tap starts dry and ramps to processed audio")
  func lateAttachRampsFromDry() {
    let factory = VoiceBoostTapFactory()
    factory.isEnabled = true
    let storage = factory.makeStorage()
    defer { VoiceBoostTapFactory.releaseStorage(storage) }
    storage.pointee.prepare(format: Self.floatFormat(channels: 2), maxFrames: 4_096)
    let isProcessing = storage.pointee.isProcessing
    #expect(isProcessing)

    let input = Self.sine(frames: Int(Self.rate), amplitude: 0.1)
    let output = Self.render(storage, channels: [input, input], block: 512)[0]

    #expect(abs(output[0] - input[0]) <= 1e-4, "the first sample is the dry input")
    let window = Int(0.05 * Self.rate)
    let steps = zip(output[..<window], output[1..<window]).map { abs($1 - $0) }
    let tailStart = output.count - Int(0.2 * Self.rate)
    let tail = Array(output[tailStart...])
    let tailSteps = zip(tail, tail.dropFirst()).map { abs($1 - $0) }
    let inputSteps = zip(input, input.dropFirst()).map { abs($1 - $0) }
    let bound = max(inputSteps.max() ?? 0, tailSteps.max() ?? 0) + 0.001
    #expect((steps.max() ?? 0) <= bound, "no step larger than the dry or processed signal's own")
    #expect(Self.rms(tail) > Self.rms(Array(input[tailStart...])) * 1.1, "processed by the end")
    #expect(factory.framesRendered == input.count)
  }

  @Test("the factory's switch reaches a running tap, and off returns bit-exact audio")
  func switchReachesTheTap() {
    let factory = VoiceBoostTapFactory()
    let storage = factory.makeStorage()
    defer { VoiceBoostTapFactory.releaseStorage(storage) }
    storage.pointee.prepare(format: Self.floatFormat(channels: 1), maxFrames: 1_024)
    let block = Self.sine(frames: 4_410, amplitude: 0.1)

    #expect(Self.render(storage, channels: [block]) == [block], "off from the start")
    factory.isEnabled = true
    #expect(Self.render(storage, channels: [block]) != [block], "on")
    factory.isEnabled = false
    _ = Self.render(storage, channels: [block])  // the ramp back down
    #expect(Self.render(storage, channels: [block]) == [block], "off again")
  }

  @Test("a buffer list that does not match the prepared channels passes through")
  func mismatchedBufferListBypasses() {
    let factory = VoiceBoostTapFactory()
    factory.isEnabled = true
    let storage = factory.makeStorage()
    defer { VoiceBoostTapFactory.releaseStorage(storage) }
    storage.pointee.prepare(format: Self.floatFormat(channels: 2), maxFrames: 512)
    let input = Self.sine(frames: 512, amplitude: 1)

    #expect(Self.render(storage, channels: [input]) == [input])
    #expect(factory.formatBypasses == 1)
  }

  @Test("prepare can run again, and unprepare more than once")
  func preparesRepeatedly() {
    let factory = VoiceBoostTapFactory()
    factory.isEnabled = true
    let storage = factory.makeStorage()
    defer { VoiceBoostTapFactory.releaseStorage(storage) }
    storage.pointee.prepare(format: Self.floatFormat(channels: 2), maxFrames: 512)
    storage.pointee.prepare(format: Self.floatFormat(channels: 6), maxFrames: 1_024)
    let isProcessing = storage.pointee.isProcessing
    #expect(isProcessing)
    let input = Self.sine(frames: 256, amplitude: 0.1)
    let output = Self.render(storage, channels: Array(repeating: input, count: 6))
    #expect(output.count == 6)
    storage.pointee.unprepare()
    storage.pointee.unprepare()
    let isProcessingAfter = storage.pointee.isProcessing
    #expect(!isProcessingAfter)
  }

  @Test("a tap keeps its factory alive until the tap is released")
  func tapOwnsItsFactory() throws {
    weak var weakFactory: VoiceBoostTapFactory?
    var tap: MTAudioProcessingTap?
    do {
      let factory = VoiceBoostTapFactory()
      weakFactory = factory
      tap = factory.makeTap()
    }
    #expect(tap != nil)
    #expect(weakFactory != nil, "the tap's storage holds the factory")
    tap = nil
    #expect(weakFactory == nil, "finalize released it")
  }

  // MARK: - A real player item

  /// The tap must see at least 99% of the frames the item played. The denominator is the whole
  /// file, played from 0 to its end.
  @Test("a real item's tap sees every frame it plays", .timeLimit(.minutes(1)))
  func realItemRunsTheTap() async throws {
    let seconds = 2.0
    let url = try Self.writeSineFile(seconds: seconds)
    defer { try? FileManager.default.removeItem(at: url) }
    let factory = VoiceBoostTapFactory()
    factory.isEnabled = true
    let handle = try #require(
      AVFoundationPlayerItemFactory().makeItem(resource: PlaybackTrackResource(trackIndex: 0, url: url))
        as? RealAudioPlayerItemHandle)
    handle.attachAudioProcessor(factory)
    let attached = await waitUntil("the audio mix lands on the item", timeout: 10) {
      handle.item.audioMix != nil
    }
    try #require(attached)

    var finished = false
    handle.onDidPlayToEnd = { finished = true }
    let player = AVPlayer(playerItem: handle.item)
    player.isMuted = true
    player.play()
    let ended = await awaitCondition(
      "the item plays to its end", timeout: 30,
      observing: { "time \(player.currentTime().seconds) frames \(factory.framesRendered)" },
      until: { finished })
    player.pause()
    try #require(ended == .observed)

    let expected = Int(seconds * Self.rate)
    #expect(Double(factory.framesRendered) >= 0.99 * Double(expected), "frames \(factory.framesRendered)")
    #expect(factory.formatBypasses == 0, "the simulator delivered a format the chain processes")
  }

  // MARK: - Helpers

  private static func floatFormat(channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
      mBitsPerChannel: 32, mReserved: 0)
  }

  private static func sine(frames: Int, amplitude: Float, frequency: Double = 440) -> [Float] {
    (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
  }

  private static func rms(_ samples: [Float]) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
  }

  /// Renders `channels` through the tap state in blocks, the way MediaToolbox hands it buffers.
  private static func render(
    _ storage: UnsafeMutablePointer<VoiceBoostTapState>, channels: [[Float]], block: Int? = nil
  ) -> [[Float]] {
    let frames = channels[0].count
    let step = block ?? frames
    var output = channels
    var start = 0
    while start < frames {
      let count = min(step, frames - start)
      let list = AudioBufferList.allocate(maximumBuffers: channels.count)
      defer { free(list.unsafeMutablePointer) }
      let buffers = channels.indices.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: count) }
      defer { for buffer in buffers { buffer.deallocate() } }
      for (index, buffer) in buffers.enumerated() {
        buffer.initialize(from: Array(output[index][start..<(start + count)]), count: count)
        list[index] = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(count * MemoryLayout<Float>.size), mData: buffer)
      }
      storage.pointee.render(list.unsafeMutablePointer, frameCount: count)
      for (index, buffer) in buffers.enumerated() {
        output[index].replaceSubrange(
          start..<(start + count), with: UnsafeBufferPointer(start: buffer, count: count))
      }
      start += count
    }
    return output
  }

  private static func writeSineFile(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "voice-boost-\(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = sine(frames: Int(frames), amplitude: 0.2)
    for channel in 0..<2 {
      let destination = try #require(buffer.floatChannelData?[channel])
      destination.update(from: samples, count: samples.count)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
  }
}
