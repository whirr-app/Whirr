import ABSApi
import AppModel
import DesignSystem
import MediaPlayer
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing
import UIKit

@testable import Whirr

extension NowPlayingMetadataTests {

  // MARK: - Updates only at semantic boundaries

  @Test("repeated position-only ticks within the same chapter do not republish")
  func positionOnlyTicksDoNotRepublish() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let clock = MutableClock()
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: itemInfoProvider, now: clock.now)
    let writesAfterConstruction = sink.writeCount

    // Simulate three plain position ticks: state's position moves but phase/rate/chapter don't.
    for time in [11.0, 12.0, 13.0] {
      clock.advance(by: 1)
      player.state.globalPosition = time
      player.emit(progressEvent(phase: .playing, currentTime: time))
    }
    _ = await awaitQuiescence(
      "Now Playing remains unchanged for position-only ticks",
      of: { "writes=\(sink.writeCount)" })

    #expect(sink.writeCount == writesAfterConstruction)
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Elapsed-time drift (Trim Silences)

  private func elapsed(_ sink: FakeNowPlayingInfoSink) -> Double? {
    sink.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
  }

  @Test("a position running ahead of the system's extrapolation republishes once, then rebases")
  func driftBeyondThresholdRepublishesElapsed() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let clock = MutableClock()
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      now: clock.now)
    let writesAfterConstruction = sink.writeCount

    // One second of wall time, but 2.5 s of audio: a 1.5 s pause was cut.
    clock.advance(by: 1)
    player.state.globalPosition = 12.5
    player.emit(progressEvent(phase: .playing, currentTime: 12.5))
    await waitUntil { sink.writeCount == writesAfterConstruction + 1 }
    #expect(elapsed(sink) == 12.5)

    // The next extrapolation starts from the republished value, so 1:1 playback is quiet again.
    clock.advance(by: 1)
    player.state.globalPosition = 13.5
    player.emit(progressEvent(phase: .playing, currentTime: 13.5, sequence: 2))
    _ = await awaitQuiescence(
      "Now Playing stays quiet once rebased", of: { "writes=\(sink.writeCount)" })
    #expect(sink.writeCount == writesAfterConstruction + 1)
    withExtendedLifetime(adapter) {}
  }

  @Test("a position keeping pace with the clock never republishes for drift")
  func positionKeepingPaceDoesNotRepublish() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let clock = MutableClock()
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      now: clock.now)
    let writesAfterConstruction = sink.writeCount

    for second in 1...20 {
      clock.advance(by: 1)
      player.state.globalPosition = 10 + Double(second)
      player.emit(progressEvent(phase: .playing, currentTime: 10 + Double(second), sequence: second))
    }
    _ = await awaitQuiescence(
      "Now Playing stays quiet at 1:1", of: { "writes=\(sink.writeCount)" })

    #expect(sink.writeCount == writesAfterConstruction)
    withExtendedLifetime(adapter) {}
  }

  @Test("drift under the threshold does not republish")
  func driftUnderThresholdDoesNotRepublish() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let clock = MutableClock()
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      now: clock.now)
    let writesAfterConstruction = sink.writeCount

    clock.advance(by: 1)
    player.state.globalPosition = 11.9  // 0.9 s ahead of the extrapolated 11
    player.emit(progressEvent(phase: .playing, currentTime: 11.9))
    _ = await awaitQuiescence(
      "Now Playing ignores sub-second drift", of: { "writes=\(sink.writeCount)" })

    #expect(sink.writeCount == writesAfterConstruction)
    withExtendedLifetime(adapter) {}
  }

  @Test("a paused player never republishes for drift")
  func pausedPlayerDoesNotRepublishForDrift() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .paused, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let clock = MutableClock()
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      now: clock.now)
    let writesAfterConstruction = sink.writeCount

    clock.advance(by: 5)
    player.state.globalPosition = 30
    player.emit(progressEvent(phase: .paused, currentTime: 30))
    _ = await awaitQuiescence(
      "Now Playing ignores position moves while paused", of: { "writes=\(sink.writeCount)" })

    #expect(sink.writeCount == writesAfterConstruction)
    withExtendedLifetime(adapter) {}
  }

  @Test("the extrapolation accounts for the playback rate")
  func driftExtrapolationUsesTheRate() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10, rate: 2.0)
    let sink = FakeNowPlayingInfoSink()
    let clock = MutableClock()
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      now: clock.now)
    let writesAfterConstruction = sink.writeCount

    // Two seconds at 2x is four seconds of audio: what the system extrapolates.
    clock.advance(by: 2)
    player.state.globalPosition = 14
    player.emit(progressEvent(phase: .playing, currentTime: 14))
    _ = await awaitQuiescence(
      "Now Playing is quiet at 2x", of: { "writes=\(sink.writeCount)" })
    #expect(sink.writeCount == writesAfterConstruction)

    // One more second should reach 16; 17.5 is 1.5 s further than that.
    clock.advance(by: 1)
    player.state.globalPosition = 17.5
    player.emit(progressEvent(phase: .playing, currentTime: 17.5, sequence: 2))
    await waitUntil { sink.writeCount == writesAfterConstruction + 1 }
    #expect(elapsed(sink) == 17.5)
    withExtendedLifetime(adapter) {}
  }

  @Test("a play/pause phase change republishes")
  func phaseChangeRepublishes() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    let writesAfterConstruction = sink.writeCount

    player.state.phase = .paused
    player.emit(progressEvent(phase: .paused, currentTime: 10))
    await waitUntil { sink.writeCount == writesAfterConstruction + 1 }

    #expect(sink.writeCount == writesAfterConstruction + 1)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    withExtendedLifetime(adapter) {}
  }

  /// The lock screen is the surface a listener is most likely to be looking at when a stream dies,
  /// and it is the one that says least: the transport already draws a Play button, so nothing there
  /// distinguishes a dead stream from a pause the listener chose.
  @Test("an unavailable remote stream names itself in the Now Playing subtitle")
  func unavailableRemoteStreamPublishesStatusSubtitle() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let provider = FakeNowPlayingItemInfoProviding()
    provider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "A Book", author: "An Author")
    let availability = FakePlaybackAvailability()
    availability.unavailableReason = .serverUnreachable

    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: provider, playbackAvailability: availability)

    #expect(
      sink.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        == PlaybackUnavailableCopy.subtitle(for: .serverUnreachable))
    // Losing the server must not cost the listener the identity of what they were listening to.
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String == "A Book")
    withExtendedLifetime(adapter) {}
  }

  /// A device with no network path of its own is a different remedy from a server that is down, and
  /// this is the surface with room for only two words of it.
  @Test("a lost network path names itself rather than blaming the server")
  func lostNetworkPathPublishesItsOwnSubtitle() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let availability = FakePlaybackAvailability()
    availability.unavailableReason = .noNetworkPath

    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      playbackAvailability: availability)

    #expect(
      sink.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        == PlaybackUnavailableCopy.subtitle(for: .noNetworkPath))
    withExtendedLifetime(adapter) {}
  }

  /// PlayerCore reaching its stall phase is not the account-scoped decision that a remote failure
  /// has occurred. Nothing may annotate a complete local download, which deriving the status from
  /// the transport phase alone would do.
  @Test("a raw PlayerCore stall does not annotate Now Playing on its own")
  func rawPlayerStallDoesNotAnnotateNowPlaying() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .stalled, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let provider = FakeNowPlayingItemInfoProviding()
    provider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "A Book", author: "An Author")
    let availability = FakePlaybackAvailability()

    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: provider, playbackAvailability: availability)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "An Author")
    withExtendedLifetime(adapter) {}
  }

  @Test("recovering the stream restores the author it replaced")
  func recoveredStreamRestoresTheAuthor() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let provider = FakeNowPlayingItemInfoProviding()
    provider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "A Book", author: "An Author")
    let availability = FakePlaybackAvailability()
    availability.unavailableReason = .serverUnreachable
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: provider, playbackAvailability: availability)

    availability.unavailableReason = nil
    availability.notifyChange()

    await waitUntil { sink.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "An Author" }
    withExtendedLifetime(adapter) {}
  }

  @Test("a change in availability republishes once, while position-only ticks remain quiet")
  func availabilityChangeRepublishesAtASemanticBoundary() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let availability = FakePlaybackAvailability()
    let clock = MutableClock()
    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      playbackAvailability: availability, now: clock.now)
    let writesAfterConstruction = sink.writeCount

    availability.unavailableReason = .serverUnreachable
    availability.notifyChange()
    await waitUntil {
      sink.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        == PlaybackUnavailableCopy.subtitle(for: .serverUnreachable)
    }
    #expect(sink.writeCount == writesAfterConstruction + 1)

    for time in [11.0, 12.0, 13.0] {
      clock.advance(by: 1)
      player.state.globalPosition = time
      player.emit(progressEvent(phase: .playing, currentTime: time))
    }
    _ = await awaitQuiescence(
      "Now Playing remains unchanged after an availability update",
      of: { "writes=\(sink.writeCount)" })

    #expect(sink.writeCount == writesAfterConstruction + 1)
    withExtendedLifetime(adapter) {}
  }

  @Test("a rate change republishes even without a phase change")
  func rateChangeRepublishes() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10, rate: 1.0)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    let writesAfterConstruction = sink.writeCount

    player.state.rate = 1.5
    player.emit(progressEvent(phase: .playing, currentTime: 10))
    await waitUntil { sink.writeCount == writesAfterConstruction + 1 }

    #expect(sink.writeCount == writesAfterConstruction + 1)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
    withExtendedLifetime(adapter) {}
  }

  @Test("crossing into a new chapter republishes even mid-playback with no phase change")
  func chapterBoundaryCrossingRepublishes() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    let writesAfterConstruction = sink.writeCount

    player.state.globalPosition = 55  // crosses from chapter 0 into chapter 1
    player.emit(progressEvent(phase: .playing, currentTime: 55))
    await waitUntil { sink.writeCount == writesAfterConstruction + 1 }

    #expect(sink.writeCount == writesAfterConstruction + 1)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyChapterNumber] as? Int == 1)
    withExtendedLifetime(adapter) {}
  }
}
