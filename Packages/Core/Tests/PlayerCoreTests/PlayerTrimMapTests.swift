import Testing

@testable import PlayerCore

/// The two timelines of a trimmed episode: source time is the file, played time is the
/// composition of what is kept. Every other part of the player stays in source time and crosses
/// to played time only through this map.
@Suite struct PlayerTrimMapTests {
  /// Cuts of 2 s from 10 to 12 and 1 s from 20 to 21: 3 s trimmed in all.
  private static let map = PlayerTrimMap(cuts: [
    PlayerTrimMap.Cut(start: 20, end: 21), PlayerTrimMap.Cut(start: 10, end: 12),
  ])

  // MARK: - Construction

  @Test func cutsAreSortedMergedAndInvalidOnesDropped() {
    let map = PlayerTrimMap(cuts: [
      PlayerTrimMap.Cut(start: 30, end: 31),
      PlayerTrimMap.Cut(start: 5, end: 7),
      PlayerTrimMap.Cut(start: 6, end: 8),
      PlayerTrimMap.Cut(start: 8, end: 9),
      PlayerTrimMap.Cut(start: 12, end: 12),
      PlayerTrimMap.Cut(start: 15, end: 14),
      PlayerTrimMap.Cut(start: .nan, end: 3),
      PlayerTrimMap.Cut(start: -2, end: 1),
    ])

    #expect(
      map.cuts == [
        PlayerTrimMap.Cut(start: 0, end: 1), PlayerTrimMap.Cut(start: 5, end: 9),
        PlayerTrimMap.Cut(start: 30, end: 31),
      ])
    #expect(map.totalTrimmed == 6)
  }

  @Test func edgesAreQuantisedToTheCompositionTimescale() {
    let scale = Double(PlayerTrimMap.timescale)
    let map = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 10 + 0.4 / scale, end: 12 + 0.6 / scale)])

    #expect(map.cuts == [PlayerTrimMap.Cut(start: 10, end: (12 * scale + 1) / scale)])
  }

  @Test func anEmptyMapIsTheIdentity() {
    let map = PlayerTrimMap(cuts: [])

    #expect(map.isEmpty)
    #expect(map.totalTrimmed == 0)
    #expect(map.playedTime(forSource: 42) == 42)
    #expect(map.sourceTime(forPlayed: 42) == 42)
    #expect(map.snapped(42) == 42)
  }

  // MARK: - Mapping

  @Test func sourceToPlayedSubtractsTheCutsBehind() {
    #expect(Self.map.playedTime(forSource: 5) == 5)
    #expect(Self.map.playedTime(forSource: 12) == 10)
    #expect(Self.map.playedTime(forSource: 15) == 13)
    #expect(Self.map.playedTime(forSource: 21) == 18)
    #expect(Self.map.playedTime(forSource: 100) == 97)
  }

  @Test func aSourceTimeInsideACutMapsToTheSplice() {
    #expect(Self.map.playedTime(forSource: 10) == 10)
    #expect(Self.map.playedTime(forSource: 11.5) == 10)
    #expect(Self.map.playedTime(forSource: 20.5) == 18)
  }

  @Test func playedToSourceAddsTheCutsBehind() {
    #expect(Self.map.sourceTime(forPlayed: 5) == 5)
    #expect(Self.map.sourceTime(forPlayed: 13) == 15)
    #expect(Self.map.sourceTime(forPlayed: 97) == 100)
  }

  @Test func aSpliceInstantMapsToTheCutsEnd() {
    #expect(Self.map.sourceTime(forPlayed: 10) == 12)
    #expect(Self.map.sourceTime(forPlayed: 18) == 21)
  }

  @Test func snappingMovesOnlyATimeInsideACutToItsEnd() {
    #expect(Self.map.snapped(9.9) == 9.9)
    #expect(Self.map.snapped(10) == 12)
    #expect(Self.map.snapped(11.999) == 12)
    #expect(Self.map.snapped(12) == 12)
    #expect(Self.map.snapped(20.2) == 21)
    #expect(Self.map.snapped(50) == 50)
  }

  @Test func theRoundTripIsSnapping() {
    var source = 0.0
    while source <= 30 {
      #expect(Self.map.sourceTime(forPlayed: Self.map.playedTime(forSource: source)) == Self.map.snapped(source))
      source += 0.25
    }
  }

  @Test func timesBeforeZeroAreUnchanged() {
    #expect(Self.map.playedTime(forSource: -1) == -1)
    #expect(Self.map.sourceTime(forPlayed: -1) == -1)
  }

  @Test func aCutAtZeroMovesTheStart() {
    let map = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 0, end: 1.5)])

    #expect(map.playedTime(forSource: 0) == 0)
    #expect(map.sourceTime(forPlayed: 0) == 1.5)
    #expect(map.snapped(0) == 1.5)
  }

  // MARK: - Advancing

  @Test func advancingWithinKeptAudioIsPlainAddition() {
    #expect(Self.map.sourceTime(advancing: 1, from: 5) == 6)
  }

  @Test func advancingAcrossOneCutSkipsIt() {
    // Played 9 → 11 crosses the splice at 10, which is source 12.
    #expect(Self.map.sourceTime(advancing: 2, from: 9) == 13)
  }

  @Test func advancingAcrossSeveralCutsSkipsThemAll() {
    // Played 9 → 19 crosses both splices: source 9 + 10 + 3.
    #expect(Self.map.sourceTime(advancing: 10, from: 9) == 22)
  }

  @Test func advancingFromInsideACutStartsAtItsEnd() {
    #expect(Self.map.sourceTime(advancing: 1, from: 11) == 13)
  }

  // MARK: - Time saved

  @Test func trimmedSecondsCountsOnlyCutTimeInTheSpan() {
    #expect(Self.map.trimmedSeconds(from: 0, to: 9) == 0)
    #expect(Self.map.trimmedSeconds(from: 9, to: 13) == 2)
    #expect(Self.map.trimmedSeconds(from: 9, to: 22) == 3)
    #expect(Self.map.trimmedSeconds(from: 11, to: 13) == 1)
    #expect(Self.map.trimmedSeconds(from: 0, to: 100) == Self.map.totalTrimmed)
  }

  @Test func aBackwardSpanTrimsNothing() {
    #expect(Self.map.trimmedSeconds(from: 22, to: 9) == 0)
  }

  // MARK: - Many cuts

  @Test func aMapOfThousandsOfCutsAgreesWithALinearScan() {
    let cuts = (0..<5000).map { index in
      PlayerTrimMap.Cut(start: Double(index) * 1.0 + 0.5, end: Double(index) * 1.0 + 0.7)
    }
    let map = PlayerTrimMap(cuts: cuts)

    #expect(map.cuts.count == 5000)
    for source in stride(from: 0.0, through: 5000, by: 123.37) {
      let behind = map.cuts.reduce(0.0) { sum, cut in
        sum + max(0, min(cut.end, source) - cut.start)
      }
      #expect(abs(map.playedTime(forSource: source) - (source - behind)) < 1e-9)
      #expect(abs(map.trimmedSeconds(from: 0, to: source) - behind) < 1e-9)
    }
  }
}
