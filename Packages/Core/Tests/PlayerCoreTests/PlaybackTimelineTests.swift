import Testing

@testable import PlayerCore

/// One global book timeline over many server tracks, built from pure `startOffset`/`duration`
/// arithmetic (ARCHITECTURE.md §4). No AVFoundation or I/O, so every case is deterministic.
@Suite struct PlaybackTimelineTests {

  // MARK: - Track ordering

  @Test func unsortedTrackIndicesProduceTheSameTimelineAsSortedInput() throws {
    let sortedInput = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 50),
      PlaybackTrack(index: 2, duration: 75),
    ])
    let unsortedInput = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 2, duration: 75),
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 50),
    ])
    #expect(sortedInput.tracks.map(\.index) == [0, 1, 2])
    #expect(unsortedInput.tracks.map(\.index) == [0, 1, 2])
    #expect(sortedInput == unsortedInput)
    #expect(sortedInput.totalDuration == 225)
  }

  // MARK: - Start offsets

  @Test func explicitStartOffsetsAreUsedVerbatim() throws {
    // Track 1's explicit offset (200) disagrees with the cumulative sum (100); the explicit
    // value wins.
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, startOffset: 0, duration: 100),
      PlaybackTrack(index: 1, startOffset: 200, duration: 50),
    ])
    let (track, local) = timeline.trackAndLocalOffset(atGlobalOffset: 210)
    #expect(track.index == 1)
    #expect(local == 10)
  }

  @Test func cumulativeFallbackIsUsedWhenAnOffsetIsAbsent() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 50),
      PlaybackTrack(index: 2, duration: 75),
    ])
    let (track1, local1) = timeline.trackAndLocalOffset(atGlobalOffset: 120)
    #expect(track1.index == 1)
    #expect(local1 == 20)
    let (track2, local2) = timeline.trackAndLocalOffset(atGlobalOffset: 150)
    #expect(track2.index == 2)
    #expect(local2 == 0)
  }

  @Test func mixedExplicitAndFallbackOffsetsChainCorrectly() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, startOffset: 10, duration: 40),
      // No explicit offset: falls back to track 0's end (10 + 40 = 50).
      PlaybackTrack(index: 1, duration: 30),
    ])
    let (track, local) = timeline.trackAndLocalOffset(atGlobalOffset: 55)
    #expect(track.index == 1)
    #expect(local == 5)
  }

  // MARK: - Duration validation

  @Test func zeroDurationIsRejected() {
    #expect(throws: PlaybackTimelinePreparationError.invalidDuration(trackIndex: 0)) {
      try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 0)])
    }
  }

  @Test func negativeDurationIsRejected() {
    #expect(throws: PlaybackTimelinePreparationError.invalidDuration(trackIndex: 0)) {
      try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: -5)])
    }
  }

  @Test func missingDurationIsRejected() {
    #expect(throws: PlaybackTimelinePreparationError.invalidDuration(trackIndex: 0)) {
      try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: nil)])
    }
  }

  @Test func nonFiniteDurationIsRejected() {
    #expect(throws: PlaybackTimelinePreparationError.invalidDuration(trackIndex: 1)) {
      try PlaybackTimeline(tracks: [
        PlaybackTrack(index: 0, duration: 10),
        PlaybackTrack(index: 1, duration: .infinity),
      ])
    }
  }

  @Test func emptyTrackListIsRejected() {
    #expect(throws: PlaybackTimelinePreparationError.noTracks) {
      try PlaybackTimeline(tracks: [])
    }
  }

  // MARK: - Boundaries

  @Test func exactStartAndEndBoundariesResolveToTheExpectedTrack() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 50),
    ])
    // The very start of the book.
    let start = timeline.trackAndLocalOffset(atGlobalOffset: 0)
    #expect(start.track.index == 0)
    #expect(start.localOffset == 0)
    // The interior boundary belongs to the next track, not the tail of the previous one.
    let boundary = timeline.trackAndLocalOffset(atGlobalOffset: 100)
    #expect(boundary.track.index == 1)
    #expect(boundary.localOffset == 0)
    // The final boundary (book end) belongs to the last track, since there is no next one.
    let end = timeline.trackAndLocalOffset(atGlobalOffset: 150)
    #expect(end.track.index == 1)
    #expect(end.localOffset == 50)
  }

  @Test func seekingExactlyToBookEndLandsOnTheLastTrackAtItsOwnEnd() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 30),
      PlaybackTrack(index: 1, duration: 45),
      PlaybackTrack(index: 2, duration: 15),
    ])
    let (track, local) = timeline.trackAndLocalOffset(atGlobalOffset: timeline.totalDuration)
    #expect(track.index == 2)
    #expect(local == 15)
  }

  // MARK: - Clamping

  @Test func negativeGlobalOffsetClampsToTheBookStart() throws {
    let timeline = try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    let (track, local) = timeline.trackAndLocalOffset(atGlobalOffset: -50)
    #expect(track.index == 0)
    #expect(local == 0)
  }

  @Test func globalOffsetPastTheEndClampsToTheBookEnd() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 50),
    ])
    let (track, local) = timeline.trackAndLocalOffset(atGlobalOffset: 999)
    #expect(track.index == 1)
    #expect(local == 50)
  }

  @Test func localOffsetPastATracksOwnDurationClampsWhenMappingBackToGlobal() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 50),
    ])
    #expect(timeline.globalOffset(forTrackIndex: 0, localOffset: 500) == 100)
    #expect(timeline.globalOffset(forTrackIndex: 0, localOffset: -500) == 0)
  }

  @Test func globalOffsetForAnUnknownTrackIndexReturnsNil() throws {
    let timeline = try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    #expect(timeline.globalOffset(forTrackIndex: 7, localOffset: 0) == nil)
  }

  // MARK: - Round trips

  @Test func globalToTrackToGlobalRoundTripsWithinOneMillisecond() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 50),
      PlaybackTrack(index: 2, duration: 75),
    ])
    for offset in stride(from: 0.0, through: timeline.totalDuration, by: 12.5) {
      let (track, local) = timeline.trackAndLocalOffset(atGlobalOffset: offset)
      let roundTripped = timeline.globalOffset(forTrackIndex: track.index, localOffset: local)
      let roundTrippedUnwrapped = try #require(roundTripped)
      #expect(abs(roundTrippedUnwrapped - offset) < 0.001)
    }
  }

  // MARK: - Property tests (deterministic, seeded with `SplitMix64` below)

  /// Generates only valid (monotonic) timelines, then proves: (1) round trips of in-range
  /// offsets are stable within 1 ms, and (2) the mapping is monotonic, so larger global offsets
  /// never map back to a smaller reconstructed global position.
  @Test(arguments: Array(0..<200))
  func mappingIsMonotonicAndRoundTripsAreStableForGeneratedTimelines(seed: Int) throws {
    var rng = SplitMix64(seed: UInt64(seed))
    let trackCount = Int.random(in: 1...6, using: &rng)
    var tracks: [PlaybackTrack] = []
    var cumulativeEnd: Double = 0
    for index in 0..<trackCount {
      let duration = Double.random(in: 0.5...500, using: &rng)
      // Half the time supply the exact cumulative offset explicitly (still monotonic); the
      // rest fall back to it implicitly.
      let startOffset = Bool.random(using: &rng) ? cumulativeEnd : nil
      tracks.append(PlaybackTrack(index: index, startOffset: startOffset, duration: duration))
      cumulativeEnd += duration
    }
    // Sometimes shuffle the input order. Sortedness is proven separately, but a generated
    // timeline should behave identically regardless.
    if Bool.random(using: &rng) {
      tracks.shuffle(using: &rng)
    }
    let timeline = try PlaybackTimeline(tracks: tracks)

    var sampledOffsets: [Double] = []
    for _ in 0..<20 {
      // Sample beyond both edges too, to exercise clamping within the property test.
      sampledOffsets.append(Double.random(in: -50...(timeline.totalDuration + 50), using: &rng))
    }
    sampledOffsets.sort()

    var previousReconstructed: Double?
    for offset in sampledOffsets {
      let (track, local) = timeline.trackAndLocalOffset(atGlobalOffset: offset)
      let reconstructed = try #require(
        timeline.globalOffset(forTrackIndex: track.index, localOffset: local))
      let clampedOffset = min(max(offset, 0), timeline.totalDuration)
      #expect(abs(reconstructed - clampedOffset) < 0.001)
      if let previousReconstructed {
        #expect(reconstructed >= previousReconstructed - 0.001)
      }
      previousReconstructed = reconstructed
    }
  }

  // MARK: - Growth from an observed extent

  private static func singleTrack(declared: Double, index: Int = 0, startOffset: Double? = nil) throws
    -> PlaybackTimeline
  {
    try PlaybackTimeline(tracks: [PlaybackTrack(index: index, startOffset: startOffset, duration: declared)])
  }

  @Test func anObservationPastTheDeclaredDurationGrowsTheTimeline() throws {
    let grown = try Self.singleTrack(declared: 100).grown(toObservedLocalExtent: 130)

    #expect(grown?.totalDuration == 130)
  }

  @Test func aShorterOrBarelyLongerObservationIsRefused() throws {
    let timeline = try Self.singleTrack(declared: 100)

    #expect(timeline.grown(toObservedLocalExtent: 40) == nil)
    #expect(timeline.grown(toObservedLocalExtent: 100) == nil)
    #expect(timeline.grown(toObservedLocalExtent: 100.5) == nil)
    #expect(timeline.grown(toObservedLocalExtent: 101) == nil)
  }

  @Test func anUnusableObservationIsRefused() throws {
    let timeline = try Self.singleTrack(declared: 100)

    #expect(timeline.grown(toObservedLocalExtent: .infinity) == nil)
    #expect(timeline.grown(toObservedLocalExtent: .nan) == nil)
    #expect(timeline.grown(toObservedLocalExtent: 0) == nil)
    #expect(timeline.grown(toObservedLocalExtent: -5) == nil)
  }

  /// Audiobookshelf pins every track of a multi-file book to an explicit `startOffset`, so a grown
  /// track would overlap the next track's fixed start instead of lengthening the book.
  @Test func aMultiTrackTimelineIsNeverGrown() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, startOffset: 0, duration: 100),
      PlaybackTrack(index: 1, startOffset: 100, duration: 50),
    ])

    #expect(timeline.grown(toObservedLocalExtent: 1000) == nil)
  }

  @Test func growthPreservesTheTracksIndexAndStartOffset() throws {
    let grown = try Self.singleTrack(declared: 100, index: 3, startOffset: 7)
      .grown(toObservedLocalExtent: 130)

    #expect(grown?.tracks.count == 1)
    #expect(grown?.tracks.first?.index == 3)
    #expect(grown?.tracks.first?.startOffset == 7)
    #expect(grown?.tracks.first?.duration == 130)
    #expect(grown?.totalDuration == 137)
  }

  /// Repeated observations only ever extend, so a late-arriving smaller one cannot undo a
  /// correction that already landed.
  @Test func repeatedGrowthIsMonotonic() throws {
    let first = try #require(try Self.singleTrack(declared: 100).grown(toObservedLocalExtent: 130))
    let second = try #require(first.grown(toObservedLocalExtent: 160))

    #expect(second.totalDuration == 160)
    #expect(second.grown(toObservedLocalExtent: 130) == nil)
    #expect(second.grown(toObservedLocalExtent: 160) == nil)
  }
}

/// Deterministic, seedable RNG for property tests (SplitMix64). Mirrors the generator in
/// `Tests/SyncEngineTests/LibraryTraversalPlannerTests.swift`, kept local to avoid growing
/// `TestSupport`'s API surface for one small struct. Test-only: production code never needs
/// randomness.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
