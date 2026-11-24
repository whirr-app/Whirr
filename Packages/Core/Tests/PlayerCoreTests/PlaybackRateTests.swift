import TestSupport
import Testing

@testable import PlayerCore

/// Playback rate is player policy (ARCHITECTURE.md §4), not AVFoundation policy. `PlayerReducer`
/// owns clamping/rejection and keeps `state.rate` the single source every `loadEngine` effect
/// reads, including across an automatic track replacement. Relaunch restoration is
/// `PlayerController`'s construction-time read of the injected `PlaybackPreferences`; `.setRate`
/// is active playback state only.
@Suite struct PlaybackRateTests {

  private static func singleTrackItem(duration: Double = 100) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    return PlayerItem(id: "item-1", timeline: timeline)
  }

  private static func twoTrackItem() -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 60),
      PlaybackTrack(index: 1, duration: 40),
    ])
    return PlayerItem(id: "item-1", timeline: timeline)
  }

  @Test func setRateWithinRangeUpdatesStateAndEmitsEngineEffect() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0), now: 0)

    let result = reducer.handle(.setRate(1.5), now: 0)

    #expect(reducer.state.rate == 1.5)
    #expect(result.effects == [.setRate(1.5)])
  }

  @Test func setRateClampsAboveSupportedMaximum() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0), now: 0)

    let result = reducer.handle(.setRate(10.0), now: 0)

    #expect(reducer.state.rate == 3.0)
    #expect(result.effects == [.setRate(3.0)])
  }

  @Test func setRateClampsBelowSupportedMinimum() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0), now: 0)

    let result = reducer.handle(.setRate(0.1), now: 0)

    #expect(reducer.state.rate == 0.5)
    #expect(result.effects == [.setRate(0.5)])
  }

  @Test func setRateRejectsNaNLeavingRateUnchanged() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.25), now: 0)

    let result = reducer.handle(.setRate(.nan), now: 0)

    #expect(reducer.state.rate == 1.25)
    #expect(result.effects.isEmpty)
  }

  @Test func setRateRejectsInfinityLeavingRateUnchanged() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.25), now: 0)

    let result = reducer.handle(.setRate(.infinity), now: 0)

    #expect(reducer.state.rate == 1.25)
    #expect(result.effects.isEmpty)
  }

  @Test func setRateWorksEvenWithNoItemLoaded() {
    var reducer = PlayerReducer(now: 0)

    let result = reducer.handle(.setRate(2.0), now: 0)

    #expect(reducer.state.rate == 2.0)
    #expect(result.effects == [.setRate(2.0)])
  }

  @Test func ratePreservedAcrossAutomaticTrackReplacement() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.twoTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.setRate(1.5), now: 0)

    let result = reducer.handle(.trackFinished(generation: 1), now: 60)

    #expect(
      result.effects.contains(
        .loadEngine(track: item.timeline.tracks[1], localOffset: 0, rate: 1.5, generation: 2)))
    #expect(reducer.state.rate == 1.5)
  }

  // MARK: - PlayerController: construction-time restore only

  @MainActor
  @Test func sendingSetRateDoesNotWriteThroughToPreferences() {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let preferences = FakePlaybackPreferences()
    let controller = PlayerController(engine: engine, clock: clock, preferences: preferences)

    controller.send(.setRate(1.75))

    #expect(controller.state.rate == 1.75)
    #expect(preferences.savedRates.isEmpty)
  }

  @MainActor
  @Test func clampedSetRateChangesPlaybackWithoutWritingToPreferences() {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let preferences = FakePlaybackPreferences()
    let controller = PlayerController(engine: engine, clock: clock, preferences: preferences)

    controller.send(.setRate(9.0))

    #expect(controller.state.rate == 3.0)
    #expect(preferences.savedRates.isEmpty)
  }

  @MainActor
  @Test func relaunchWithSamePreferencesRestoresSavedRate() {
    let preferences = FakePlaybackPreferences(initialRate: 1.75)

    let controller = PlayerController(
      engine: FakeAudioEngine(), clock: ManualClock(now: 0), preferences: preferences)

    #expect(controller.state.rate == 1.75)
    #expect(preferences.savedRates.isEmpty)
  }

  @MainActor
  @Test func noSavedRateKeepsTheDefaultStartingRate() {
    let preferences = FakePlaybackPreferences()

    let controller = PlayerController(
      engine: FakeAudioEngine(), clock: ManualClock(now: 0), preferences: preferences)

    #expect(controller.state.rate == 1.0)
  }
}
