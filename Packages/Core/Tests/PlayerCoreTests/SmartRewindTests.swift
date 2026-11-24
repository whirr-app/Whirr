import Foundation
import TestSupport
import Testing

@testable import PlayerCore

@Suite struct SmartRewindTests {

  // MARK: - Curve

  @Test func curveHasTheConfiguredThresholdAndPositiveValuesAboveIt() {
    #expect(SmartRewind.rewindSeconds(pausedFor: -1) == 0)
    #expect(SmartRewind.rewindSeconds(pausedFor: 14.999) == 0)
    #expect(SmartRewind.rewindSeconds(pausedFor: 15) == 0)
    #expect(SmartRewind.rewindSeconds(pausedFor: 16) > 0)
  }

  @Test func curveMatchesNamedAnchorValues() {
    let anchors: [(pausedFor: Double, expected: Double)] = [
      (15, 0),
      (30, 1.45),
      (60, 2.9),
      (5 * 60, 6.27),
      (30 * 60, 10.0),
      (8 * 60 * 60, 10.0),
      (24 * 60 * 60, 10.0),
    ]

    for anchor in anchors {
      #expect(
        abs(SmartRewind.rewindSeconds(pausedFor: anchor.pausedFor) - anchor.expected) < 0.1,
        "pause \(anchor.pausedFor) seconds")
    }
  }

  @Test func curveIsMonotonicAcrossAWidePauseSweep() {
    let pauses: [Double] = [0, 15, 16, 30, 60, 300, 1_800, 28_800, 86_400, 7 * 86_400]
    let rewinds = pauses.map { SmartRewind.rewindSeconds(pausedFor: $0) }

    #expect(zip(rewinds, rewinds.dropFirst()).allSatisfy { $0.1 >= $0.0 })
  }

  @Test func curveNeverExceedsItsCap() {
    #expect(SmartRewind.rewindSeconds(pausedFor: 7 * 24 * 60 * 60) == SmartRewind.maximumRewindSeconds)
  }

  /// The shape Rhys asked for: half an hour away is as much rewind as any longer break earns.
  @Test func curveIsAtItsCapFromHalfAnHourOnward() {
    #expect(SmartRewind.rewindSeconds(pausedFor: 30 * 60) == SmartRewind.maximumRewindSeconds)
    #expect(SmartRewind.rewindSeconds(pausedFor: 60 * 60) == SmartRewind.maximumRewindSeconds)
    #expect(SmartRewind.rewindSeconds(pausedFor: 8 * 60 * 60) == SmartRewind.maximumRewindSeconds)
    #expect(SmartRewind.rewindSeconds(pausedFor: 10 * 60) < SmartRewind.maximumRewindSeconds)
  }

  @Test func curveRejectsNonFiniteAndNegativeInput() {
    #expect(SmartRewind.rewindSeconds(pausedFor: Double.nan) == 0)
    #expect(SmartRewind.rewindSeconds(pausedFor: Double.infinity) == 0)
    #expect(SmartRewind.rewindSeconds(pausedFor: -Double.infinity) == 0)
    #expect(SmartRewind.rewindSeconds(pausedFor: -30) == 0)
  }

  // MARK: - Resume behavior

  @Test func pauseStampsOnlyWhenPlaybackWasIntendedAndActuallyPauses() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)

    let noOp = reducer.handle(.pause, now: 10)

    #expect(noOp.effects == [.pause])
    #expect(noOp.progressEvents.isEmpty)
    #expect(reducer.state.pausedAt == nil)

    _ = reducer.handle(.ready(generation: 1), now: 10)
    _ = reducer.handle(.play, now: 10)
    _ = reducer.handle(.pause, now: 13)

    #expect(reducer.state.pausedAt == 13)
  }

  @Test func aShortPauseResumesWithoutASeek() {
    var reducer = Self.pausedReducer(position: 100)

    let result = reducer.handle(.play, now: 5)

    #expect(result.effects == [.play])
    #expect(result.effects.contains { if case .seekEngine = $0 { true } else { false } } == false)
    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 100)
    #expect(reducer.state.pausedAt == nil)
  }

  @Test func aTenMinutePauseSeeksBackByTheCurveAmountThenPlays() {
    var reducer = Self.pausedReducer(position: 100)
    let rewind = SmartRewind.rewindSeconds(pausedFor: 10 * 60)
    let expectedPosition = 100 - rewind

    let result = reducer.handle(.play, now: 10 * 60)

    #expect(result.effects == [.seekEngine(localOffset: expectedPosition), .play])
    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.isPlaybackIntended)
    #expect(abs(reducer.state.globalPosition - expectedPosition) < 0.000_001)
    #expect(result.progressEvents.map(\.phase) == [.seeking])
    #expect(result.progressEvents.map(\.listenedDelta) == [0])
  }

  @Test func resumeClearsThePauseTimestampAndASecondPlayCannotSeekAgain() {
    var reducer = Self.pausedReducer(position: 100)
    let first = reducer.handle(.play, now: 10 * 60)
    let positionAfterFirstResume = reducer.state.globalPosition

    #expect(first.effects.contains { if case .seekEngine = $0 { true } else { false } })
    #expect(reducer.state.pausedAt == nil)

    let second = reducer.handle(.play, now: 10 * 60 + 1)

    #expect(second.effects == [.play])
    #expect(second.effects.contains { if case .seekEngine = $0 { true } else { false } } == false)
    #expect(reducer.state.globalPosition == positionAfterFirstResume)

    // The re-asserted `.play` from resolution is an effect; it does not re-enter `handlePlay`.
    let resolved = reducer.handle(.ready(generation: 1), now: 10 * 60 + 2)
    #expect(resolved.effects == [.play])
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.pausedAt == nil)
  }

  @Test func rewindClampsAtTheStartOfTheTimeline() {
    var reducer = Self.pausedReducer(position: 5)

    let result = reducer.handle(.play, now: 10 * 60)

    #expect(result.effects == [.seekEngine(localOffset: 0), .play])
    #expect(reducer.state.globalPosition == 0)
  }

  @Test func rewindAcrossATrackBoundaryLoadsThePreviousTrackWithANewGeneration() {
    var reducer = Self.pausedReducer(item: Self.twoTrackItem(), position: 61)
    let rewind = SmartRewind.rewindSeconds(pausedFor: 10 * 60)
    let expectedPosition = 61 - rewind

    let result = reducer.handle(.play, now: 10 * 60)

    #expect(
      result.effects == [
        .loadEngine(
          track: Self.twoTrackItem().timeline.tracks[0], localOffset: expectedPosition, rate: 1.0,
          generation: 2),
        .play,
      ])
    #expect(result.effects.contains { if case .seekEngine = $0 { true } else { false } } == false)
    #expect(reducer.state.currentTrackIndex == 0)
    #expect(reducer.state.globalPosition == expectedPosition)
    #expect(reducer.state.phase == .seeking)
  }

  @Test func disabledSmartRewindPreservesTheExistingPlayBehavior() {
    var reducer = Self.pausedReducer(position: 100)
    reducer.isSmartRewindEnabled = false

    let result = reducer.handle(.play, now: 10 * 60)

    #expect(result.effects == [.play])
    #expect(result.progressEvents.map(\.phase) == [.playing])
    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 100)
    #expect(reducer.state.pausedAt == nil)
  }

  @Test func aFreshLoadThenPlayNeverRewindsThePreviousItemsPause() {
    var reducer = Self.pausedReducer(item: Self.singleTrackItem(id: "item-a"), position: 100)
    let freshItem = Self.singleTrackItem(id: "item-b")
    let freshStart = 7 * 24 * 60 * 60.0

    _ = reducer.handle(.load(item: freshItem, initialGlobalPosition: 0, rate: 1.0), now: freshStart)
    #expect(reducer.state.pausedAt == nil)

    let play = reducer.handle(.play, now: freshStart)

    #expect(play.effects.isEmpty)
    #expect(play.progressEvents.isEmpty)
    #expect(reducer.state.phase == .preparing)
    #expect(reducer.state.globalPosition == 0)

    // The current phase machine promotes an intended fresh start to `.playing` on resolution.
    let ready = reducer.handle(.ready(generation: 2), now: freshStart)
    #expect(ready.effects == [.play])
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 0)
    #expect(ready.effects.contains { if case .seekEngine = $0 { true } else { false } } == false)
  }

  @Test func stopClearsThePauseTimestamp() {
    var reducer = Self.pausedReducer(position: 100)

    _ = reducer.handle(.stop, now: 1)

    #expect(reducer.state == .idle)
    #expect(reducer.state.pausedAt == nil)
  }

  @Test func resumeCreditsNoListeningTimeForThePausedOrRewoundInterval() {
    var reducer = Self.pausedReducer(position: 100)

    let result = reducer.handle(.play, now: 10 * 60)

    #expect(result.progressEvents.count == 1)
    #expect(result.progressEvents[0].listenedDelta == 0)
    #expect(result.progressEvents[0].phase == .seeking)
  }

  @Test func toggleFromPausedUsesTheSameSmartRewindPathAsPlay() {
    var reducer = Self.pausedReducer(position: 100)
    let rewind = SmartRewind.rewindSeconds(pausedFor: 10 * 60)

    let result = reducer.handle(.toggle, now: 10 * 60)

    #expect(result.effects == [.seekEngine(localOffset: 100 - rewind), .play])
    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.isPlaybackIntended)
  }

  @Test func sleepTimerExpiryStampsThePauseForSmartRewind() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)

    let expiry = reducer.handle(.positionUpdated(generation: 1, localOffset: 60), now: 60)

    #expect(expiry.effects.contains(.pause))
    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.pausedAt == 60)
  }

  // MARK: - Controller preference refresh

  @MainActor
  @Test func controllerReadsTheSmartRewindPreferenceOnTheNextPlay() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let preferences = FakePlaybackPreferences()
    let controller = PlayerController(engine: engine, clock: clock, preferences: preferences)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 100, rate: 1.0))
    _ = await events.next()
    engine.emit(.ready(generation: 1))
    _ = await events.next()
    controller.send(.play)
    _ = await events.next()

    clock.advance(by: 1)
    controller.send(.pause)
    _ = await events.next()

    preferences.smartRewindEnabled = false
    clock.advance(by: 10 * 60)
    controller.send(.play)

    #expect(engine.seekCalls.isEmpty)
    #expect(controller.state.phase == .playing)
    #expect(controller.state.globalPosition == 100)
  }

  // MARK: - Chapter floor

  @Test func resumeTargetFloorsAtTheChapterStart() {
    let target = SmartRewind.resumeTarget(from: 100, pausedFor: 30 * 60, chapterStart: 95)

    #expect(target == 95)
  }

  @Test func resumeTargetIgnoresAChapterStartTheCurveCannotReach() {
    let rewind = SmartRewind.rewindSeconds(pausedFor: 30 * 60)
    let target = SmartRewind.resumeTarget(from: 100, pausedFor: 30 * 60, chapterStart: 50)

    #expect(target == 100 - rewind)
  }

  @Test func resumeTargetAtAChapterStartIsThePositionItself() {
    #expect(SmartRewind.resumeTarget(from: 500, pausedFor: 30 * 60, chapterStart: 500) == 500)
    #expect(SmartRewind.resumeTarget(from: 500, pausedFor: 7 * 24 * 60 * 60, chapterStart: 500) == 500)
  }

  @Test func resumeTargetWithoutAChapterStartUsesTheFullCurve() {
    let rewind = SmartRewind.rewindSeconds(pausedFor: 10 * 60)

    #expect(SmartRewind.resumeTarget(from: 100, pausedFor: 10 * 60, chapterStart: nil) == 100 - rewind)
  }

  @Test func resumeTargetNeverMovesForward() {
    let sweep: [(position: Double, pause: Double, chapterStart: Double?)] = [
      (100, 0, 95), (100, 5, nil), (100, 30 * 60, 120), (100, 30 * 60, Double.nan),
      (100, Double.nan, 95), (100, 30 * 60, Double.infinity),
    ]

    for (position, pause, chapterStart) in sweep {
      #expect(
        SmartRewind.resumeTarget(from: position, pausedFor: pause, chapterStart: chapterStart)
          <= position,
        "position \(position), pause \(pause), chapter start \(String(describing: chapterStart))")
    }
  }

  /// A chapter start is the cleanest landmark in a book: there is no thread to pick back up, and
  /// crossing the boundary backwards flips the chapter title and refills the chapter scrubber.
  @Test func resumeAtAChapterStartPlaysWithoutSeeking() {
    var reducer = Self.pausedReducer(item: Self.chapteredItem(), position: 500)

    let result = reducer.handle(.play, now: 30 * 60)

    #expect(result.effects == [.play])
    #expect(result.progressEvents.map(\.phase) == [.playing])
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 500)
    #expect(reducer.state.pausedAt == nil)
  }

  @Test func resumeJustInsideAChapterRewindsOnlyToItsStart() {
    var reducer = Self.pausedReducer(item: Self.chapteredItem(), position: 503)

    let result = reducer.handle(.play, now: 30 * 60)

    #expect(result.effects == [.seekEngine(localOffset: 500), .play])
    #expect(reducer.state.globalPosition == 500)
    #expect(reducer.state.phase == .seeking)
  }

  @Test func resumeWellInsideAChapterStillUsesTheFullCurve() {
    var reducer = Self.pausedReducer(item: Self.chapteredItem(), position: 600)
    let rewind = SmartRewind.rewindSeconds(pausedFor: 30 * 60)

    let result = reducer.handle(.play, now: 30 * 60)

    #expect(result.effects == [.seekEngine(localOffset: 600 - rewind), .play])
    #expect(reducer.state.globalPosition == 600 - rewind)
  }

  /// A gap between chapters is not a landmark, so there is nothing to floor the rewind at.
  @Test func resumeInAChapterGapUsesTheFullCurve() {
    var reducer = Self.pausedReducer(item: Self.chapteredItem(), position: 1_200)
    let rewind = SmartRewind.rewindSeconds(pausedFor: 30 * 60)

    let result = reducer.handle(.play, now: 30 * 60)

    #expect(result.effects == [.seekEngine(localOffset: 1_200 - rewind), .play])
    #expect(reducer.state.globalPosition == 1_200 - rewind)
  }

  @Test func disabledSmartRewindDoesNotSeekToAChapterStartEither() {
    var reducer = Self.pausedReducer(item: Self.chapteredItem(), position: 503)
    reducer.isSmartRewindEnabled = false

    let result = reducer.handle(.play, now: 30 * 60)

    #expect(result.effects == [.play])
    #expect(reducer.state.globalPosition == 503)
  }

  // MARK: - Fixtures

  private static func singleTrackItem(id: String = "item-1", duration: Double = 10_000) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    return PlayerItem(id: id, timeline: timeline)
  }

  /// Two adjacent chapters, a gap, then a third. Enough to exercise the floor, the shared
  /// boundary, and the uncovered case.
  private static func chapteredItem() -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 10_000)])
    return PlayerItem(
      id: "item-1",
      timeline: timeline,
      chapters: PlaybackChapterMap(chapters: [
        PlaybackChapter(title: "One", start: 0, end: 500),
        PlaybackChapter(title: "Two", start: 500, end: 1_000),
        PlaybackChapter(title: "Three", start: 1_500, end: 2_000),
      ]))
  }

  private static func twoTrackItem() -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 60),
      PlaybackTrack(index: 1, duration: 100),
    ])
    return PlayerItem(id: "item-1", timeline: timeline)
  }

  private static func playingReducer() -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  private static func pausedReducer(
    item: PlayerItem, position: Double
  ) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: position, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.pause, now: 0)
    return reducer
  }

  private static func pausedReducer(position: Double) -> PlayerReducer {
    pausedReducer(item: Self.singleTrackItem(), position: position)
  }
}
