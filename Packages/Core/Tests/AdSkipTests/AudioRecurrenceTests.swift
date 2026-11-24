import Foundation
import Testing

@testable import AdSkip

@Suite struct AudioRecurrenceTests {
  /// The library `golden.py` builds with the same generator: one 3,000-frame segment shared by
  /// episodes a (exact), b (about one bit in eight flipped) and c (its middle half only); a
  /// 400-frame run of one common hash in a and b; and d, a linked copy of a.
  private static func library() -> [AudioRecurrence.Reference] {
    var random = SplitMix64(seed: 42)
    func word() -> UInt32 { UInt32(truncatingIfNeeded: random.next()) }
    let segment = (0..<3000).map { _ in word() }
    var a = (0..<20000).map { _ in word() }
    var b = (0..<15000).map { _ in word() }
    var c = (0..<12000).map { _ in word() }
    a.replaceSubrange(5000..<8000, with: segment)
    b.replaceSubrange(8000..<11000, with: segment.map { $0 ^ (word() & word() & word()) })
    c.replaceSubrange(1000..<2500, with: segment[1000..<2500])
    for i in 0..<400 {
      a[15000 + i] = 0xDEAD_BEEF
      b[1000 + i] = 0xDEAD_BEEF
    }
    let keys: [Set<EpisodeKey>] = [[EpisodeKey("a")], [EpisodeKey("b")], [EpisodeKey("c")], [EpisodeKey("a")]]
    return zip([a, b, c, a], keys).map { AudioRecurrence.Reference(print: AudioPrint(words: $0), keys: $1) }
  }

  /// Runs `audiocand.py` `audio_runs` gave for the same library, to the last bit.
  @Test func runsMatchTheHarness() {
    let library = Self.library()
    let expected: [[TimeSpan]] = [
      [TimeSpan(start: 58.03193033381713, end: 93.27140783744557)],
      [TimeSpan(start: 92.86502177068215, end: 128.1044992743106)],
      [TimeSpan(start: 11.518142235123367, end: 29.4455732946299)],
      [TimeSpan(start: 58.03193033381713, end: 93.27140783744557)],
    ]
    for query in library.indices {
      #expect(AudioRecurrence.runs(of: query, in: library) == expected[query], "query \(query)")
    }
  }

  @Test func linkedCopiesNeverMatchEachOther() {
    let library = Self.library()
    // Only a and its copy d: everything would match, but they share a key.
    let pair = [library[0], library[3]]
    #expect(AudioRecurrence.runs(of: 0, in: pair).isEmpty)
    let unlinked = [library[0], AudioRecurrence.Reference(print: library[3].print, keys: [EpisodeKey("z")])]
    let runs = AudioRecurrence.runs(of: 0, in: unlinked)
    #expect(runs.count == 1)
    #expect((runs.first?.duration ?? 0) > 200)
  }

  @Test func aSliceOfAPrintMatchesLikeTheWholePrint() {
    // A learned ad keeps only its range's print; matching against it finds the same audio.
    let library = Self.library()
    let creative = AudioRecurrence.Reference(
      print: library[0].print.slice(from: 5000, to: 8000), keys: [EpisodeKey("a")])
    let runs = AudioRecurrence.runs(of: 0, in: [library[1], creative])
    #expect(runs.count == 1)
    #expect(abs((runs.first?.start ?? 0) - AudioPrint.time(ofFrame: 8000)) < 0.5)
    #expect(abs((runs.first?.end ?? 0) - AudioPrint.time(ofFrame: 11000)) < 0.5)
  }

  @Test func copiesShareAlmostAllTheirAudioAndEpisodesSharingASegmentLittle() {
    let library = Self.library()
    // a and its copy d: everything recurs.
    #expect(AudioRecurrence.sharedFraction(of: library[0].print, and: library[3].print) > 0.9)
    // a and b share one 35 s segment: the smaller share is b's 35 s of 174 s at most.
    let segment = AudioRecurrence.sharedFraction(of: library[0].print, and: library[1].print)
    #expect(segment > 0.1)
    #expect(segment < 0.25)
    #expect(AudioRecurrence.sharedFraction(of: library[0].print, and: AudioPrint(words: [])) == 0)
  }

  @Test func anEmptyOrLoneLibraryHasNoRuns() {
    let lone = [AudioRecurrence.Reference(print: AudioPrint(words: []), keys: [EpisodeKey("a")])]
    #expect(AudioRecurrence.runs(of: 0, in: lone).isEmpty)
    let library = Self.library()
    #expect(AudioRecurrence.runs(of: 0, in: [library[0]]).isEmpty)
  }

  @Test func recurrenceGivesTheRunsAlone() {
    let library = Self.library()
    for query in library.indices {
      #expect(
        AudioRecurrence.recurrence(of: query, in: library).runs
          == AudioRecurrence.runs(of: query, in: library), "query \(query)")
    }
  }

  /// Every second a run covers, some alignment covers, and the reverse, to within a block's
  /// refinement at each edge.
  @Test func alignmentsCoverWhatTheRunsCover() {
    let library = Self.library()
    for query in library.indices {
      let recurrence = AudioRecurrence.recurrence(of: query, in: library)
      let covered = recurrence.alignments.map(\.span).sorted { $0.start < $1.start }
      #expect(recurrence.runs.isEmpty == covered.isEmpty, "query \(query)")
      for run in recurrence.runs {
        let overlapping = covered.filter { $0.start < run.end && $0.end > run.start }
        #expect(abs((overlapping.map(\.start).min() ?? 0) - run.start) < 1, "query \(query)")
        #expect(abs((overlapping.map(\.end).max() ?? 0) - run.end) < 1, "query \(query)")
      }
      for alignment in recurrence.alignments {
        #expect(alignment.reference != query)
        #expect(library[alignment.reference].keys.isDisjoint(with: library[query].keys))
        #expect(recurrence.runs.contains { $0.start < alignment.span.end && $0.end > alignment.span.start })
      }
    }
  }

  /// An ad boundary: the query plays a stretch of one reference straight into a stretch of
  /// another. `runs` joins them into one; the alignments keep each reference's own stretch.
  @Test func twoReferencesMeetingInsideOneRunAlignSeparately() throws {
    var random = SplitMix64(seed: 7)
    func words(_ count: Int) -> [UInt32] {
      (0..<count).map { _ in UInt32(truncatingIfNeeded: random.next()) }
    }
    let first = words(2500)
    let second = words(2500)
    let query = words(3000) + first + second + words(3000)
    let library = [
      AudioRecurrence.Reference(print: AudioPrint(words: query), keys: [EpisodeKey("q")]),
      AudioRecurrence.Reference(
        print: AudioPrint(words: words(4000) + first + words(4000)), keys: [EpisodeKey("a")]),
      AudioRecurrence.Reference(
        print: AudioPrint(words: words(1000) + second + words(6000)), keys: [EpisodeKey("b")]),
    ]
    let recurrence = AudioRecurrence.recurrence(of: 0, in: library)
    let run = try #require(recurrence.runs.first)
    #expect(recurrence.runs.count == 1)
    #expect(abs(run.start - AudioPrint.time(ofFrame: 3000)) < 0.5)
    #expect(abs(run.end - AudioPrint.time(ofFrame: 8000)) < 0.5)

    #expect(recurrence.alignments.map(\.reference) == [1, 2])
    let a = try #require(recurrence.alignments.first { $0.reference == 1 }).span
    let b = try #require(recurrence.alignments.first { $0.reference == 2 }).span
    #expect(abs(a.start - AudioPrint.time(ofFrame: 3000)) < 0.5)
    #expect(abs(a.end - AudioPrint.time(ofFrame: 5500)) < 0.5)
    #expect(abs(b.start - AudioPrint.time(ofFrame: 5500)) < 0.5)
    #expect(abs(b.end - AudioPrint.time(ofFrame: 8000)) < 0.5)
  }

  @Test func printsRoundTripThroughLittleEndianData() {
    let words: [UInt32] = [0, 1, 0xDEAD_BEEF, 0xFFFF_FFFF]
    let print = AudioPrint(words: words)
    #expect(print.data == Data([0, 0, 0, 0, 1, 0, 0, 0, 0xEF, 0xBE, 0xAD, 0xDE, 255, 255, 255, 255]))
    #expect(AudioPrint(littleEndianData: print.data)?.words == words)
    #expect(AudioPrint(littleEndianData: Data([1, 2, 3])) == nil)
    #expect(print.slice(from: 1, to: 3).words == [1, 0xDEAD_BEEF])
    #expect(print.slice(from: 3, to: 99).words == [0xFFFF_FFFF])
    // Misaligned storage is copied rather than read in place.
    let shifted = Data([9] + print.data).dropFirst()
    #expect(AudioPrint(littleEndianData: Data(shifted))?.words == words)
  }

  /// The file store hands over the words as a slice past the file header, so `data` does not
  /// start at index 0.
  @Test func slicesAPrintWhoseDataDoesNotStartAtZero() throws {
    let words: [UInt32] = [0, 1, 0xDEAD_BEEF, 0xFFFF_FFFF]
    let file = Data(repeating: 0xAA, count: 8) + AudioPrint(words: words).data
    let print = try #require(AudioPrint(littleEndianData: file.dropFirst(8)))
    #expect(print.slice(from: 0, to: 1).words == [0])
    #expect(print.slice(from: 1, to: 3).words == [1, 0xDEAD_BEEF])
    #expect(print.slice(from: 3, to: 99).words == [0xFFFF_FFFF])
  }

  @Test func frameTimesAreTheHarnesss() {
    #expect(AudioPrint.time(ofFrame: 0) == 2048.0 / 5512.0 / 2)
    #expect(AudioPrint.time(ofFrame: 5000) == 5000 * (64.0 / 5512.0) + (2048.0 / 5512.0) / 2)
    #expect(AudioPrint.frame(atTime: 58.1) == Int(58.1 / (64.0 / 5512.0)))
  }
}
