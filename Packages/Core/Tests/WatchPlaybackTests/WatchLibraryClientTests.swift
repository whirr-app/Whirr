import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

@Test("Watch login stores account and bounds catalogue pages")
func loginAndCatalogue() async throws {
  let server = try WatchServerConfiguration.https(host: "example.test", pathPrefix: "abs")
  #expect(server.baseURL.absoluteString == "https://example.test/abs")
  let settings = LockedMemorySettings()
  let tokens = InMemoryTokenStore()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let service = try FakeService()
  service.page = LibraryItemsPage(
    items: [
      LibraryItemSummary(
        id: "book-1", libraryID: "books", mediaType: "book", title: "Book", authorName: "Author", seriesName: nil,
        numAudioFiles: 1)
    ], total: 1, limit: 100, page: 0)
  let client = WatchLibraryClient(accountStore: store, service: service)

  let record = try await client.login(username: "user", password: "secret")
  #expect(record.userID == "u1")
  let page = try await client.catalogue(libraryID: "books", page: 0, limit: 10_000)
  #expect(page.items.count == 1)
  #expect(page.items[0].selection == .audiobookshelf(itemID: "book-1", episodeID: nil))
  #expect((try await client.libraries()).first?.id == "books")
  #expect((try await store.load())?.userID == "u1")
}

@Test("same-user reauthentication succeeds, foreign user is rejected")
func accountIsolation() async throws {
  let settings = LockedMemorySettings()
  let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: settings)
  let service = try FakeService()
  service.page = LibraryItemsPage(
    items: [
      LibraryItemSummary(
        id: "book-1", libraryID: "books", mediaType: "book", title: "Book", authorName: nil, seriesName: nil,
        numAudioFiles: 1)
    ], total: 1, limit: 100, page: 0)
  let client = WatchLibraryClient(accountStore: store, service: service)
  _ = try await client.login(apiToken: "token")
  _ = try await client.catalogue(libraryID: "books")
  _ = try await client.login(apiToken: "token")

  try service.changeUser(to: "u2")
  do {
    _ = try await client.login(apiToken: "token")
    Issue.record("foreign login should fail")
  } catch let error as WatchLibraryError { #expect(error == .accountMismatch) }
}

@Test("logout clears account settings and token namespace")
func logoutClearsState() async throws {
  let settings = LockedMemorySettings()
  let tokens = InMemoryTokenStore()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let service = try FakeService()
  let client = WatchLibraryClient(accountStore: store, service: service)
  let record = try await client.login(apiToken: "token")
  try await client.logout()
  #expect(await client.currentAccount() == nil)
  #expect(try await store.load() == nil)
  #expect(try tokens.load(for: record.tokenAccount()) == nil)
}

@Test("expanded podcast episodes and progress produce source-qualified Watch values")
func podcastAndContinueProjection() async throws {
  let settings = LockedMemorySettings()
  let store = WatchAccountStore(tokenStore: InMemoryTokenStore(), settings: settings)
  let service = try FakeService()
  let episode = PodcastEpisode(
    id: "ep-1", title: "Episode", contentUrl: nil, mimeType: "audio/mpeg", duration: 60,
    publishedAt: nil,
    audioFile: PodcastEpisodeAudio(ino: "file-1", expectedSize: 12, mimeType: "audio/mpeg", duration: 60))
  service.detailValue = ItemDetail(
    id: "pod-1", libraryID: "podcasts", mediaType: "podcast",
    media: .podcast(PodcastMedia(title: "Show", author: nil, description: nil, episodes: [episode])))
  service.progressValue = UserProgressSnapshot(
    progress: [
      MediaProgress(
        libraryItemID: "book-1", episodeID: nil, mediaItemID: nil, mediaItemType: "book",
        duration: 100, progress: 0.25, currentTime: nil, isFinished: false,
        hideFromContinueListening: false, ebookLocation: nil, ebookProgress: nil,
        lastUpdate: nil, startedAt: nil, finishedAt: nil),
      MediaProgress(
        libraryItemID: "hidden", episodeID: nil, mediaItemID: nil, mediaItemType: "book",
        duration: 100, progress: 0.5, currentTime: nil, isFinished: false,
        hideFromContinueListening: true, ebookLocation: nil, ebookProgress: nil,
        lastUpdate: nil, startedAt: nil, finishedAt: nil),
    ], hiddenSeriesIDs: [])
  let client = WatchLibraryClient(accountStore: store, service: service)
  _ = try await client.login(apiToken: "token")
  let episodes = try await client.episodes(for: "pod-1")
  #expect(episodes.count == 1)
  #expect(episodes[0].audio?.fileIdentity == "file-1")
  let continueItems = try await client.continueListening()
  #expect(continueItems.count == 1)
  #expect(continueItems[0].progressSeconds == 25)
  let browsedEpisodes = try await client.browsePodcastEpisodes(libraryID: "podcasts", showID: "pod-1")
  #expect(browsedEpisodes.items.first?.id == "pod-1\u{1f}ep-1")
}

/// Test configuration retaining the reverse-proxy path prefix normalized by ABSApi.
private enum WatchServerConfiguration {
  static func https(host: String, pathPrefix: String = "") throws -> ABSServerConfig {
    guard host.isEmpty == false, host.contains("://") == false,
      let url = URL(string: "https://\(host)\(pathPrefix.hasPrefix("/") ? pathPrefix : "/\(pathPrefix)")")
    else { throw WatchLibraryError.invalidServer }
    return try ABSServerConfig(url: url)
  }
}
