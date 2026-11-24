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

/// Covers `NowPlayingMetadataAdapter`, which publishes `MPNowPlayingInfoCenter`-shaped metadata
/// from `PlaybackControlling.state` and `.progressEvents` plus an injected title/author source
/// (`PlayerCore` has none). A `NowPlayingInfoSink` fake keeps tests off the process-wide
/// `MPNowPlayingInfoCenter.default()`. `CoverImageClient` is nil except in the artwork test.
@MainActor
@Suite("NowPlayingMetadataAdapter", .timeLimit(.minutes(1)))
struct NowPlayingMetadataTests {

  // MARK: - Initial publish (construction observes whatever is already loaded)

  @Test("title, author, duration, elapsed time, rate, and default rate are published on construction")
  func publishesCoreMetadataOnConstruction() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 12, rate: 1.25)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    let info = sink.nowPlayingInfo
    // Position 12 is in the first chapter: the title names the chapter, the book moves to album.
    #expect(info?[MPMediaItemPropertyTitle] as? String == "Chapter One")
    #expect(info?[MPMediaItemPropertyAlbumTitle] as? String == "Dune")
    #expect(info?[MPMediaItemPropertyArtist] as? String == "Frank Herbert")
    // Duration and elapsed are chapter-scoped: position 12 is 12s into a 50s first chapter,
    // not 12s into the 150s book.
    #expect(info?[MPMediaItemPropertyPlaybackDuration] as? Double == 50)
    #expect(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12)
    #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.25)
    #expect(info?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.25)
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Chapter-scoped timeline (the lock-screen scrubber)

  @Test("a chaptered audiobook publishes the current chapter's duration and chapter-relative elapsed")
  func chapteredBookPublishesChapterScopedTimeline() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 60)  // 10s into the 50s second chapter
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 50)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 10)
    withExtendedLifetime(adapter) {}
  }

  @Test("crossing into a new chapter rebases the published timeline onto that chapter")
  func chapterBoundaryCrossingRebasesTheTimeline() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    player.state.globalPosition = 105  // 5s into the third chapter
    player.emit(progressEvent(phase: .playing, currentTime: 105))
    await waitUntil { sink.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 5 }

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 50)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 5)
    withExtendedLifetime(adapter) {}
  }

  /// The lock screen shows "0:00 remaining" over audible audio, so a correction must republish
  /// even though it moves nothing else. The dedupe is keyed on item, phase, rate and chapter alone,
  /// so it must not suppress a remaining-time change.
  @Test("a corrected duration republishes even though nothing else in the snapshot moved")
  func aCorrectedDurationRepublishesTheTimeline() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(chapters: PlaybackChapterMap(chapters: []), position: 148)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Empire", author: "Goalhanger")
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 150)

    let grown = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 180)])
    player.state.item = PlayerItem(
      id: "item-1", episodeID: nil, timeline: grown, chapters: PlaybackChapterMap(chapters: []))
    player.emit(progressEvent(phase: .playing, currentTime: 148))

    await waitUntil { sink.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 180 }
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 148)
    withExtendedLifetime(adapter) {}
  }

  @Test("a book with no chapters keeps the whole-book timeline")
  func chapterlessBookPublishesTheWholeBookTimeline() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(chapters: PlaybackChapterMap(chapters: []), position: 12)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 150)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 12)
    withExtendedLifetime(adapter) {}
  }

  @Test("a podcast episode keeps the whole-episode timeline even when the item carries chapters")
  func podcastEpisodePublishesTheWholeEpisodeTimeline() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 60, episodeID: "episode-12")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Deep Cover", author: "Deep Cover")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 150)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 60)
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Chapter as the title

  @Test("the title names the current chapter and the album names the book")
  func chapterIsTheTitleAndTheBookIsTheAlbum() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 60)  // inside the second chapter
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Chapter Two")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String == "Dune")
    withExtendedLifetime(adapter) {}
  }

  @Test("the title slot carries the compact chapter name")
  func chapterTitleIsCompacted() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(
      chapters: PlaybackChapterMap(chapters: [
        PlaybackChapter(id: "c0", title: "Chapter Twenty: The Clock-Tower", start: 0, end: 150)
      ]))
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(
      title: "The Ruby in the Smoke", author: "Philip Pullman")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "20: The Clock-Tower")
    #expect(
      sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String == "The Ruby in the Smoke")
    withExtendedLifetime(adapter) {}
  }

  @Test("crossing into a new chapter republishes the new chapter's title")
  func chapterBoundaryCrossingUpdatesTheTitle() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Chapter One")

    player.state.globalPosition = 55  // crosses from chapter 0 into chapter 1
    player.emit(progressEvent(phase: .playing, currentTime: 55))
    await waitUntil { sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Chapter Two" }

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Chapter Two")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String == "Dune")
    withExtendedLifetime(adapter) {}
  }

  @Test("a seek backwards into an earlier chapter republishes that chapter's title")
  func seekingBackwardsUpdatesTheTitle() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 120)  // third chapter
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Chapter Three")

    player.state.globalPosition = 5
    player.emit(progressEvent(phase: .playing, currentTime: 5))
    await waitUntil { sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Chapter One" }

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Chapter One")
    withExtendedLifetime(adapter) {}
  }

  @Test("a book with no chapters falls back to the book title and publishes no album")
  func noChaptersFallsBackToTheBookTitle() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(chapters: PlaybackChapterMap(chapters: []))
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Dune")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] == nil)
    withExtendedLifetime(adapter) {}
  }

  @Test("a chapter with a blank title falls back to the book title rather than showing nothing")
  func blankChapterTitleFallsBackToTheBookTitle() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(
      chapters: PlaybackChapterMap(chapters: [
        PlaybackChapter(id: "c0", title: "   ", start: 0, end: 50)
      ]))
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Dune", author: "Frank Herbert")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Dune")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] == nil)
    withExtendedLifetime(adapter) {}
  }

  @Test("a podcast episode keeps its own title even when the episode carries chapters")
  func aPodcastEpisodeKeepsItsTitleDespiteChapters() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 60, episodeID: "episode-12")  // inside the second chapter
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeEpisodeAwareNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Deep Cover", author: "Pushkin")
    itemInfoProvider.infoByEpisodeID["episode-12"] = NowPlayingItemInfo(
      title: "12. The Truth About Sam", author: "Deep Cover")

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "12. The Truth About Sam")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] == nil)
    withExtendedLifetime(adapter) {}
  }

  /// The end-to-end episode projection the lock screen shows: the library provider puts the
  /// episode title in the title slot and the parent show in the subtitle slot, matching the
  /// bookmark row's primary/secondary lines. A book keeps its own author there instead.
  @Test("an episode drawn from the library store names itself with the show as the subtitle")
  func libraryEpisodeNamesItselfWithTheShowAsTheSubtitle() throws {
    let database = try AppDatabase.inMemory()
    let accountDAO = AccountDAO(database: database)
    let account = try accountDAO.save(
      AccountRecord(
        clientUUID: "client-uuid", serverBaseURL: "https://books.example.test",
        serverUserId: "user-1", serverVersion: "2.35.1"))
    let accountId = try #require(account.id)
    let library = try LibraryDAO(database: database).upsert(
      LibraryRecord(
        accountId: accountId, serverLibraryId: "lib-1", mediaType: "podcast", name: "Podcasts",
        lastSeenGeneration: 1))
    let item = try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: accountId, libraryId: try #require(library.id), serverItemId: "item-1",
        mediaKind: "podcast", title: "Deep Cover", sortTitle: "Deep Cover",
        author: "Pushkin Industries"))
    try PodcastEpisodeDAO(database: database).upsert(
      PodcastEpisodeRecord(
        accountId: accountId, itemId: try #require(item.id), serverEpisodeId: "episode-12",
        title: "12. The Truth About Sam", lastSeenGeneration: 1))

    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 60, episodeID: "episode-12")
    let sink = FakeNowPlayingInfoSink()
    let adapter = makeAdapter(
      player: player, sink: sink,
      itemInfoProvider: LibraryBackedNowPlayingItemInfoProvider(
        database: database, accountDAO: accountDAO))

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "12. The Truth About Sam")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == "Deep Cover")
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] == nil)
    withExtendedLifetime(adapter) {}
  }

  @Test("nothing playable at construction publishes nothing (nil now playing info)")
  func nothingPlayableAtConstructionPublishesNil() {
    let player = FakeAdapterPlaybackControlling()
    player.state = .idle
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo == nil)
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Chapter number/count (zero-based)

  @Test("chapter number is zero-based and chapter count reflects the book's chapter list")
  func chapterNumberIsZeroBasedWithCount() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 60)  // inside the second chapter (index 1)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyChapterNumber] as? Int == 1)
    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyChapterCount] as? Int == 3)
    withExtendedLifetime(adapter) {}
  }

  @Test("first chapter publishes chapter number 0")
  func firstChapterIsChapterNumberZero() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 5)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPNowPlayingInfoPropertyChapterNumber] as? Int == 0)
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Clearing on stop/logout

  @Test("stopping (item becomes nil) clears now playing info")
  func stoppingClearsNowPlayingInfo() async {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    #expect(sink.nowPlayingInfo != nil)

    player.state = .idle
    player.emit(progressEvent(phase: .idle, currentTime: 10))
    await waitUntil { sink.nowPlayingInfo == nil }

    #expect(sink.nowPlayingInfo == nil)
    withExtendedLifetime(adapter) {}
  }

  @Test("explicit clear() clears now playing info regardless of controller state (logout)")
  func explicitClearClearsRegardlessOfState() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)
    #expect(sink.nowPlayingInfo != nil)

    adapter.clear()

    #expect(sink.nowPlayingInfo == nil)
  }
}
