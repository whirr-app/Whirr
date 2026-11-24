import PlayerCore
import Testing

@testable import AppModel

/// The car's Chapters and rate controls, derived from the player.
@Suite struct CarPlayNowPlayingControlsTests {
  private static let presets = [0.75, 1, 1.25, 1.5, 1.75, 2]

  @Test func nothingLoadedOffersNoControls() {
    let controls = CarPlayNowPlayingControls(
      state: .idle, effectiveRate: 1, presets: Self.presets, generation: 1)

    #expect(controls.chapters == nil)
    #expect(controls.rate == nil)
    #expect(controls.nextRate == nil)
  }

  @Test func chapteredBookListsItsChaptersAndMarksTheCurrentOne() throws {
    let controls = try Self.controls(position: 150)
    let list = try #require(controls.chapters)

    #expect(list.generation == 7)
    #expect(list.itemID == "book")
    #expect(list.episodeID == nil)
    #expect(list.rows.map(\.id) == [0, 1, 2])
    #expect(list.rows.map(\.title) == ["Opening", "Chapter 2", "Closing"])
    #expect(list.rows.map(\.isCurrent) == [false, true, false])
    #expect(list.rows.map(\.chapter) == Self.chapters)
  }

  @Test func sharedBoundaryBelongsToTheLaterChapter() throws {
    let list = try #require(try Self.controls(position: 100).chapters)
    #expect(list.rows.map(\.isCurrent) == [false, true, false])
  }

  @Test func controlsDoNotChangeOnATickInsideOneChapter() throws {
    #expect(try Self.controls(position: 150) == Self.controls(position: 151))
    #expect(try Self.controls(position: 150) != Self.controls(position: 250))
  }

  @Test func episodeHasNoChaptersButtonButKeepsItsRate() throws {
    let controls = try Self.controls(position: 150, episodeID: "episode")

    #expect(controls.chapters == nil)
    #expect(controls.rate == 1)
    #expect(controls.nextRate == 1.25)
  }

  @Test func unchapteredBookHasNoChaptersButton() throws {
    #expect(try Self.controls(position: 150, chapters: []).chapters == nil)
  }

  @Test func positionBetweenChaptersHasNoChaptersButton() throws {
    let gapped = [
      PlaybackChapter(title: "One", start: 0, end: 100), PlaybackChapter(title: "Two", start: 200, end: 300),
    ]
    #expect(try Self.controls(position: 150, chapters: gapped).chapters == nil)
  }

  @Test(arguments: [
    (1.0, 1.25), (2.0, 0.75), (1.1, 1.25), (0.5, 0.75), (3.0, 0.75),
  ])
  func rateCyclesUpThroughThePresetsAndWraps(rate: Double, next: Double) {
    #expect(CarPlayNowPlayingControls.rate(after: rate, in: Self.presets) == next)
  }

  @Test func rateCycleIgnoresPresetOrder() {
    #expect(CarPlayNowPlayingControls.rate(after: 1, in: [2, 1, 1.5]) == 1.5)
  }

  @Test func rateHasNothingToCycleToWithoutAnotherPreset() {
    #expect(CarPlayNowPlayingControls.rate(after: 1, in: []) == nil)
    #expect(CarPlayNowPlayingControls.rate(after: 1, in: [1]) == nil)
    #expect(CarPlayNowPlayingControls.rate(after: 1.5, in: [1]) == 1)
  }

  private static let chapters = [
    PlaybackChapter(title: "Opening", start: 0, end: 100),
    PlaybackChapter(title: "  ", start: 100, end: 200),
    PlaybackChapter(title: "Closing", start: 200, end: 300),
  ]

  private static func controls(
    position: Double, episodeID: String? = nil, chapters: [PlaybackChapter] = chapters
  ) throws -> CarPlayNowPlayingControls {
    let item = PlayerItem(
      id: "book", episodeID: episodeID,
      timeline: try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 300)]),
      chapters: PlaybackChapterMap(chapters: chapters))
    let state = PlayerState(
      phase: .playing, item: item, currentTrackIndex: 0, globalPosition: position, rate: 1)
    return CarPlayNowPlayingControls(state: state, effectiveRate: 1, presets: presets, generation: 7)
  }
}
