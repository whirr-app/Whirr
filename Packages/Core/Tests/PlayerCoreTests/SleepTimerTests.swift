import Testing

@testable import PlayerCore

/// The sleep timer has no system API. It is `PlayerReducer` logic driven entirely by the
/// caller-supplied `now`, the same way listening-delta accrual is. Every test advances time by
/// passing later `now` values into `handle`, never by sleeping.
@Suite struct SleepTimerTests {

  private static func singleTrackItem(id: String = "item-1", duration: Double = 10_000) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    return PlayerItem(id: id, timeline: timeline)
  }

  /// A 10,000s single-track item with one chapter boundary at 1,000s, loaded, ready, and playing
  /// as of `now: 0`. The common starting point most expiry tests build on.
  private static func playingItemWithChapterBoundary(at boundary: Double = 1_000) -> (
    reducer: PlayerReducer, item: PlayerItem
  ) {
    var reducer = PlayerReducer(now: 0)
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(start: 0, end: boundary),
      PlaybackChapter(start: boundary, end: 10_000),
    ])
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 10_000)])
    let item = PlayerItem(id: "item-1", timeline: timeline, chapters: chapters)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return (reducer, item)
  }

  // MARK: - off / durations

  @Test func offLeavesTheTimerOff() {
    var reducer = PlayerReducer(now: 0)

    _ = reducer.handle(.setSleepTimer(.off), now: 0)

    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func fifteenMinutesSetsA900SecondCountdown() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 900))
  }

  @Test func thirtyMinutesSetsA1800SecondCountdown() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.thirtyMinutes), now: 0)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 1_800))
  }

  @Test func fortyFiveMinutesSetsA2700SecondCountdown() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.fortyFiveMinutes), now: 0)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 2_700))
  }

  @Test func sixtyMinutesSetsA3600SecondCountdown() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.sixtyMinutes), now: 0)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 3_600))
  }

  @Test func customDurationSetsTheRequestedCountdown() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 7_500)), now: 0)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 7_500))
  }

  @Test(
    "invalid custom durations leave the timer off",
    arguments: [0.0, -60.0, .infinity, .nan]
  )
  func invalidCustomDurationsLeaveTheTimerOff(seconds: Double) {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: seconds)), now: 0)
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  // MARK: - end of chapter

  @Test func endOfChapterTargetsTheCurrentChaptersEnd() {
    var (reducer, _) = Self.playingItemWithChapterBoundary(at: 1_000)

    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 1_000))
  }

  @Test func endOfChapterFallsBackToTotalDurationOutsideAnyChapter() {
    var reducer = PlayerReducer(now: 0)
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 500)])
    // A single chapter that doesn't cover the whole book, leaving a gap at the end.
    let chapters = PlaybackChapterMap(chapters: [PlaybackChapter(start: 0, end: 100)])
    let item = PlayerItem(id: "item-1", timeline: timeline, chapters: chapters)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 200, rate: 1.0), now: 0)

    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 500))
  }

  @Test func endOfChapterWithNoLoadedItemIsANoOp() {
    var reducer = PlayerReducer(now: 0)

    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func endOfItemTargetsTheEpisodeEndEvenWhenItHasChapters() {
    var (reducer, _) = Self.playingItemWithChapterBoundary(at: 1_000)

    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 0)

    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 10_000))
    let chapterBoundary = reducer.handle(
      .positionUpdated(generation: 1, localOffset: 1_000), now: 1_000)
    #expect(chapterBoundary.effects.contains(.pause) == false)
    #expect(reducer.state.phase == .playing)
  }

  @Test func endOfItemTargetsTheEndOfAChapterlessEpisode() {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 500)])
    let item = PlayerItem(
      id: "rss:1", episodeID: "episode-1", timeline: timeline)
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 100, rate: 1), now: 0)

    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 0)

    #expect(item.chapters.chapters.isEmpty)
    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 500))
  }

  // MARK: - replacement / extension / cancel

  @Test func settingANewDurationReplacesRatherThanStacksOnTheActiveTimer() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    _ = reducer.handle(.setSleepTimer(.thirtyMinutes), now: 100)

    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 1_800))
  }

  @Test func extendingAddsSecondsToTheActiveCountdown() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    _ = reducer.handle(.extendSleepTimer(by: 300), now: 0)

    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 1_200))
  }

  // MARK: - the configured choice

  @Test func aCountdownRemembersWhatItWasSetToWhileItsRemainderFalls() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)
    #expect(reducer.state.sleepTimer.configuredSeconds == 900)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 300), now: 300)

    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))
    #expect(reducer.state.sleepTimer.configuredSeconds == 900)
  }

  @Test func aCustomCountdownRecordsTheSecondsItWasAskedFor() {
    var reducer = PlayerReducer(now: 0)

    _ = reducer.handle(.setSleepTimer(.custom(seconds: 1_500)), now: 0)

    #expect(reducer.state.sleepTimer.configuredSeconds == 1_500)
  }

  @Test func anExtendedCountdownNoLongerClaimsTheChoiceItStartedAs() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    _ = reducer.handle(.extendSleepTimer(by: 300), now: 0)

    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 1_200))
    #expect(reducer.state.sleepTimer.configuredSeconds == nil)
  }

  @Test func aBoundaryTimerAndAClearedTimerRecordNoConfiguredSeconds() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()

    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)
    #expect(reducer.state.sleepTimer.configuredSeconds == nil)

    _ = reducer.handle(.setSleepTimer(.thirtyMinutes), now: 0)
    #expect(reducer.state.sleepTimer.configuredSeconds == 1_800)

    _ = reducer.handle(.setSleepTimer(.off), now: 0)
    #expect(reducer.state.sleepTimer.configuredSeconds == nil)
  }

  @Test func extendingWhenTheTimerIsOffIsANoOp() {
    var reducer = PlayerReducer(now: 0)

    _ = reducer.handle(.extendSleepTimer(by: 300), now: 0)

    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func extendingAnEndOfChapterTimerIsANoOp() {
    var (reducer, _) = Self.playingItemWithChapterBoundary(at: 1_000)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    _ = reducer.handle(.extendSleepTimer(by: 300), now: 0)

    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 1_000))
  }

  @Test func cancelingViaOffStopsAnActiveCountdown() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    _ = reducer.handle(.setSleepTimer(.off), now: 100)

    #expect(reducer.state.sleepTimer.mode == .off)
  }

  // MARK: - countdown expiry

  @Test func countdownExpiryPausesPlaybackAndClearsTheTimer() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    // A single engine tick 900s later. The periodic `positionUpdated` the engine emits during
    // playback (and while backgrounded, since audio continues) is what drives the countdown, so
    // no separate timer machinery is needed.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 900), now: 900)

    #expect(result.effects.contains(.pause))
    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.sleepTimer.mode == .off)
    #expect(result.progressEvents.last?.sleepTimerExpiry == .expired)
  }

  @Test func countdownDecrementsGraduallyAcrossMultipleTicksBeforeExpiring() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    let first = reducer.handle(.positionUpdated(generation: 1, localOffset: 300), now: 300)
    #expect(first.effects.contains(.pause) == false)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))

    let second = reducer.handle(.positionUpdated(generation: 1, localOffset: 600), now: 600)
    #expect(second.effects.contains(.pause) == false)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 300))

    let third = reducer.handle(.positionUpdated(generation: 1, localOffset: 900), now: 900)
    #expect(third.effects.contains(.pause))
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func changingRateDuringAnActiveCountdownDoesNotChangeItsDeadline() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 900)), now: 0)

    let firstTick = reducer.handle(
      .positionUpdated(generation: 1, localOffset: 300), now: 300)
    #expect(firstTick.progressEvents.last?.listenedDelta == 300)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))

    let rateChange = reducer.handle(.setRate(2.0), now: 300)
    #expect(rateChange.effects == [.setRate(2.0)])
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))

    let secondTick = reducer.handle(
      .positionUpdated(generation: 1, localOffset: 900), now: 600)
    #expect(secondTick.effects.contains(.pause) == false)
    #expect(secondTick.progressEvents.last?.listenedDelta == 300)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 300))

    let expiry = reducer.handle(
      .positionUpdated(generation: 1, localOffset: 1_500), now: 900)
    #expect(expiry.effects.contains(.pause))
    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func expiryFiresOnlyOnePauseEvenWithFurtherTicksAfterward() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 900), now: 900)
    #expect(reducer.state.phase == .paused)

    // Nothing resumes playback; further real time passing must not pause again (there is nothing
    // left to pause, and the timer is already cleared).
    let later = reducer.handle(.buffering(generation: 1), now: 5_000)

    #expect(later.effects.contains(.pause) == false)
  }

  /// Set a timer, leave it paused, and the remaining time shown must still be the remaining
  /// time owed. The countdown only spends listening time,
  /// so a timer set while paused spends nothing until playback starts.
  @Test func aTimerSetWhilePausedDoesNotRunUntilPlaybackStarts() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.pause, now: 0)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 600)), now: 0)

    // Ten minutes of real time pass with nothing playing. Whatever reaches the reducer meanwhile
    // must not spend the timer, and must not fire it.
    // (The `.pause` effect here is the engine being re-asserted as paused by an unexpected tick,
    // not the timer firing, which is what must not happen.)
    let whilePaused = reducer.handle(.positionUpdated(generation: 1, localOffset: 0), now: 600)
    #expect(whilePaused.progressEvents.contains { $0.sleepTimerExpiry == .expired } == false)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))
    #expect(reducer.state.sleepTimer.compactRemainingText == "10:00")

    // Starting playback spends nothing retroactively: the full ten minutes is still owed. Resume
    // runs through smart rewind, so `.playing` only arrives once the engine confirms the seek;
    // that in-flight window is not listening time either.
    _ = reducer.handle(.play, now: 600)
    _ = reducer.handle(.ready(generation: 1), now: 600)
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))

    let expiry = reducer.handle(.positionUpdated(generation: 1, localOffset: 600), now: 1_200)
    #expect(expiry.effects.contains(.pause))
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func pausingFreezesTheCountdownAndResumingContinuesFromWhereItStopped() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 300), now: 300)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))

    // Pausing must credit the segment that was actually played, and no more: the phase gate reads
    // the phase in force before `handlePause` installs `.paused`, so this final 100s counts.
    _ = reducer.handle(.pause, now: 400)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 500))

    // An hour paused spends nothing, and neither does the smart-rewind seek that resume issues.
    _ = reducer.handle(.play, now: 4_000)
    _ = reducer.handle(.ready(generation: 1), now: 4_000)
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 500))

    let afterResuming = reducer.handle(
      .positionUpdated(generation: 1, localOffset: 500), now: 4_100)
    #expect(afterResuming.effects.contains(.pause) == false)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 400))
  }

  /// Anything that takes audio out of `.playing` freezes the timer, not just a pause. A phone
  /// call or a stalled stream must not spend a listener's remaining time either.
  @Test func anInterruptionFreezesTheCountdownForItsDuration() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 300), now: 300)

    _ = reducer.handle(.buffering(generation: 1), now: 300)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))

    _ = reducer.handleStallTimeout(now: 900)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 600))
  }

  @Test func cancelingBeforeExpiryPreventsAnyPauseEvenAfterTheOriginalDeadlinePasses() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)
    _ = reducer.handle(.setSleepTimer(.off), now: 100)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 10_000), now: 10_000)

    #expect(result.effects.contains(.pause) == false)
    #expect(reducer.state.phase == .playing)
  }

  // MARK: - end-of-chapter expiry

  @Test func endOfChapterExpiryFiresWhenPositionCrossesTheChapterBoundary() {
    var (reducer, _) = Self.playingItemWithChapterBoundary(at: 1_000)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    let beforeBoundary = reducer.handle(.positionUpdated(generation: 1, localOffset: 999), now: 999)
    #expect(beforeBoundary.effects.contains(.pause) == false)

    let atBoundary = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_000), now: 1_000)

    #expect(atBoundary.effects.contains(.pause))
    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.sleepTimer.mode == .off)
    #expect(atBoundary.progressEvents.last?.sleepTimerExpiry == .expired)
  }

  @Test func changingRateImmediatelyBeforeChapterCrossingStillFiresAtTheBoundary() {
    var (reducer, _) = Self.playingItemWithChapterBoundary(at: 1_000)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    let beforeBoundary = reducer.handle(
      .positionUpdated(generation: 1, localOffset: 999), now: 999)
    #expect(beforeBoundary.effects.contains(.pause) == false)

    let rateChange = reducer.handle(.setRate(2.0), now: 999)
    #expect(rateChange.effects == [.setRate(2.0)])
    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 1_000))

    let crossing = reducer.handle(
      .positionUpdated(generation: 1, localOffset: 1_000), now: 999.5)
    #expect(crossing.effects.contains(.pause))
    #expect(reducer.state.globalPosition == 1_000)
    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  /// The end-of-item callback is not the only way playback ends: position ticks are clamped to the
  /// declared duration, so when it under-runs the real audio (routine for podcast feed metadata)
  /// the timer expires from a tick and `AVPlayerItemDidPlayToEndTime` never arrives. Both paths
  /// must complete the item, or an episode slept through stays part-played and never leaves the
  /// latest-episodes queue.
  @Test func endOfItemExpiryFromAPositionTickCompletesTheItem() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 0)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 10_000), now: 10_000)

    #expect(result.effects.contains(.pause))
    #expect(result.progressEvents.last?.phase == .ended)
    #expect(result.progressEvents.last?.currentTime == 10_000)
    #expect(result.progressEvents.last?.endBehavior == .stop)
    #expect(result.progressEvents.last?.sleepTimerExpiry == .expired)
    #expect(reducer.state.phase == .ended)
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  /// The last chapter ends where the item does, so sleeping through it is the same completion.
  @Test func endOfChapterExpiryOnTheFinalChapterCompletesTheItem() {
    var (reducer, _) = Self.playingItemWithChapterBoundary(at: 1_000)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 2_000), now: 2_000)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 2_000)
    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 10_000))

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 10_000), now: 10_000)

    #expect(result.progressEvents.last?.phase == .ended)
    #expect(result.progressEvents.last?.endBehavior == .stop)
    #expect(reducer.state.phase == .ended)
  }

  /// A chapter boundary short of the item end is still only a pause: the listener has audio left,
  /// so nothing may mark the item finished.
  @Test func endOfChapterExpiryMidItemNeverCompletesTheItem() {
    var (reducer, _) = Self.playingItemWithChapterBoundary(at: 1_000)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_000), now: 1_000)

    #expect(result.progressEvents.contains(where: { $0.phase == .ended }) == false)
    #expect(reducer.state.phase == .paused)
  }

  @Test func itemEndUnderSleepTimerStillEmitsFinishedButForbidsQueueAdvance() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 0)

    let result = reducer.handle(.trackFinished(generation: 1), now: 10_000)

    #expect(result.progressEvents.last?.phase == .ended)
    #expect(result.progressEvents.last?.currentTime == 10_000)
    #expect(result.progressEvents.last?.endBehavior == .stop)
    #expect(result.progressEvents.last?.sleepTimerExpiry == .expired)
    #expect(result.progressEvents.count == 1)
    #expect(reducer.state.phase == .ended)
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  // MARK: - item switch

  @Test func loadingANewItemCancelsTheSleepTimerWithoutFiringItsCompletion() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    let secondItem = Self.singleTrackItem(id: "item-2", duration: 500)
    _ = reducer.handle(.load(item: secondItem, initialGlobalPosition: 0, rate: 1.0), now: 100)
    #expect(reducer.state.sleepTimer.mode == .off)

    // Far past the original 15-minute deadline, on the new item, so it must not retroactively fire.
    _ = reducer.handle(.ready(generation: 2), now: 200)
    let result = reducer.handle(.play, now: 200)
    let laterTick = reducer.handle(.positionUpdated(generation: 2, localOffset: 100), now: 10_000)

    #expect(result.effects.contains(.pause) == false)
    #expect(laterTick.effects.contains(.pause) == false)
    #expect(reducer.state.phase == .playing)
  }

  // MARK: - accessible remaining-time text

  @Test func accessibleTextIsNilWhenOff() {
    #expect(SleepTimerState.off.accessibleRemainingText == nil)
  }

  @Test func accessibleTextFormatsMinutesAndSecondsForACountdown() {
    let state = SleepTimerState(mode: .countdown(remainingSeconds: 900))
    #expect(state.accessibleRemainingText == "15:00 remaining")
  }

  @Test func accessibleTextZeroPadsSecondsUnderTen() {
    let state = SleepTimerState(mode: .countdown(remainingSeconds: 839))
    #expect(state.accessibleRemainingText == "13:59 remaining")
  }

  @Test func accessibleTextDescribesEndOfChapter() {
    let state = SleepTimerState(mode: .endOfChapter(atPosition: 1_000))
    #expect(state.accessibleRemainingText == "Until end of chapter")
  }

  @Test func accessibleTextReflectsCountdownProgressAfterAnEngineTick() {
    var (reducer, _) = Self.playingItemWithChapterBoundary()
    _ = reducer.handle(.setSleepTimer(.fifteenMinutes), now: 0)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 61), now: 61)

    #expect(reducer.state.sleepTimer.accessibleRemainingText == "13:59 remaining")
  }

  // MARK: - compact on-screen text

  @Test func compactTextIsNilWhenOff() {
    #expect(SleepTimerState.off.compactRemainingText == nil)
  }

  @Test func compactTextIsTheBareClock() {
    let state = SleepTimerState(mode: .countdown(remainingSeconds: 900))
    #expect(state.compactRemainingText == "15:00")
  }

  @Test func compactTextZeroPadsSecondsUnderTen() {
    let state = SleepTimerState(mode: .countdown(remainingSeconds: 839))
    #expect(state.compactRemainingText == "13:59")
  }

  @Test func compactTextNamesTheChapterEndWithoutASentence() {
    let state = SleepTimerState(mode: .endOfChapter(atPosition: 1_000))
    #expect(state.compactRemainingText == "Chapter")
  }

  /// The two forms are the same fact at two lengths: the spoken one says what the clock means,
  /// the drawn one is only the clock. Neither may drift into the other's job.
  @Test func theSpokenTextExplainsWhatTheDrawnTextOnlyShows() throws {
    let state = SleepTimerState(mode: .countdown(remainingSeconds: 900))
    let compact = try #require(state.compactRemainingText)
    let spoken = try #require(state.accessibleRemainingText)

    #expect(spoken.hasPrefix(compact))
    #expect(spoken.contains("remaining"))
    #expect(compact.contains("remaining") == false)
  }
}
