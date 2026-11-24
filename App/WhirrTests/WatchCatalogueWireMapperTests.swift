import AppModel
import Foundation
import Persistence
import PlayerCore
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch catalogue wire mapper")
struct WatchCatalogueWireMapperTests {
  @Test func chapterProgressOnlyEnrichesMatchingCurrentSelection() throws {
    let source = try #require(PodcastSourceIdentity.abs(itemId: "book"))
    let selection = CompanionSelection(source: source)
    let otherEpisode = CompanionSelection(source: source, episodeID: "episode")
    let capabilities = CompanionCatalogueCapabilities(phonePlayable: true, watchPlayable: true)
    let snapshot = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined", accountIdentityHash: "account", serverIdentityHash: "server",
      continueListening: [
        .init(
          id: selection, title: "Book", progressSeconds: 20, durationSeconds: 100, capabilities: capabilities,
          isCurrentPlayback: true)
      ],
      recentBooks: [
        .init(id: selection, title: "Book", progressSeconds: 20, durationSeconds: 100, capabilities: capabilities)
      ])
    let chapter = PlaybackChapter(title: "Chapter 2", start: 30, end: 100)
    let result = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(
        from: snapshot, generatedAt: Date(),
        playbackProgress: (selection, 35, 100, chapter)))
    #expect(result.items[0].progressSeconds == 35)
    #expect(result.items[0].chapterStartSeconds == 30 && result.items[0].chapterEndSeconds == 100)
    #expect(result.items[0].chapterTitle == "Chapter 2")
    #expect(result.items[1].progressSeconds == 20 && result.items[1].chapterStartSeconds == nil)
    let mismatch = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(
        from: snapshot, generatedAt: Date(),
        playbackProgress: (otherEpisode, 35, 100, chapter)))
    #expect(mismatch.items[0].progressSeconds == 20 && mismatch.items[0].chapterStartSeconds == nil)
  }

  /// Only the current row carries the phone's last listen, and only when it names that title.
  @Test func onlyTheCurrentRowCarriesThePhonesLastListen() throws {
    let source = try #require(PodcastSourceIdentity.abs(itemId: "book"))
    let selection = CompanionSelection(source: source)
    let capabilities = CompanionCatalogueCapabilities(phonePlayable: true, watchPlayable: true)
    let snapshot = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined", accountIdentityHash: "account", serverIdentityHash: "server",
      continueListening: [
        .init(
          id: selection, title: "Book", progressSeconds: 20, durationSeconds: 100, capabilities: capabilities,
          isCurrentPlayback: true)
      ],
      recentBooks: [
        .init(id: selection, title: "Book", progressSeconds: 20, durationSeconds: 100, capabilities: capabilities)
      ])
    let listened = Date(timeIntervalSince1970: 1_790_000_000)
    let result = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(
        from: snapshot, generatedAt: Date(), playbackProgress: (selection, 35, 100, nil),
        phoneLastListenedAt: listened))
    #expect(result.items.map(\.lastListenedAt) == [listened, nil])
    let unloaded = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(
        from: snapshot, generatedAt: Date(), phoneLastListenedAt: listened))
    #expect(unloaded.items.map(\.lastListenedAt) == [nil, nil])
  }

  @Test func rowsCarryThePhonesCoverRevision() throws {
    let source = try #require(PodcastSourceIdentity.abs(itemId: "book"))
    let capabilities = CompanionCatalogueCapabilities(phonePlayable: true, watchPlayable: true)
    let snapshot = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined", accountIdentityHash: "account", serverIdentityHash: "server",
      continueListening: [
        .init(
          id: CompanionSelection(source: source), title: "Dated", capabilities: capabilities,
          serverUpdatedAt: Date(timeIntervalSince1970: 1_790_000_000.123)),
        .init(id: CompanionSelection(source: source, episodeID: "e"), title: "Undated", capabilities: capabilities),
      ])
    let result = try #require(WatchCatalogueWireMapper.makeWatchSnapshot(from: snapshot, generatedAt: Date()))
    #expect(result.items.map(\.artworkRevision) == ["1790000000123", nil])
  }

  @Test func mapsCurrentPlaybackRate() throws {
    let companion = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined",
      accountIdentityHash: "account", serverIdentityHash: "server")
    let snapshot = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(
        from: companion, generatedAt: Date(), playbackState: .paused, playbackRate: 1.35))
    #expect(snapshot.playbackRate == 1.35)
  }
  @Test("pure mapping preserves sections and source-qualified selections")
  func mapsCompanionRows() throws {
    let input = CompanionCatalogueInput(
      accountIdentity: AccountIdentity(
        id: 7, clientUUID: "client", serverIdentityFingerprint: "server"),
      continueListening: [
        HomeItem(
          serverItemId: "book", title: "Book", author: "Author", category: .audiobook,
          durationSeconds: 600, progressSeconds: 120, isFinished: false, addedAt: nil,
          isDownloaded: false)
      ],
      recentEpisodes: [
        HomePodcastEpisode(
          itemID: "rss:3", showTitle: "Show", showAuthor: nil, episodeID: "episode",
          title: "Episode", subtitle: "Subtitle", publishedAt: Date(), durationSeconds: 900)
      ])
    let companion = CompanionCatalogueBuilder.build(input)
    let snapshot = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(
        from: companion, generatedAt: Date(timeIntervalSince1970: 1)))

    #expect(snapshot.accountStamp != nil)
    #expect(snapshot.items.count == 2)
    #expect(snapshot.items[0].section == .continueListening)
    #expect(snapshot.items[1].section == .recentEpisodes)
    #expect(snapshot.items[0].selection == .audiobookshelf(itemID: "book", episodeID: nil))
    #expect(snapshot.items[1].selection == .nativeFeed(feedID: "3", episodeID: "episode"))
  }

  @Test("server rows pass Watch playback through; Watch-local downloads are never advertised")
  func passesWatchPlaybackForServerRows() throws {
    let companion = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined",
      accountIdentityHash: "account",
      serverIdentityHash: "server",
      recentBooks: [
        CompanionCatalogueItem(
          id: CompanionSelection(source: try #require(PodcastSourceIdentity.abs(itemId: "book"))),
          title: "Book",
          capabilities: CompanionCatalogueCapabilities(
            phonePlayable: true, watchPlayable: true, phoneDownloaded: true, watchDownloaded: true)),
        CompanionCatalogueItem(
          id: CompanionSelection(source: try #require(PodcastSourceIdentity.abs(itemId: "phone-only"))),
          title: "Phone only",
          capabilities: CompanionCatalogueCapabilities(phonePlayable: true, watchPlayable: false)),
      ])
    let snapshot = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(from: companion, generatedAt: Date()))

    #expect(snapshot.items.count == 2)
    #expect(snapshot.items[0].capabilities.phonePlayable)
    #expect(snapshot.items[0].capabilities.phoneLocalDownload)
    #expect(snapshot.items[0].capabilities.watchPlayable)
    #expect(snapshot.items[0].capabilities.watchLocalDownload == false)
    #expect(snapshot.items[1].capabilities.watchPlayable == false)
  }

  @Test("native feed rows never advertise Watch playback even if the phone claims it")
  func forcesNativeRowsPhoneOnly() throws {
    let companion = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined",
      accountIdentityHash: "account",
      serverIdentityHash: "server",
      recentEpisodes: [
        CompanionCatalogueItem(
          id: CompanionSelection(
            source: try #require(PodcastSourceIdentity.rss(feedId: 3)), episodeID: "episode"),
          title: "Episode",
          capabilities: CompanionCatalogueCapabilities(phonePlayable: true, watchPlayable: true))
      ])
    let snapshot = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(from: companion, generatedAt: Date()))

    #expect(snapshot.items.count == 1)
    #expect(snapshot.items[0].selection == .nativeFeed(feedID: "3", episodeID: "episode"))
    #expect(snapshot.items[0].capabilities.phonePlayable)
    #expect(snapshot.items[0].capabilities.watchPlayable == false)
  }

  @Test("row identity includes shelf section and remains stable")
  func rowIdentityIsStableAndSectionQualified() throws {
    let source = try #require(PodcastSourceIdentity.abs(itemId: "book"))
    let selection = CompanionSelection(source: source, episodeID: nil)
    let first = CompanionCatalogueBuilder.rowIdentifier(
      selection: selection, section: .continueListening)
    let second = CompanionCatalogueBuilder.rowIdentifier(
      selection: selection, section: .continueListening)
    let differentSection = CompanionCatalogueBuilder.rowIdentifier(
      selection: selection, section: .downloads)

    #expect(first == second)
    #expect(first != differentSection)
  }

  @Test("the remove-played setting rides the mapper and the assembly into the snapshot")
  func removePlayedSettingReachesTheSnapshot() throws {
    let companion = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined",
      accountIdentityHash: "account",
      serverIdentityHash: "server")

    for enabled in [true, false] {
      let mapped = try #require(
        WatchCatalogueWireMapper.makeWatchSnapshot(
          from: companion, generatedAt: Date(timeIntervalSince1970: 1),
          removePlayedNativeEpisodes: enabled))
      #expect(mapped.removePlayedNativeEpisodes == enabled)

      let assembly = WatchCatalogueAssembly(
        identity: AccountIdentity(id: 7, clientUUID: "client", serverIdentityFingerprint: "server"),
        nativeEnabled: true,
        absContinue: [],
        nativeContinueItems: [],
        bookmark: nil,
        recentBooks: [],
        absLatest: nil,
        nativeLatestEpisodes: [],
        absDownloads: [],
        nativeDownloadFeeds: [],
        generatedAt: Date(timeIntervalSince1970: 1),
        playbackState: .idle,
        playbackRate: nil,
        skipBackwardSeconds: 15,
        skipForwardSeconds: 30,
        playbackRatePresets: [1],
        removePlayedNativeEpisodes: enabled,
        playbackProgress: nil,
        phoneLastListenedAt: nil)
      let assembled = try #require(assembly.makeSnapshot())
      #expect(assembled.removePlayedNativeEpisodes == enabled)
    }
  }

  @Test("oversized metadata is dropped before the Watch payload is encoded")
  func oversizedMetadataMappingStaysBounded() throws {
    let source = try #require(PodcastSourceIdentity.abs(itemId: "book-large"))
    let row = CompanionCatalogueItem(
      id: CompanionSelection(source: source),
      title: String(repeating: "💥", count: 2_000),
      subtitle: String(repeating: "subtitle", count: 200),
      capabilities: CompanionCatalogueCapabilities(phonePlayable: true, watchPlayable: false))
    let companion = CompanionCatalogueSnapshot(
      accountServerIdentityHash: "combined",
      accountIdentityHash: "account",
      serverIdentityHash: "server",
      recentBooks: [row])

    let snapshot = try #require(
      WatchCatalogueWireMapper.makeWatchSnapshot(
        from: companion, generatedAt: Date(timeIntervalSince1970: 1)))
    let data = try WatchWireCodec.encode(snapshot)

    #expect(snapshot.items.isEmpty)
    #expect(data.count <= WatchProtocolVersion.maxSnapshotBytes)
  }

}
