import Testing

@testable import AdSkip

/// The end of a kept range moves to the next pause, over words, when one starts within 5 s: an ad's
/// closing call to action names the show, so it rarely recurs and the matched run stops short.
@Suite struct PlaybackEdgesTests {
  private static let kept = KeptRange(start: 30, end: 50, meanAdProbability: 0.4, endsItem: false)

  @Test func theEndMovesToAPauseWithinFiveSeconds() {
    let extended = PlaybackEdges.extendingEnd(
      of: Self.kept,
      silences: [Silence(start: 20, end: 21), Silence(start: 54, end: 54.6), Silence(start: 54.9, end: 56)])
    #expect(extended == KeptRange(start: 30, end: 54, meanAdProbability: 0.4, endsItem: false))
  }

  @Test func aPauseFurtherAwayLeavesTheEnd() {
    let extended = PlaybackEdges.extendingEnd(of: Self.kept, silences: [Silence(start: 55.1, end: 56)])
    #expect(extended == Self.kept)
  }

  @Test func aPauseAlreadyAtTheEndLeavesIt() {
    // The repetition stage has already extended this edge over wordless audio to the pause.
    let extended = PlaybackEdges.extendingEnd(of: Self.kept, silences: [Silence(start: 49.7, end: 50.4)])
    #expect(extended == Self.kept)
  }

  @Test func withoutPausesTheEndStays() {
    #expect(PlaybackEdges.extendingEnd(of: Self.kept, silences: []) == Self.kept)
  }

  @Test func anItemEndingRangeStaysItemEnding() {
    let tail = KeptRange(start: 30, end: 50, meanAdProbability: 0.4, endsItem: true)
    let extended = PlaybackEdges.extendingEnd(of: tail, silences: [Silence(start: 52, end: 53)])
    #expect(extended == KeptRange(start: 30, end: 52, meanAdProbability: 0.4, endsItem: true))
  }

  @Test func aStartWithinFiveSecondsOfTheFileStartMovesToZero() {
    // A pre-roll whose opening words were transcribed differently in every copy: the store
    // matches only from the first words the copies share.
    #expect(PlaybackEdges.start(atItemStartFor: 4.14) == 0)
    #expect(PlaybackEdges.start(atItemStartFor: 5) == 0)
  }

  @Test func aLaterStartStays() {
    #expect(PlaybackEdges.start(atItemStartFor: 5.01) == 5.01)
    #expect(PlaybackEdges.start(atItemStartFor: 30) == 30)
  }

  @Test func aStartAtZeroStays() {
    #expect(PlaybackEdges.start(atItemStartFor: 0) == 0)
  }

  // MARK: - Silence bridging

  /// The served range runs from the start of the silence before it and to the end of the silence
  /// after it: a stitch gap holds no programme, and skipping it hides the output route's latency.
  @Test func aStartAtTheEndOfASilenceMovesToItsStart() {
    let bridged = PlaybackEdges.bridgingSilences(
      [TimeSpan(start: 30, end: 50)], silences: [Silence(start: 27.5, end: 30)])
    #expect(bridged == [TimeSpan(start: 27.5, end: 50)])
  }

  @Test func aStartInsideASilenceMovesToItsStart() {
    let bridged = PlaybackEdges.bridgingSilences(
      [TimeSpan(start: 30, end: 50)], silences: [Silence(start: 29.2, end: 30.4)])
    #expect(bridged == [TimeSpan(start: 29.2, end: 50)])
  }

  @Test func aStartShortlyAfterASilenceMovesToItsStart() {
    let bridged = PlaybackEdges.bridgingSilences(
      [TimeSpan(start: 30, end: 50)], silences: [Silence(start: 28, end: 29.96)])
    #expect(bridged == [TimeSpan(start: 28, end: 50)])
  }

  @Test func aSilenceFurtherBeforeTheStartLeavesIt() {
    let bridged = PlaybackEdges.bridgingSilences(
      [TimeSpan(start: 30, end: 50)], silences: [Silence(start: 28, end: 29.9)])
    #expect(bridged == [TimeSpan(start: 30, end: 50)])
  }

  @Test func anEndInsideOrJustBeforeASilenceMovesToItsEnd() {
    #expect(
      PlaybackEdges.bridgingSilences([TimeSpan(start: 30, end: 50)], silences: [Silence(start: 44, end: 51.5)])
        == [TimeSpan(start: 30, end: 51.5)])
    #expect(
      PlaybackEdges.bridgingSilences([TimeSpan(start: 30, end: 50)], silences: [Silence(start: 50.04, end: 52)])
        == [TimeSpan(start: 30, end: 52)])
    #expect(
      PlaybackEdges.bridgingSilences([TimeSpan(start: 30, end: 50)], silences: [Silence(start: 50.1, end: 52)])
        == [TimeSpan(start: 30, end: 50)])
  }

  @Test func theNearestSilenceOnEachSideWins() {
    let bridged = PlaybackEdges.bridgingSilences(
      [TimeSpan(start: 30, end: 50)],
      silences: [
        Silence(start: 27, end: 29.52), Silence(start: 29.6, end: 29.97), Silence(start: 50.02, end: 50.3),
        Silence(start: 50.32, end: 53),
      ])
    #expect(bridged == [TimeSpan(start: 29.6, end: 50.3)])
  }

  @Test func neighboursSharingOneSilenceMeetWithoutOverlapping() {
    let bridged = PlaybackEdges.bridgingSilences(
      [TimeSpan(start: 30, end: 50), TimeSpan(start: 51.2, end: 70)], silences: [Silence(start: 50, end: 51.2)])
    #expect(bridged == [TimeSpan(start: 30, end: 51.2), TimeSpan(start: 51.2, end: 70)])
  }

  @Test func overlappingRangesKeepTheirUnion() {
    // Two library matches over one break: the first holds the second's start and runs past its end.
    #expect(
      PlaybackEdges.disjoint([TimeSpan(start: 172.7, end: 336.1), TimeSpan(start: 173.8, end: 236.4)])
        == [TimeSpan(start: 172.7, end: 336.1), TimeSpan(start: 336.1, end: 336.1)])
    #expect(
      PlaybackEdges.disjoint([TimeSpan(start: 30, end: 50), TimeSpan(start: 40, end: 70), TimeSpan(start: 80, end: 90)])
        == [TimeSpan(start: 30, end: 50), TimeSpan(start: 50, end: 70), TimeSpan(start: 80, end: 90)])
    #expect(PlaybackEdges.disjoint([]).isEmpty)
  }

  @Test func silencesInsideTheRangeAndFarAwayChangeNothing() {
    let ranges = [TimeSpan(start: 30, end: 50)]
    #expect(
      PlaybackEdges.bridgingSilences(ranges, silences: [Silence(start: 35, end: 36), Silence(start: 70, end: 72)])
        == ranges)
    #expect(PlaybackEdges.bridgingSilences(ranges, silences: []) == ranges)
    #expect(PlaybackEdges.bridgingSilences([], silences: [Silence(start: 1, end: 2)]).isEmpty)
  }

  // MARK: - Break fills

  private static func spans(gap: Double) -> [TimeSpan] {
    [TimeSpan(start: 30, end: 50), TimeSpan(start: 50 + gap, end: 70 + gap)]
  }

  @Test func aGapTheJoinAlreadyCoversIsNotFilled() {
    #expect(PlaybackEdges.breakFills(between: Self.spans(gap: 9), refusing: { _ in false }).isEmpty)
  }

  @Test func aGapPastTheJoinUpToTheCapIsFilled() {
    for gap in [10.0, PlaybackEdges.breakFillSeconds] {
      #expect(
        PlaybackEdges.breakFills(between: Self.spans(gap: gap), refusing: { _ in false })
          == [TimeSpan(start: 50, end: 50 + gap)])
    }
  }

  @Test func aGapPastTheCapIsNotFilled() {
    let spans = Self.spans(gap: PlaybackEdges.breakFillSeconds + 1)
    #expect(PlaybackEdges.breakFills(between: spans, refusing: { _ in false }).isEmpty)
  }

  @Test func aRefusedGapIsNotFilledAndTheOthersAre() {
    let spans = [
      TimeSpan(start: 0, end: 20), TimeSpan(start: 40, end: 60), TimeSpan(start: 90, end: 100),
    ]
    let fills = PlaybackEdges.breakFills(between: spans, refusing: { $0.start == 20 })
    #expect(fills == [TimeSpan(start: 60, end: 90)])
    #expect(PlaybackEdges.breakFills(between: [], refusing: { _ in false }).isEmpty)
    #expect(PlaybackEdges.breakFills(between: [spans[0]], refusing: { _ in false }).isEmpty)
  }
}
