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

  // MARK: - Podcast episodes: the lock screen names the episode, not just the show

  @Test("a podcast episode publishes the episode title, with the show as the secondary line")
  func podcastEpisodePublishesEpisodeTitleAndShow() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, episodeID: "episode-12")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeEpisodeAwareNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Deep Cover", author: "Pushkin")
    itemInfoProvider.infoByEpisodeID["episode-12"] = NowPlayingItemInfo(
      title: "12. The Truth About Sam", author: "Deep Cover")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    let info = sink.nowPlayingInfo
    #expect(info?[MPMediaItemPropertyTitle] as? String == "12. The Truth About Sam")
    #expect(info?[MPMediaItemPropertyArtist] as? String == "Deep Cover")
    // Named, but still not identified: the raw episode id stays out of the dictionary.
    for value in (info ?? [:]).values {
      let description = String(describing: value)
      #expect(description.contains("episode-12") == false)
      #expect(description.contains("://") == false)
    }
    withExtendedLifetime(adapter) {}
  }

  @Test("auto-advancing to the next episode of the same show republishes the new episode's metadata")
  func autoAdvanceBetweenEpisodesOfTheSameShowRepublishes() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10, episodeID: "episode-12")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeEpisodeAwareNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Deep Cover", author: "Pushkin")
    itemInfoProvider.infoByEpisodeID["episode-12"] = NowPlayingItemInfo(
      title: "12. The Truth About Sam", author: "Deep Cover")
    itemInfoProvider.infoByEpisodeID["episode-13"] = NowPlayingItemInfo(
      title: "13. The Last Call", author: "Deep Cover")
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    let writesAfterConstruction = sink.writeCount

    // The advance a listener actually hears: same show, phase, rate and chapter index.
    // Only the episode identity moves.
    player.state = Self.state(phase: .playing, position: 0, episodeID: "episode-13")
    player.emit(progressEvent(phase: .playing, currentTime: 0))
    await waitUntil { sink.writeCount == writesAfterConstruction + 1 }

    #expect(sink.writeCount == writesAfterConstruction + 1)
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "13. The Last Call")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Deep Cover")
    withExtendedLifetime(adapter) {}
  }

  @Test("an audiobook still publishes item-level title/author and is resolved with no episode id")
  func audiobookMetadataIsUnchangedByEpisodeAwareness() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 12, rate: 1.25)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeEpisodeAwareNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")
    itemInfoProvider.infoByEpisodeID["episode-12"] = NowPlayingItemInfo(
      title: "12. The Truth About Sam", author: "Deep Cover")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    let info = sink.nowPlayingInfo
    #expect(info?[MPMediaItemPropertyTitle] as? String == "Chapter One")
    #expect(info?[MPMediaItemPropertyAlbumTitle] as? String == "Dune")
    #expect(info?[MPMediaItemPropertyArtist] as? String == "Frank Herbert")
    // Duration and elapsed are chapter-scoped: position 12 is 12s into a 50s first chapter,
    // not 12s into the 150s book.
    #expect(info?[MPMediaItemPropertyPlaybackDuration] as? Double == 50)
    #expect(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12)
    #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.25)
    #expect(info?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.25)
    #expect(itemInfoProvider.requestedEpisodeIDs == [String?.none])
    withExtendedLifetime(adapter) {}
  }

  // MARK: - No credentials ever appear in the metadata dictionary

  @Test("no token or server URL string ever appears among the published metadata values")
  func noTokenOrServerURLInMetadata() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    let info = sink.nowPlayingInfo ?? [:]
    for value in info.values {
      let description = String(describing: value)
      #expect(description.contains("token") == false)
      #expect(description.contains("://") == false)
    }
    withExtendedLifetime(adapter) {}
  }

  @Test("podcast episode identity never leaks into Now Playing metadata")
  func podcastEpisodeIdentityNeverLeaksIntoNowPlayingMetadata() {
    let canaryEpisodeIdentity =
      "CANARY-ACCESS-TOKEN-DO-NOT-LEAK|https://podcast-origin.invalid/private-feed"
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, episodeID: canaryEpisodeIdentity)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(
      title: "Privacy-safe episode", author: "Privacy-safe show")

    let adapter = makeAdapter(
      player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    let info = sink.nowPlayingInfo ?? [:]
    #expect(info[MPMediaItemPropertyTitle] as? String == "Privacy-safe episode")
    #expect(info[MPMediaItemPropertyArtist] as? String == "Privacy-safe show")
    for value in info.values {
      let description = String(describing: value)
      #expect(description.contains("CANARY-ACCESS-TOKEN") == false)
      #expect(description.contains("podcast-origin.invalid") == false)
      #expect(description.contains("://") == false)
    }
    withExtendedLifetime(adapter) {}
  }
}
