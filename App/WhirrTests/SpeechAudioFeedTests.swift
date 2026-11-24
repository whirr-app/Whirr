import AVFoundation
import AdSkip
import CoreMedia
import Foundation
import Speech
import Testing

@testable import Whirr

/// The feed both speech adapters share: a slice read as the player reads it, converted to the
/// analyser's format and stamped on the player's clock. Nonisolated: converting seconds of audio on the main
/// actor would stall timing tests that share it.
@Suite("Speech audio feed")
nonisolated struct SpeechAudioFeedTests {

  private static let sourceRate = 44_100.0
  private static let targetRate = 16_000.0

  private func writeFile(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("feed-\(UUID().uuidString).wav")
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Self.sourceRate, channels: 1,
        interleaved: false))
    let file = try AVAudioFile(
      forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
      interleaved: false)
    let frames = AVAudioFrameCount((seconds * Self.sourceRate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    for frame in 0..<Int(frames) { data[0][frame] = Float(sin(Double(frame) * 0.05)) * 0.3 }
    try file.write(from: buffer)
    return url
  }

  private func target() throws -> AVAudioFormat {
    try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Self.targetRate, channels: 1,
        interleaved: false))
  }

  /// Every input the feed yields until it ends.
  private func drain(_ feed: inout SpeechAudioFeed) throws -> [AnalyzerInput] {
    var inputs: [AnalyzerInput] = []
    while let next = try feed.next() { inputs += next }
    return inputs
  }

  @Test("buffers abut on the file's clock from the slice's first frame")
  func buffersAbut() async throws {
    let url = try writeFile(seconds: 3)
    defer { try? FileManager.default.removeItem(at: url) }
    var feed = try await SpeechAudioFeed.open(url: url, target: try target(), slice: TimeSpan(start: 0.5, end: 2.5))

    let inputs = try drain(&feed)

    let first = try #require(inputs.first)
    #expect(first.bufferStartTime?.value == Int64(0.5 * Self.targetRate))
    #expect(first.bufferStartTime?.timescale == CMTimeScale(Self.targetRate))
    for (previous, next) in zip(inputs, inputs.dropFirst()) {
      let end = (previous.bufferStartTime?.value ?? 0) + Int64(previous.buffer.frameLength)
      #expect(next.bufferStartTime?.value == end)
    }
  }

  @Test("the slice is fed in full and the fed time reaches its end")
  func feedsTheWholeSlice() async throws {
    let url = try writeFile(seconds: 3)
    defer { try? FileManager.default.removeItem(at: url) }
    var feed = try await SpeechAudioFeed.open(url: url, target: try target(), slice: TimeSpan(start: 0.5, end: 2.5))

    let inputs = try drain(&feed)

    let frames = inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
    #expect(abs(Double(frames) / Self.targetRate - 2) < 0.01)
    #expect(abs(feed.fedThroughSeconds - 2.5) < 0.01)
    #expect(try feed.next() == nil)
  }

  @Test("a slice past the end of the file stops at the file's end")
  func stopsAtTheFileEnd() async throws {
    let url = try writeFile(seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    var feed = try await SpeechAudioFeed.open(url: url, target: try target(), slice: TimeSpan(start: 0, end: 5))

    _ = try drain(&feed)

    #expect(abs(feed.fedThroughSeconds - 1) < 0.01)
  }

  @Test("an empty slice yields nothing")
  func emptySlice() async throws {
    let url = try writeFile(seconds: 1)
    defer { try? FileManager.default.removeItem(at: url) }
    var feed = try await SpeechAudioFeed.open(url: url, target: try target(), slice: TimeSpan(start: 2, end: 3))

    #expect(try feed.next() == nil)
  }

  @Test("the asset's duration is the file's length")
  func assetDuration() async throws {
    let url = try writeFile(seconds: 3)
    defer { try? FileManager.default.removeItem(at: url) }

    let duration = try await SpeechAudioFeed.duration(ofFileAt: url)

    #expect(abs(duration - 3) < 0.02)
  }

  /// A file joined from parts, as some audiobooks are: `shortened` packets just after the start
  /// have a container duration of one tick, though each still decodes to a full packet. Silent but
  /// for a burst that starts `burstAt` seconds into the decoded audio.
  private func writeJoinedFile(seconds: Double, burstAt: Double, shortened: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("feed-joined-\(UUID().uuidString).m4a")
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sourceRate,
        AVNumberOfChannelsKey: 1,
      ],
      commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount((seconds * Self.sourceRate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    let burst = Int(burstAt * Self.sourceRate)..<Int((burstAt + 0.2) * Self.sourceRate)
    for frame in 0..<Int(frames) {
      data[0][frame] = burst.contains(frame) ? Float(sin(Double(frame) * 0.3)) * 0.8 : 0
    }
    try file.write(from: buffer)
    file.close()
    var movie = try MP4Boxes(data: Data(contentsOf: url))
    try movie.shortenPackets(20..<(20 + shortened))
    try movie.data.write(to: url)
    return url
  }

  /// Where the first loud sample lands on the feed's clock, in seconds.
  private func burstOnset(_ inputs: [AnalyzerInput]) throws -> Double? {
    for input in inputs {
      // One reference held across the reads: the channel pointer lives only as long as it does.
      let buffer = input.buffer
      let start = try #require(input.bufferStartTime)
      let loud = try withExtendedLifetime(buffer) { () throws -> Int? in
        let samples = try #require(buffer.int16ChannelData)
        return (0..<Int(buffer.frameLength)).first { abs(Int(samples[0][$0])) > 6_000 }
      }
      if let loud { return (Double(start.value) + Double(loud)) / Self.targetRate }
    }
    return nil
  }

  @Test("a slice of a joined file lands where the player seeks, not where the decode counts")
  func stampsOnThePlayersClock() async throws {
    let url = try writeJoinedFile(seconds: 12, burstAt: 8, shortened: 40)
    defer { try? FileManager.default.removeItem(at: url) }
    var feed = try await SpeechAudioFeed.open(
      url: url, target: try target(), slice: TimeSpan(start: 5, end: 10))

    let onset = try #require(try burstOnset(drain(&feed)))

    // Each shortened packet is one tick long on the player's clock instead of 1,024 frames, so
    // the burst comes that much earlier than in the decode, where `AVAudioFile` puts it (8 s).
    let expected = 8 - 40 * 1_023 / Self.sourceRate
    #expect(abs(onset - expected) < 0.02, "onset \(onset) s, expected \(expected) s")
  }
}

/// Just enough of an MP4 file's box tree to rewrite its one audio track's sample durations, for a
/// fixture no encoder writes. The movie box is expected before the media data, as `AVAudioFile`
/// writes it, so the chunk offsets move by whatever the table grows.
private nonisolated struct MP4Boxes {
  enum Failure: Error { case missing(String) }

  var data: Data

  private func u32(_ offset: Int) -> Int {
    data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
  }

  private mutating func put(_ value: Int, at offset: Int) {
    for byte in 0..<4 {
      data[data.startIndex + offset + byte] = UInt8((value >> (24 - 8 * byte)) & 0xff)
    }
  }

  private func find(_ type: String, in range: Range<Int>) throws -> Int {
    var offset = range.lowerBound
    while offset < range.upperBound {
      let start = data.startIndex + offset
      if String(decoding: data[start + 4..<start + 8], as: UTF8.self) == type { return offset }
      offset += u32(offset)
    }
    throw Failure.missing(type)
  }

  /// Gives each packet in `packets` a duration of one tick.
  mutating func shortenPackets(_ packets: Range<Int>) throws {
    var parents: [Int] = []
    var range = 0..<data.count
    for type in ["moov", "trak", "mdia", "minf", "stbl"] {
      let offset = try find(type, in: range)
      parents.append(offset)
      range = (offset + 8)..<(offset + u32(offset))
    }
    let table = try find("stts", in: range)
    let chunks = try find("stco", in: range)
    var durations: [Int] = []
    for entry in 0..<u32(table + 12) {
      durations += Array(repeating: u32(table + 20 + 8 * entry), count: u32(table + 16 + 8 * entry))
    }
    for packet in packets { durations[packet] = 1 }
    var runs: [(count: Int, duration: Int)] = []
    for duration in durations {
      if runs.last?.duration == duration { runs[runs.count - 1].count += 1 } else { runs.append((1, duration)) }
    }
    var box = Data()
    func append(_ value: Int) { box += (0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xff) } }
    append(16 + 8 * runs.count)
    box += Data("stts".utf8)
    append(0)
    append(runs.count)
    for run in runs {
      append(run.count)
      append(run.duration)
    }
    let growth = box.count - u32(table)
    let chunkCount = u32(chunks + 12)
    let chunkOffsets = (0..<chunkCount).map { u32(chunks + 16 + 4 * $0) }
    let start = data.startIndex + table
    data.replaceSubrange(start..<start + u32(table), with: box)
    for parent in parents { put(u32(parent) + growth, at: parent) }
    // `stco` follows `stts` in the sample table, so it has moved by the growth too.
    let movedChunks = chunks > table ? chunks + growth : chunks
    for (index, offset) in chunkOffsets.enumerated() { put(offset + growth, at: movedChunks + 16 + 4 * index) }
  }
}
