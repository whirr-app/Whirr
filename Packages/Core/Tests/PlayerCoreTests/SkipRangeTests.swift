import Testing

@testable import PlayerCore

/// Skipping detected ads: a range is skipped the first time playback enters it from before its
/// start, once per pass, and a deliberate move back into it plays it. A skip forward into it
/// skips it too. A move back before its start begins a new pass, except for a range that was
/// undone.
@Suite struct SkipRangeTests {
  private static let ad = PlayerSkipRange(start: 30, end: 50, endsItem: false)

  // MARK: - Entering a range

  @Test func playingIntoARangeSeeksToItsEndAndReportsIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.globalPosition == 50)
    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
    #expect(reducer.state.isPlaybackIntended)
  }

  @Test func theSeekLandsAndPlaybackContinuesAfterTheRange() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 30.4)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 50)
    #expect(landed.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func seekingBackBeforeASkippedRangeSkipsItAgain() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.seek(toGlobalOffset: 20), now: 32)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 32.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.8), now: 42)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.3), now: 42.5)

    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  /// Skipping forward into a range plays it, but that move must not keep the range from being
  /// skipped once the listener goes back before it and plays through.
  @Test func aRangeSkippedIntoIsSkippedAfterAMoveBackBeforeIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 10), now: 10)
    _ = reducer.handle(.skip(by: 30), now: 11)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 40), now: 11.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 45), now: 16)
    _ = reducer.handle(.seek(toGlobalOffset: 0), now: 17)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 0), now: 17.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.6), now: 46.8)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.1), now: 47.3)

    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  @Test func aChapterMoveBackBeforeASkippedRangeSkipsItAgain() throws {
    let two = PlaybackChapter(id: "2", title: "Two", start: 25, end: 100)
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "1", title: "One", start: 0, end: 25), two,
    ])
    var reducer = Self.playingReducer(ranges: [Self.ad], chapters: chapters)
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.selectChapter(two), now: 32)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25), now: 32.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.6), now: 36.8)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.1), now: 37.3)

    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  /// Moving within or past a consumed range is not a new pass.
  @Test func aMoveThatStaysPastTheRangeStartKeepsItConsumed() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.seek(toGlobalOffset: 35), now: 1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 35), now: 1.2)
    _ = reducer.handle(.seek(toGlobalOffset: 30), now: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 2.2)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.5), now: 2.7)

    #expect(reducer.state.globalPosition == 30.5)
    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func scrubbingIntoARangePlaysIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.seek(toGlobalOffset: 35), now: 5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 35), now: 5.2)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 35.5), now: 5.7)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 35.5)
    #expect(result.effects.contains { if case .seekEngine = $0 { true } else { false } } == false)
  }

  @Test func aStaleTickAfterAScrubIntoARangeDoesNotSkipIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25), now: 25)
    _ = reducer.handle(.seek(toGlobalOffset: 31), now: 25.1)
    // Queued before the seek, and within the landing tolerance, so it is adopted as the landing.
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25.5), now: 25.2)

    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 31), now: 25.4)
    let after = reducer.handle(.positionUpdated(generation: 1, localOffset: 31.5), now: 25.9)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 31.5)
    #expect((landed.progressEvents + after.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  @Test func aTickExactlyAtTheStartSkipsTheRange() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 30)

    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  /// A pre-roll starts where playback does, so there is no position before its start to enter it
  /// from.
  @Test func playingFromTheStartSkipsARangeThatStartsThere() throws {
    let preRoll = PlayerSkipRange(start: 0, end: 20, endsItem: false)
    var reducer = Self.playingReducer(ranges: [preRoll])

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 0.5), now: 0.5)

    #expect(result.effects.contains(.seekEngine(localOffset: 20)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [preRoll])
  }

  @Test func seekingBackToTheStartPlaysARangeThatStartsThere() throws {
    let preRoll = PlayerSkipRange(start: 0, end: 20, endsItem: false)
    var reducer = Self.playingReducer(item: Self.item(), ranges: [])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25), now: 25)
    _ = reducer.handle(
      .setSkipRanges(itemID: "episode-1", episodeID: "ep-1", ranges: [preRoll]), now: 25)
    _ = reducer.handle(.seek(toGlobalOffset: 0), now: 26)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 0), now: 26.2)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 0.5), now: 26.7)

    #expect(reducer.state.globalPosition == 0.5)
    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func resumingInsideARangePlaysIt() throws {
    var reducer = PlayerReducer(now: 0)
    let item = Self.item()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 40, rate: 1), now: 0)
    _ = reducer.handle(.setSkipRanges(itemID: item.id, episodeID: item.episodeID, ranges: [Self.ad]), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 40), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 40.5), now: 0.5)

    #expect(reducer.state.globalPosition == 40.5)
    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  // MARK: - Ranges that arrive after playback began

  /// The ranges come from an actor that can be busy, so the first ticks can beat them. Playback
  /// that began at or before a range's start and ran into it uninterrupted would have skipped it.
  @Test func lateRangesSkipTheRestOfAPreRollPlaybackBeganIn() throws {
    let preRoll = PlayerSkipRange(start: 0, end: 20, endsItem: false)
    var reducer = Self.startedReducer()
    for tick in [0.5, 1.0, 1.5] {
      _ = reducer.handle(.positionUpdated(generation: 1, localOffset: tick), now: tick)
    }

    let result = reducer.handle(Self.setting([preRoll]), now: 1.6)

    #expect(reducer.state.globalPosition == 20)
    #expect(result.effects.contains(.seekEngine(localOffset: 20)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [preRoll])
    #expect(reducer.state.isPlaybackIntended)
  }

  @Test func lateRangesSkipTheRestOfARangePlayedIntoFromTheLoad() throws {
    var reducer = Self.startedReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 31), now: 31)

    let result = reducer.handle(Self.setting([Self.ad]), now: 31.1)

    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  @Test func aLateSkipIsNotRepeatedByTheNextTick() throws {
    let preRoll = PlayerSkipRange(start: 0, end: 20, endsItem: false)
    var reducer = Self.startedReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1), now: 1)
    _ = reducer.handle(Self.setting([preRoll]), now: 1.1)

    let stale = reducer.handle(.positionUpdated(generation: 1, localOffset: 1.5), now: 1.2)
    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 1.3)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 20)
    #expect((stale.progressEvents + landed.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  /// Paused when the ranges land, there is nothing to seek away from yet; the resume skips.
  @Test func lateRangesThatArriveWhilePausedSkipOnTheNextPlayingTick() throws {
    let preRoll = PlayerSkipRange(start: 0, end: 20, endsItem: false)
    var reducer = Self.startedReducer()
    reducer.isSmartRewindEnabled = false
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 3), now: 3)
    _ = reducer.handle(.pause, now: 3)
    let delivered = reducer.handle(Self.setting([preRoll]), now: 4)
    _ = reducer.handle(.play, now: 5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 3.5), now: 5.5)

    #expect(delivered.progressEvents.compactMap(\.skippedRange).isEmpty)
    #expect(result.effects.contains(.seekEngine(localOffset: 20)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [preRoll])
  }

  @Test func lateRangesDoNotSkipARangeTheListenerScrubbedInto() throws {
    var reducer = Self.startedReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1), now: 1)
    _ = reducer.handle(.seek(toGlobalOffset: 35), now: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 35), now: 2.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 36), now: 3.2)

    let delivered = reducer.handle(Self.setting([Self.ad]), now: 3.3)
    let after = reducer.handle(.positionUpdated(generation: 1, localOffset: 36.5), now: 3.7)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 36.5)
    #expect((delivered.progressEvents + after.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  /// As with ranges that were on time: a seek to exactly a range's start asks to hear it.
  @Test func lateRangesDoNotSkipARangeTheListenerSoughtToTheStartOf() throws {
    var reducer = Self.startedReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 60), now: 60)
    _ = reducer.handle(.seek(toGlobalOffset: 30), now: 61)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 61.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 31), now: 62.2)

    let delivered = reducer.handle(Self.setting([Self.ad]), now: 62.3)
    let after = reducer.handle(.positionUpdated(generation: 1, localOffset: 31.5), now: 62.7)

    #expect(reducer.state.globalPosition == 31.5)
    #expect((delivered.progressEvents + after.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  @Test func lateRangesSkipARangePlayedIntoAfterAScrubBeforeIt() throws {
    var reducer = Self.startedReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 60), now: 60)
    _ = reducer.handle(.seek(toGlobalOffset: 28), now: 61)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 28), now: 61.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 31), now: 64.2)

    let result = reducer.handle(Self.setting([Self.ad]), now: 64.3)

    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  @Test func lateRangesDoNotSkipARangeResumedInside() throws {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.item(), initialGlobalPosition: 40, rate: 1), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 40), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 41), now: 1)

    let delivered = reducer.handle(Self.setting([Self.ad]), now: 1.1)
    let after = reducer.handle(.positionUpdated(generation: 1, localOffset: 41.5), now: 1.5)

    #expect(reducer.state.globalPosition == 41.5)
    #expect((delivered.progressEvents + after.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  /// Only the load's first delivery catches up. A recompute that finds an ad where the listener
  /// already is must not pull them out of what they have been hearing.
  @Test func replacedRangesDoNotSkipARangeTheListenerIsIn() throws {
    let preRoll = PlayerSkipRange(start: 0, end: 20, endsItem: false)
    var reducer = Self.playingReducer(ranges: [])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 5), now: 5)

    let delivered = reducer.handle(Self.setting([preRoll]), now: 5.1)
    let after = reducer.handle(.positionUpdated(generation: 1, localOffset: 5.5), now: 5.5)

    #expect(reducer.state.globalPosition == 5.5)
    #expect((delivered.progressEvents + after.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  /// The first delivery can itself be empty, for a file not yet analysed, and land before
  /// playback starts ticking.
  @Test func rangesReplacedBeforeTheFirstTickDoNotSkipARangeTheListenerIsIn() throws {
    let preRoll = PlayerSkipRange(start: 0, end: 20, endsItem: false)
    var reducer = Self.startedReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 3), now: 3)
    _ = reducer.handle(.pause, now: 3)
    _ = reducer.handle(Self.setting([]), now: 4)
    _ = reducer.handle(Self.setting([preRoll]), now: 5)
    reducer.isSmartRewindEnabled = false
    _ = reducer.handle(.play, now: 6)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 3.5), now: 6.5)

    #expect(reducer.state.globalPosition == 3.5)
    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func replacedRangesDoNotSkipAnUndoneRangeTheListenerIsIn() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.undoSkip(Self.ad), now: 31.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 31.7)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 35), now: 36.7)
    let recomputed = PlayerSkipRange(start: 30.5, end: 49.5, endsItem: false)

    let delivered = reducer.handle(Self.setting([recomputed]), now: 36.8)
    let after = reducer.handle(.positionUpdated(generation: 1, localOffset: 35.5), now: 37.2)

    #expect(reducer.state.globalPosition == 35.5)
    #expect((delivered.progressEvents + after.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  // MARK: - Skipping forward into a range

  /// A forward skip says "get me past this", so landing inside an ad carries on to its end.
  /// Otherwise skipping a missed ad just before a kept range lands in that range and plays it.
  @Test func skippingForwardIntoARangeCarriesOnToItsEnd() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25), now: 25)

    let result = reducer.handle(.skip(by: 10), now: 25.1)

    #expect(reducer.state.globalPosition == 50)
    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
    #expect(result.effects.contains(.seekEngine(localOffset: 35)) == false)
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  @Test func skippingForwardIntoARangeCarriesThroughItsJoinedBreak() throws {
    let second = PlayerSkipRange(start: 52, end: 70, endsItem: false)
    var reducer = Self.playingReducer(ranges: [Self.ad, second])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25), now: 25)

    let result = reducer.handle(.skip(by: 10), now: 25.1)

    #expect(reducer.state.globalPosition == 70)
    #expect(
      result.progressEvents.compactMap(\.skippedRange)
        == [PlayerSkipRange(start: 30, end: 70, endsItem: false)])
  }

  @Test func skippingForwardIntoARangeThatEndsTheItemCompletesIt() throws {
    let tail = PlayerSkipRange(start: 90, end: 100, endsItem: true)
    var reducer = Self.playingReducer(ranges: [tail])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 85), now: 85)

    let result = reducer.handle(.skip(by: 10), now: 85.1)

    #expect(reducer.state.phase == .ended)
    #expect(result.progressEvents.last?.skippedRange == tail)
  }

  @Test func theLandingAfterAForwardSkipPlaysOnFromTheRangeEnd() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25), now: 25)
    _ = reducer.handle(.skip(by: 10), now: 25.1)
    // Queued before the seek, from where the skip started.
    let stale = reducer.handle(.positionUpdated(generation: 1, localOffset: 25.2), now: 25.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 25.4)
    let after = reducer.handle(.positionUpdated(generation: 1, localOffset: 50.5), now: 25.9)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 50.5)
    #expect((stale.progressEvents + after.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  @Test func skippingForwardWhilePausedStillCarriesPastTheRange() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 25), now: 25)
    _ = reducer.handle(.pause, now: 25)

    let result = reducer.handle(.skip(by: 10), now: 25.1)

    #expect(reducer.state.globalPosition == 50)
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
    #expect(reducer.state.isPlaybackIntended == false)
  }

  @Test func skippingBackIntoARangePlaysIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.seek(toGlobalOffset: 60), now: 1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 60), now: 1.2)

    let result = reducer.handle(.skip(by: -15), now: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 45), now: 2.2)
    let next = reducer.handle(.positionUpdated(generation: 1, localOffset: 45.5), now: 2.7)

    #expect(result.effects.contains(.seekEngine(localOffset: 45)))
    #expect(reducer.state.globalPosition == 45.5)
    #expect((result.progressEvents + next.progressEvents).compactMap(\.skippedRange).isEmpty)
  }

  @Test func skippingForwardInsideARangeTheListenerScrubbedIntoPlaysOn() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.seek(toGlobalOffset: 32), now: 1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 32), now: 1.2)

    let result = reducer.handle(.skip(by: 10), now: 2)

    #expect(result.effects.contains(.seekEngine(localOffset: 42)))
    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func skippingForwardIntoAnUndoneRangePlaysIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.undoSkip(Self.ad), now: 32)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 32.2)
    _ = reducer.handle(.seek(toGlobalOffset: 20), now: 33)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 33.2)

    let result = reducer.handle(.skip(by: 15), now: 34)

    #expect(result.effects.contains(.seekEngine(localOffset: 35)))
    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func nothingIsSkippedWhilePaused() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)
    _ = reducer.handle(.pause, now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
    #expect(reducer.state.phase == .paused)
  }

  // MARK: - Which ranges apply

  @Test func rangesForAnotherEpisodeAreIgnored() throws {
    var reducer = Self.playingReducer(ranges: [])
    _ = reducer.handle(.setSkipRanges(itemID: "episode-1", episodeID: "ep-2", ranges: [Self.ad]), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func loadingAnotherItemDropsTheRanges() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    let other = Self.item(episodeID: "ep-2")
    _ = reducer.handle(.load(item: other, initialGlobalPosition: 0, rate: 1), now: 1)
    _ = reducer.handle(.ready(generation: 2), now: 1)
    _ = reducer.handle(.play, now: 1)
    _ = reducer.handle(.positionUpdated(generation: 2, localOffset: 29.5), now: 30.5)

    let result = reducer.handle(.positionUpdated(generation: 2, localOffset: 30.2), now: 31.2)

    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
    #expect(reducer.skipRanges.isEmpty)
  }

  @Test func clearingTheRangesStopsSkipping() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.setSkipRanges(itemID: "episode-1", episodeID: "ep-1", ranges: []), now: 1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  /// A recompute can nudge an undone range's edges; that must not make it skippable again.
  @Test func resettingTheSameRangesKeepsAnUndoneRangePlayed() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.undoSkip(Self.ad), now: 31.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 31.7)
    let recomputed = PlayerSkipRange(start: 30.5, end: 49.5, endsItem: false)
    _ = reducer.handle(.setSkipRanges(itemID: "episode-1", episodeID: "ep-1", ranges: [recomputed]), now: 31)
    _ = reducer.handle(.seek(toGlobalOffset: 20), now: 32)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 32.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 42.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.6), now: 43.1)

    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  // MARK: - Back-to-back ranges

  /// One break often holds several creatives detected as separate ranges. Skipping them one by one
  /// lands in each short gap and shows a receipt per range, so they are skipped as one.
  @Test func rangesSeparatedByShortGapsAreSkippedAsOne() throws {
    let second = PlayerSkipRange(start: 52, end: 70, endsItem: false)
    let third = PlayerSkipRange(start: 75, end: 90, endsItem: false)
    var reducer = Self.playingReducer(ranges: [Self.ad, second, third])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(result.effects.contains(.seekEngine(localOffset: 90)))
    #expect(
      result.progressEvents.compactMap(\.skippedRange)
        == [PlayerSkipRange(start: 30, end: 90, endsItem: false)])
    #expect(result.effects.last == .setBoundary(localOffset: nil))
  }

  @Test func aLongerGapBetweenRangesIsHeard() throws {
    let later = PlayerSkipRange(start: 60, end: 70, endsItem: false)
    var reducer = Self.playingReducer(ranges: [Self.ad, later])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
    #expect(result.effects.last == .setBoundary(localOffset: 60))
  }

  @Test func anUndoneRangeEndsTheJoin() throws {
    let second = PlayerSkipRange(start: 52, end: 70, endsItem: false)
    var reducer = Self.playingReducer(ranges: [Self.ad, second])
    // Playing into the second range from the gap skips it alone. Undoing that plays it from then
    // on.
    _ = reducer.handle(.seek(toGlobalOffset: 51), now: 1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 51), now: 1.1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 52.1), now: 1.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 70), now: 1.4)
    _ = reducer.handle(.undoSkip(second), now: 1.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 52), now: 1.7)
    _ = reducer.handle(.seek(toGlobalOffset: 20), now: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 2.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 11.7)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 12.4)

    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
    #expect(result.progressEvents.compactMap(\.skippedRange) == [Self.ad])
  }

  @Test func joiningIntoARangeThatEndsTheItemCompletesIt() throws {
    let tail = PlayerSkipRange(start: 53, end: 100, endsItem: true)
    var reducer = Self.playingReducer(ranges: [Self.ad, tail])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(reducer.state.phase == .ended)
    #expect(
      result.progressEvents.compactMap(\.skippedRange)
        == [PlayerSkipRange(start: 30, end: 100, endsItem: true)])
  }

  @Test func undoingAJoinedSkipPlaysTheWholeBreak() throws {
    let second = PlayerSkipRange(start: 52, end: 70, endsItem: false)
    let joined = PlayerSkipRange(start: 30, end: 70, endsItem: false)
    var reducer = Self.playingReducer(ranges: [Self.ad, second])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 70), now: 31)

    let undo = reducer.handle(.undoSkip(joined), now: 32)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 32.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 51.5), now: 53.7)
    let next = reducer.handle(.positionUpdated(generation: 1, localOffset: 52.3), now: 54.5)

    #expect(undo.effects.contains(.seekEngine(localOffset: 30)))
    #expect(reducer.state.globalPosition == 52.3)
    #expect(next.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  // MARK: - Ranges that end the item

  @Test func aRangeThatEndsTheItemCompletesIt() throws {
    let tail = PlayerSkipRange(start: 90, end: 100, endsItem: true)
    var reducer = Self.playingReducer(ranges: [tail])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 89.5), now: 89.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 90.1), now: 90.1)

    #expect(reducer.state.phase == .ended)
    #expect(reducer.state.globalPosition == 100)
    #expect(result.effects.contains(.pause))
    let ended = try #require(result.progressEvents.last)
    #expect(ended.phase == .ended)
    #expect(ended.endBehavior == .advanceQueue)
    #expect(ended.skippedRange == tail)
  }

  /// `totalDuration` can grow once the engine sees more audio, so the flag decides, not the end's
  /// position.
  @Test func anItemEndingRangeCompletesEvenShortOfTheDeclaredEnd() throws {
    let tail = PlayerSkipRange(start: 60, end: 75, endsItem: true)
    var reducer = Self.playingReducer(ranges: [tail])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 59.5), now: 59.5)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 60.1), now: 60.1)

    #expect(reducer.state.phase == .ended)
  }

  @Test func anItemEndingRangeHonoursASleepTimerAtTheEnd() throws {
    let tail = PlayerSkipRange(start: 90, end: 100, endsItem: true)
    var reducer = Self.playingReducer(ranges: [tail])
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 89.5), now: 89.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 90.1), now: 90.1)

    #expect(reducer.state.phase == .ended)
    #expect(result.progressEvents.contains { $0.phase == .ended && $0.endBehavior == .stop })
  }

  // MARK: - Undo

  @Test func undoReturnsToTheRangeStartAndPlaysIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)

    let undo = reducer.handle(.undoSkip(Self.ad), now: 32)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 32.2)
    let next = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.5), now: 32.7)

    #expect(undo.effects.contains(.seekEngine(localOffset: 30)))
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 30.5)
    #expect(next.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func anUndoneRangePlaysAfterAMoveBackBeforeIt() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.undoSkip(Self.ad), now: 32)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 32.2)
    _ = reducer.handle(.seek(toGlobalOffset: 20), now: 33)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 33.2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.6), now: 42.8)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.1), now: 43.3)

    #expect(reducer.state.globalPosition == 30.1)
    #expect(result.progressEvents.compactMap(\.skippedRange).isEmpty)
  }

  @Test func undoForARangeNotLoadedIsIgnored() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 70), now: 70)

    let result = reducer.handle(.undoSkip(PlayerSkipRange(start: 1, end: 2, endsItem: false)), now: 71)

    #expect(result == .none)
    #expect(reducer.state.globalPosition == 70)
  }

  // MARK: - Smart rewind

  @Test func smartRewindAfterASkipStopsAtTheRangeEnd() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 52), now: 33)
    _ = reducer.handle(.pause, now: 33)

    let result = reducer.handle(.play, now: 33 + 1800)

    #expect(reducer.state.globalPosition == 50)
    #expect(result.effects.contains(.seekEngine(localOffset: 50)))
  }

  @Test func smartRewindIsUnchangedAwayFromAConsumedRange() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    Self.playInto(&reducer)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 31)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 80), now: 61)
    _ = reducer.handle(.pause, now: 61)

    _ = reducer.handle(.play, now: 61 + 1800)

    #expect(reducer.state.globalPosition == 80 - SmartRewind.rewindSeconds(pausedFor: 1800))
  }

  // MARK: - Seek landing

  /// A periodic tick already queued when the skip was issued carries a position inside the range.
  /// For a range shorter than `seekLandingTolerance` it is close enough to the target to pass for
  /// the landing, which would put the playhead back into the ad.
  @Test func aStaleTickInsideAShortRangeIsNotTakenForTheLanding() throws {
    let short = PlayerSkipRange(start: 30, end: 42, endsItem: false)
    var reducer = Self.playingReducer(ranges: [short])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.7), now: 30.7)

    #expect(reducer.state.globalPosition == 42)
    #expect(reducer.state.phase == .seeking)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 42), now: 30.9)

    #expect(reducer.state.globalPosition == 42)
    #expect(reducer.state.phase == .playing)
  }

  // MARK: - Sleep timer and listening time

  @Test func skippingAcrossAnEndOfChapterTimerStillStops() throws {
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "0", title: "One", start: 0, end: 40),
      PlaybackChapter(id: "1", title: "Two", start: 40, end: 100),
    ])
    var reducer = Self.playingReducer(ranges: [Self.ad], chapters: chapters)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(reducer.state.isPlaybackIntended == false)
    #expect(reducer.state.sleepTimer == .off)
    #expect(result.effects.contains(.pause))
  }

  @Test func aSkipCreditsOnlyWallClockListeningTime() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let skip = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)
    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 30.4)
    let next = reducer.handle(.positionUpdated(generation: 1, localOffset: 50.5), now: 30.9)

    // The 0.2 s spent seeking is not credited, as for any seek; the 20 s skipped never is.
    let total = (skip.progressEvents + landed.progressEvents + next.progressEvents)
      .map(\.listenedDelta).reduce(0, +)
    #expect(abs(total - 1.2) < 0.0001)
  }

  // MARK: - Boundary arming

  @Test func theNextRangeStartIsArmedAsABoundary() throws {
    var reducer = PlayerReducer(now: 0)
    let item = Self.item()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1), now: 0)

    let result = reducer.handle(
      .setSkipRanges(itemID: item.id, episodeID: item.episodeID, ranges: [Self.ad]), now: 0)

    #expect(result.effects == [.setBoundary(localOffset: 30)])
  }

  @Test func theBoundaryMovesOnAfterASkip() throws {
    let second = PlayerSkipRange(start: 70, end: 80, endsItem: false)
    var reducer = Self.playingReducer(ranges: [Self.ad, second])
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    #expect(result.effects.last == .setBoundary(localOffset: 70))
  }

  @Test func theBoundaryIsReArmedAfterASeekAndClearedWhenNothingIsAhead() throws {
    var reducer = Self.playingReducer(ranges: [Self.ad])

    let back = reducer.handle(.seek(toGlobalOffset: 10), now: 1)
    let past = reducer.handle(.seek(toGlobalOffset: 60), now: 2)

    #expect(back.effects == [.seekEngine(localOffset: 10), .setBoundary(localOffset: 30)])
    #expect(past.effects == [.seekEngine(localOffset: 60), .setBoundary(localOffset: nil)])
  }

  @Test func aBoundaryInALaterTrackIsArmedWhenThatTrackLoads() throws {
    let item = try PlayerItem(
      id: "episode-1", episodeID: "ep-1",
      timeline: PlaybackTimeline(tracks: [
        PlaybackTrack(index: 0, duration: 50), PlaybackTrack(index: 1, duration: 50),
      ]))
    let late = PlayerSkipRange(start: 70, end: 80, endsItem: false)
    var reducer = Self.playingReducer(item: item, ranges: [late])
    #expect(reducer.armedSkipBoundary == nil)

    let advanced = reducer.handle(.trackFinished(generation: 1), now: 50)

    #expect(advanced.effects.last == .setBoundary(localOffset: 20))
  }

  // MARK: - Helpers

  private static func item(episodeID: String = "ep-1", chapters: PlaybackChapterMap? = nil) -> PlayerItem {
    try! PlayerItem(
      id: "episode-1", episodeID: episodeID,
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]),
      chapters: chapters ?? PlaybackChapterMap(chapters: []))
  }

  private static func playingReducer(
    ranges: [PlayerSkipRange], chapters: PlaybackChapterMap? = nil
  ) -> PlayerReducer {
    playingReducer(item: item(chapters: chapters), ranges: ranges)
  }

  private static func playingReducer(item: PlayerItem, ranges: [PlayerSkipRange]) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1), now: 0)
    _ = reducer.handle(.setSkipRanges(itemID: item.id, episodeID: item.episodeID, ranges: ranges), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  /// Playing from the start, with no ranges delivered yet.
  private static func startedReducer() -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item(), initialGlobalPosition: 0, rate: 1), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  private static func setting(_ ranges: [PlayerSkipRange]) -> PlayerIntent {
    .setSkipRanges(itemID: "episode-1", episodeID: "ep-1", ranges: ranges)
  }

  /// Plays from just before the ad into it, which skips it.
  private static func playInto(_ reducer: inout PlayerReducer) {
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)
  }
}
