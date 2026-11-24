import ABSApi
import Foundation
import GRDB
import Persistence
import PodcastFeeds
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("Add feed model", .timeLimit(.minutes(1)))
struct AddFeedModelTests {
  private let feedURL = URL(string: "https://feeds.example.test/x.xml")!
  private let preview = FeedPreview(
    feedURL: URL(string: "https://feeds.example.test/x.xml")!, title: "A Feed",
    author: "An Author", artworkURL: URL(string: "https://feeds.example.test/art.png"),
    synopsis: "A synopsis", episodeCount: 3)

  @Test func validPreviewAndFollowWrite() async {
    let following = StubFollowing()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following, now: { date })

    await model.loadPreview(from: feedURL.absoluteString)
    #expect(model.phase == .preview(preview))
    #expect(model.previewDisplay?.title == "A Feed")
    #expect(model.canFollow)

    await model.follow()
    #expect(model.phase == .followed(feedId: 1))
    #expect(model.followedFeedItemID == "rss:1")
    #expect(await following.calls == 1)
  }

  @Test func directoryFollowMarksTheRowFollowedAndKeepsTheSheetOpen() async {
    let otherURL = URL(string: "https://feeds.example.test/y.xml")!
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil, episodeCount: nil),
      PodcastDirectoryResult(
        feedURL: otherURL, title: "Also found", author: nil, artworkURL: nil, episodeCount: nil),
    ])
    let following = StubFollowing()
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following,
      directory: directory)
    await model.submit("found")

    await model.followDirectoryResult(feedURL: feedURL)

    // A directory follow is one of possibly several: it must not finish the sheet's journey.
    #expect(model.isFollowed == false)
    #expect(model.followedFeedItemID == nil)
    #expect(model.isDirectoryResultFollowed(feedURL))
    #expect(model.isDirectoryResultFollowed(otherURL) == false)

    await model.followDirectoryResult(feedURL: otherURL)
    #expect(model.isDirectoryResultFollowed(otherURL))
    #expect(await following.calls == 2)

    model.reset()
    #expect(model.isDirectoryResultFollowed(feedURL) == false)
  }

  @Test func alreadyFollowedDirectoryResultsAreMarkedWithoutTouchingTheNetwork() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil, episodeCount: nil)
    ])
    let following = StubFollowing()
    // Stored and directory spellings of one feed differ only in scheme, host case and a
    // trailing slash; they must still match.
    await following.setFollowedFeedURLs([URL(string: "http://FEEDS.example.test/x.xml/")!])
    let previews = stubbedPreviews(.failure(.notAFeed))
    let model = AddFeedModel(previews: previews, following: following, directory: directory)
    await model.submit("found")

    #expect(model.isDirectoryResultFollowed(feedURL))

    await model.followDirectoryResult(feedURL: feedURL)

    #expect(previews.urls.isEmpty)
    #expect(await following.calls == 0)
    #expect(model.directoryFollowErrors.isEmpty)
  }

  @Test func opmlImportIsOfferedOnlyToADeviceThatFollowsNothingYet() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil, episodeCount: nil)
    ])
    let fresh = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: StubFollowing(),
      directory: directory)
    #expect(fresh.offersOPMLImport == false)

    await fresh.loadFollowedFeeds()
    #expect(fresh.offersOPMLImport)

    // Decided once per presentation: following from this sheet must not pull the row away.
    await fresh.submit("found")
    await fresh.followDirectoryResult(feedURL: feedURL)
    #expect(fresh.offersOPMLImport)

    fresh.reset()
    #expect(fresh.offersOPMLImport == false)

    let migrated = StubFollowing()
    await migrated.setFollowedFeedURLs([feedURL])
    let established = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: migrated)
    await established.loadFollowedFeeds()
    #expect(established.offersOPMLImport == false)
  }

  @Test func aDuplicateReportedByTheStoreBecomesFollowedStateNotAnError() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil, episodeCount: nil)
    ])
    let following = StubFollowing()
    await following.setResult(.failure(.alreadyFollowing(existingFeedId: 9)))
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following,
      directory: directory)
    await model.submit("found")

    await model.followDirectoryResult(feedURL: feedURL)

    #expect(model.directoryFollowErrors.isEmpty)
    #expect(model.isDirectoryResultFollowed(feedURL))
  }

  @Test func invalidAndProviderFailuresMapToBoundedCopyStates() async {
    let invalid = AddFeedModel(
      previews: stubbedPreviews(.failure(.unreachable)),
      following: StubFollowing())
    await invalid.loadPreview(from: "not a url")
    #expect(invalid.phase == .failed(.invalidAddress))

    let unavailable = AddFeedModel(
      previews: stubbedPreviews(.failure(.unreachable)),
      following: StubFollowing())
    await unavailable.loadPreview(from: feedURL.absoluteString)
    #expect(unavailable.phase == .failed(.unreachable))
  }

  @Test func aPastedFeedAlreadyFollowedPreviewsAsFollowed() async {
    let following = StubFollowing()
    await following.setFollowedFeedURLs([feedURL])
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following)

    await model.loadPreview(from: feedURL.absoluteString)

    #expect(model.phase == .preview(preview))
    #expect(model.isPreviewFollowed)
    #expect(model.canFollow == false)
  }

  @Test func aDuplicateFollowOfAPastedFeedSettlesAsFollowed() async {
    let following = StubFollowing()
    await following.setResult(.failure(.alreadyFollowing(existingFeedId: 9)))
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following)
    await model.loadPreview(from: feedURL.absoluteString)
    #expect(model.isPreviewFollowed == false)

    await model.follow()

    #expect(model.phase == .preview(preview))
    #expect(model.isPreviewFollowed)
    #expect(model.canFollow == false)
    #expect(model.isFollowed == false)
  }

  @Test func productionFollowerWritesDeviceOwnedStore() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let follower = RSSFeedFollowing(store: store)

    let id = try await follower.follow(preview, subscribedAt: Date())

    #expect(try await store.fetchFeed(feedId: id)?.title == preview.title)
    #expect(try await store.recoveryRequired(feedID: id) == false)
    await #expect(throws: FollowFeedError.alreadyFollowing(existingFeedId: id)) {
      try await follower.follow(preview, subscribedAt: Date())
    }
    #expect(try await follower.followedFeedURLs() == [preview.feedURL])
  }

  @Test func nonURLSubmissionSearchesTheDirectoryWithoutTouchingLibrarySearch() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: "Host", artworkURL: nil,
        episodeCount: 12)
    ])
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: StubFollowing(),
      directory: directory)

    await model.submit("a show name")

    #expect(await directory.terms == ["a show name"])
    #expect(model.directoryResults.map(\.title) == ["Found"])
    #expect(model.phase == .empty)
  }

  @Test func anEmptyDirectorySearchSettlesAsResultsInsteadOfIdle() async {
    let directory = ControlledDirectory()
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: StubFollowing(),
      directory: directory)

    let search = Task { @MainActor in await model.searchDirectory(for: "missing") }
    await directory.waitForRequestCount(1)

    #expect(model.directoryPhase == .searching)

    await directory.complete(term: "missing", with: [])
    await search.value

    #expect(model.directoryPhase == .results([]))
    #expect(model.directoryPhase != .idle)
  }

  @Test func urlSubmissionStillUsesTheExplicitPreviewJourney() async {
    let directory = StubDirectory()
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: StubFollowing(),
      directory: directory)

    await model.submit(feedURL.absoluteString)

    #expect(model.phase == .preview(preview))
    #expect(await directory.terms.isEmpty)
  }

  @Test func directoryFollowValidatesTheFeedAndReportsItsOwnInlineFailure() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil,
        episodeCount: nil)
    ])
    let model = AddFeedModel(
      previews: stubbedPreviews(.failure(.notAFeed)), following: StubFollowing(),
      directory: directory)
    await model.submit("found")

    await model.followDirectoryResult(feedURL: feedURL)

    #expect(model.directoryFollowErrors[feedURL] == .notAFeed)
    #expect(model.phase == .empty)
  }

  @Test func olderDirectorySearchCannotOverwriteNewerResults() async {
    let directory = ControlledDirectory()
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: StubFollowing(),
      directory: directory)
    let firstResult = PodcastDirectoryResult(
      feedURL: URL(string: "https://feeds.example.test/first.xml")!, title: "First",
      author: nil, artworkURL: nil, episodeCount: nil)
    let secondResult = PodcastDirectoryResult(
      feedURL: URL(string: "https://feeds.example.test/second.xml")!, title: "Second",
      author: nil, artworkURL: nil, episodeCount: nil)

    let first = Task { @MainActor in await model.searchDirectory(for: "first") }
    await directory.waitForRequestCount(1)
    let second = Task { @MainActor in await model.searchDirectory(for: "second") }
    await directory.waitForRequestCount(2)

    await directory.complete(term: "second", with: [secondResult])
    await second.value
    await directory.complete(term: "first", with: [firstResult])
    await first.value

    #expect(model.directoryResults.map(\.title) == ["Second"])
    #expect(await directory.cancelledTerms == ["first"])
  }

  @Test func resetCancelsPreviewAndLateCompletionCannotRestoreIt() async {
    let previews = makeHeldPreviews()
    let model = AddFeedModel(previews: previews, following: StubFollowing())

    let loading = Task { @MainActor in
      await model.loadPreview(from: feedURL.absoluteString)
    }
    await previews.waitForRequestCount(1)

    model.reset()
    await previews.complete(url: feedURL, with: preview)
    await loading.value

    #expect(model.phase == .empty)
    #expect(previews.cancelledURLs == [feedURL])
  }

  @Test func resetCancelsDirectoryFollowAndLateCompletionCannotRestoreIt() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil,
        episodeCount: nil)
    ])
    let following = ControlledFollowing()
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following,
      directory: directory)
    await model.searchDirectory(for: "found")

    let follow = Task { @MainActor in
      await model.followDirectoryResult(feedURL: feedURL)
    }
    await following.waitUntilCalled()

    model.reset()
    await following.complete(with: 7)
    await follow.value

    #expect(model.phase == .empty)
    #expect(model.directoryFollowingURL == nil)
    #expect(model.isDirectoryResultFollowed(feedURL) == false)
    #expect(await following.observedCancellation)
  }

  @Test func clearingTheQueryReturnsToIdleAndKeepsWhatTheSheetAlreadyKnows() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil, episodeCount: nil)
    ])
    let following = StubFollowing()
    await following.setFollowedFeedURLs([])
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following,
      directory: directory)
    await model.loadFollowedFeeds()
    await model.submit("found")
    await model.followDirectoryResult(feedURL: feedURL)
    #expect(model.isIdle == false)

    model.clearQuery()

    #expect(model.isIdle)
    #expect(model.directoryResults.isEmpty)
    #expect(model.offersOPMLImport)
    #expect(model.isDirectoryResultFollowed(feedURL))
  }

  @Test func clearingTheQueryAfterAFailureReturnsToIdle() async {
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: StubFollowing())
    await model.submit("")
    #expect(model.failure == .invalidAddress)

    model.clearQuery()

    #expect(model.isIdle)
    #expect(model.failure == nil)
  }

  @Test func clearingTheQueryMidFollowLeavesLaterFollowsWorking() async {
    let directory = StubDirectory()
    await directory.setResults([
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: nil, artworkURL: nil, episodeCount: nil)
    ])
    let following = ControlledFollowing()
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: following,
      directory: directory)
    await model.searchDirectory(for: "found")
    let follow = Task { @MainActor in
      await model.followDirectoryResult(feedURL: feedURL)
    }
    await following.waitUntilCalled()

    model.clearQuery()
    await following.complete(with: 7)
    await follow.value
    #expect(model.directoryFollowingURL == nil)

    await model.searchDirectory(for: "found")
    await following.enqueueImmediateResult(8)
    await model.followDirectoryResult(feedURL: feedURL)
    #expect(model.isDirectoryResultFollowed(feedURL))
  }

  @Test func newerCredentialedPreviewSupersedesAnOlderCredentialedFollow() async throws {
    let firstURL = URL(string: "https://alice:one@feeds.example.test/first.xml")!
    let secondURL = URL(string: "https://bob:two@feeds.example.test/second.xml")!
    let firstCleanURL = URL(string: "https://feeds.example.test/first.xml")!
    let secondCleanURL = URL(string: "https://feeds.example.test/second.xml")!
    let firstPreview = FeedPreview(
      feedURL: firstCleanURL, title: "First", author: nil, artworkURL: nil, synopsis: nil,
      episodeCount: 1)
    let secondPreview = FeedPreview(
      feedURL: secondCleanURL, title: "Second", author: nil, artworkURL: nil, synopsis: nil,
      episodeCount: 2)
    let firstCredential = try PodcastFeedCredential.basic(username: "alice", password: "one")
    let secondCredential = try PodcastFeedCredential.basic(username: "bob", password: "two")
    let previews = makeHeldPreviews()
    let following = ControlledFollowing()
    let model = AddFeedModel(previews: previews, following: following)

    let firstLoad = Task { @MainActor in await model.loadPreview(from: firstURL.absoluteString) }
    await previews.waitForRequestCount(1)
    await previews.complete(url: firstCleanURL, with: firstPreview)
    await firstLoad.value

    let staleFollow = Task { @MainActor in await model.follow() }
    await following.waitUntilCalled()
    let secondLoad = Task { @MainActor in await model.loadPreview(from: secondURL.absoluteString) }
    await previews.waitForRequestCount(2)
    await previews.complete(url: secondCleanURL, with: secondPreview)
    await secondLoad.value
    await following.complete(with: 1)
    await staleFollow.value

    #expect(model.phase == .preview(secondPreview))
    #expect(await following.observedCancellation)
    await following.enqueueImmediateResult(2)
    await model.follow()
    #expect(model.phase == .followed(feedId: 2))
    #expect(await following.credentials == [firstCredential, secondCredential])
  }

  @Test func embeddedCredentialsAreExtractedBeforePreviewAndStoredOnlyAfterFollow() async throws {
    let previews = stubbedPreviews(.success(preview))
    let following = StubFollowing()
    let directory = StubDirectory()
    let model = AddFeedModel(previews: previews, following: following, directory: directory)

    await model.submit("https://listener:p%40ss@feeds.example.test/x.xml")

    #expect(model.didExtractCredentials)
    #expect(await directory.terms.isEmpty)
    #expect(previews.urls == [feedURL])
    let expected = try PodcastFeedCredential.basic(username: "listener", password: "p@ss")
    #expect(previews.credentials == [expected])

    await model.follow()
    #expect(await following.credentials == [expected])
  }

  @Test func overlappingPreviewsKeepTheirCredentialWithTheDisplayedPreview() async throws {
    let firstURL = URL(string: "https://alice:one@feeds.example.test/first.xml")!
    let secondURL = URL(string: "https://bob:two@feeds.example.test/second.xml")!
    let firstCleanURL = URL(string: "https://feeds.example.test/first.xml")!
    let secondCleanURL = URL(string: "https://feeds.example.test/second.xml")!
    let firstPreview = FeedPreview(
      feedURL: firstCleanURL, title: "First", author: nil, artworkURL: nil, synopsis: nil,
      episodeCount: 1)
    let secondPreview = FeedPreview(
      feedURL: secondCleanURL, title: "Second", author: nil, artworkURL: nil, synopsis: nil,
      episodeCount: 2)
    let firstCredential = try PodcastFeedCredential.basic(username: "alice", password: "one")
    let secondCredential = try PodcastFeedCredential.basic(username: "bob", password: "two")
    let previews = makeHeldPreviews()
    let following = StubFollowing()
    let model = AddFeedModel(previews: previews, following: following)

    let firstTask = Task { @MainActor in
      await model.loadPreview(from: firstURL.absoluteString)
    }
    await previews.waitForRequestCount(1)
    let secondTask = Task { @MainActor in
      await model.loadPreview(from: secondURL.absoluteString)
    }
    await previews.waitForRequestCount(2)

    await previews.complete(url: secondCleanURL, with: secondPreview)
    await secondTask.value
    await previews.complete(url: firstCleanURL, with: firstPreview)
    await firstTask.value

    #expect(model.phase == .preview(secondPreview))
    await model.follow()
    #expect(await following.previews == [secondPreview])
    #expect(await following.credentials == [secondCredential])
    #expect(previews.credentials == [firstCredential, secondCredential])
  }

  @Test func equalPreviewsFromDifferentSourcesCannotCarryACredentialAcrossSources() async throws {
    let firstURL = URL(string: "https://alice:one@feeds.example.test/first.xml")!
    let secondURL = URL(string: "https://bob:two@feeds.example.test/second.xml")!
    let firstCleanURL = URL(string: "https://feeds.example.test/first.xml")!
    let secondCleanURL = URL(string: "https://feeds.example.test/second.xml")!
    let firstPreview = FeedPreview(
      feedURL: firstCleanURL, title: "Same", author: nil, artworkURL: nil, synopsis: nil,
      episodeCount: 1)
    let secondPreview = FeedPreview(
      feedURL: firstCleanURL, title: "Same", author: nil, artworkURL: nil, synopsis: nil,
      episodeCount: 1)
    let firstCredential = try PodcastFeedCredential.basic(username: "alice", password: "one")
    let secondCredential = try PodcastFeedCredential.basic(username: "bob", password: "two")
    let previews = makeHeldPreviews()
    let following = StubFollowing()
    let model = AddFeedModel(previews: previews, following: following)

    #expect(firstPreview == secondPreview)
    #expect(firstCleanURL != secondCleanURL)

    let firstTask = Task { @MainActor in
      await model.loadPreview(from: firstURL.absoluteString)
    }
    await previews.waitForRequestCount(1)
    let secondTask = Task { @MainActor in
      await model.loadPreview(from: secondURL.absoluteString)
    }
    await previews.waitForRequestCount(2)

    await previews.complete(url: secondCleanURL, with: secondPreview)
    await secondTask.value
    await previews.complete(url: firstCleanURL, with: firstPreview)
    await firstTask.value

    #expect(model.phase == .preview(secondPreview))
    await model.follow()

    #expect(await following.previews.isEmpty)
    #expect(await following.credentials.isEmpty)
    #expect(previews.credentials == [firstCredential, secondCredential])
  }

  @Test func incompleteOrInvalidEmbeddedCredentialsNeverBecomeADirectoryQuery() async {
    let directory = StubDirectory()
    let model = AddFeedModel(
      previews: stubbedPreviews(.success(preview)), following: StubFollowing(),
      directory: directory)

    await model.submit("https://listener@feeds.example.test/x.xml")

    #expect(model.phase == .failed(.invalidAddress))
    #expect(await directory.terms.isEmpty)
  }

  @Test func productionFollowerPersistsCredentialAgainstTheCleanFeedIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let credentialStore = InMemoryFeedCredentialStore()
    let follower = RSSFeedFollowing(store: store, credentialStore: credentialStore)
    let credential = try PodcastFeedCredential.basic(username: "listener", password: "secret")

    let id = try await follower.follow(
      preview, credential: credential, subscribedAt: Date())

    #expect(try await store.fetchFeed(feedId: id)?.feedURL == feedURL.absoluteString)
    #expect(try credentialStore.load(forFeedID: id) == credential)
    #expect(try await store.fetchFeed(feedId: id)?.feedURL.contains("listener") == false)
    #expect(try await store.recoveryRequired(feedID: id) == false)
  }

  @Test func credentialStorageFailureLeavesTheSubscriptionVisibleForRecovery() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let follower = RSSFeedFollowing(
      store: store, credentialStore: failingSaveCredentialStore())
    let credential = try PodcastFeedCredential.basic(
      username: "fixture-user", password: "fixture-password")

    await #expect(throws: TestCredentialStoreError.self) {
      try await follower.follow(
        preview, credential: credential, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    let feeds = try await store.fetchFeeds()
    #expect(feeds.count == 1)
    #expect(feeds.first?.title == preview.title)
    let feedID = try #require(feeds.first?.id)
    #expect(try await store.recoveryRequired(feedID: feedID))
  }

  @Test func recoveryMarkerExistsBeforeCredentialSaveAndClearsAfterSuccess() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let credentialStore = FakeFeedCredentialStoring()
    let markerWasPresentDuringSave = Locked(false)
    credentialStore.setSaveHook { feedID in
      let markerExists = try database.read { db in
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS (SELECT 1 FROM rssFeedRecovery WHERE feedId = ?)",
          arguments: [feedID]) ?? false
      }
      markerWasPresentDuringSave.value = markerExists
    }
    let follower = RSSFeedFollowing(store: store, credentialStore: credentialStore)
    let credential = try PodcastFeedCredential.basic(
      username: "fixture-user", password: "fixture-password")

    let feedID = try await follower.follow(
      preview, credential: credential, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(markerWasPresentDuringSave.value)
    #expect(try await store.recoveryRequired(feedID: feedID) == false)
  }

  @Test func cancellationAfterCredentialSaveLeavesARecoverableFeed() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let follower = RSSFeedFollowing(store: store, credentialStore: cancellingCredentialStore())
    let credential = try PodcastFeedCredential.basic(
      username: "fixture-user", password: "fixture-password")

    let follow = Task {
      try await follower.follow(
        preview, credential: credential, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
    await #expect(throws: CancellationError.self) { try await follow.value }

    let feedID = try #require(try await store.fetchFeeds().first?.id)
    #expect(try await store.recoveryRequired(feedID: feedID))
  }
}

private struct TestCredentialStoreError: Error {}

private func stubbedPreviews(
  _ result: Result<FeedPreview, FeedPreviewError>
) -> FakeFeedPreviewProviding {
  FakeFeedPreviewProviding(result: result)
}

/// Parks every request until the test completes it by URL.
private func makeHeldPreviews() -> FakeFeedPreviewProviding {
  let previews = FakeFeedPreviewProviding()
  previews.hold()
  return previews
}

private func failingSaveCredentialStore() -> FakeFeedCredentialStoring {
  let store = FakeFeedCredentialStoring()
  store.stubSaveFailure(TestCredentialStoreError())
  return store
}

/// Cancels the task that is saving, as a follow cancelled mid-flight would.
private func cancellingCredentialStore() -> FakeFeedCredentialStoring {
  let store = FakeFeedCredentialStoring()
  store.setSaveHook { _ in withUnsafeCurrentTask { $0?.cancel() } }
  return store
}

private actor StubFollowing: NativeFeedFollowing {
  private(set) var calls = 0
  private(set) var previews: [FeedPreview] = []
  private(set) var credentials: [PodcastFeedCredential?] = []
  private var result: Result<Int64, FollowFeedError> = .success(1)
  private var followed: [URL] = []

  func followedFeedURLs() async throws -> [URL] { followed }

  func follow(_ preview: FeedPreview, subscribedAt: Date) async throws -> Int64 {
    try await follow(preview, credential: nil, subscribedAt: subscribedAt)
  }

  func follow(
    _ preview: FeedPreview, credential: PodcastFeedCredential?, subscribedAt: Date
  ) async throws -> Int64 {
    calls += 1
    previews.append(preview)
    credentials.append(credential)
    return try result.get()
  }

  func setResult(_ result: Result<Int64, FollowFeedError>) { self.result = result }
  func setFollowedFeedURLs(_ urls: [URL]) { followed = urls }
}

private actor ControlledFollowing: NativeFeedFollowing {
  // Stays parked through task cancellation: a real follow runs to completion once started.
  nonisolated let gate = TestGate<Result<Int64, any Error>>(
    label: "ControlledFollowing follow", ignoresCancellation: true)
  private var immediateResults: [Int64] = []
  private(set) var credentials: [PodcastFeedCredential?] = []
  private(set) var observedCancellation = false

  init() { gate.hold() }

  func follow(_ preview: FeedPreview, subscribedAt: Date) async throws -> Int64 {
    try await follow(preview, credential: nil, subscribedAt: subscribedAt)
  }

  func follow(
    _ preview: FeedPreview, credential: PodcastFeedCredential?, subscribedAt: Date
  ) async throws -> Int64 {
    credentials.append(credential)
    if immediateResults.isEmpty == false { return immediateResults.removeFirst() }
    let feedID = try await gate.pass(otherwise: { .failure(CancellationError()) }).get()
    observedCancellation = Task.isCancelled
    return feedID
  }

  func waitUntilCalled() async {
    await gate.waitUntilParked()
  }

  func complete(with feedID: Int64) {
    gate.releaseNext(.success(feedID))
  }

  func enqueueImmediateResult(_ feedID: Int64) { immediateResults.append(feedID) }
}

private actor ControlledDirectory: PodcastDirectorySearching {
  private typealias SearchGate = TestGate<Result<[PodcastDirectoryResult], any Error>>
  private var gates: [String: SearchGate] = [:]
  private let requests = CallRecorder<String>(label: "ControlledDirectory searches")
  private(set) var cancelledTerms: [String] = []

  func search(term: String) async throws -> [PodcastDirectoryResult] {
    let gate = gate(for: term)
    gate.hold()
    requests.record(term)
    let results = try await gate.pass(otherwise: { .failure(CancellationError()) }).get()
    if Task.isCancelled { cancelledTerms.append(term) }
    return results
  }

  func waitForRequestCount(_ count: Int) async {
    await requests.waitUntil(count: count)
  }

  /// Waits for the search to park first: it records its request just before it parks.
  func complete(term: String, with results: [PodcastDirectoryResult]) async {
    let gate = gate(for: term)
    await gate.waitUntilParked()
    gate.releaseNext(.success(results))
  }

  // Stays parked through task cancellation: a real search runs to completion once started.
  private func gate(for term: String) -> SearchGate {
    if let gate = gates[term] { return gate }
    let gate = SearchGate(
      label: "ControlledDirectory search \(term)", ignoresCancellation: true)
    gates[term] = gate
    return gate
  }
}

private actor StubDirectory: PodcastDirectorySearching {
  private(set) var terms: [String] = []
  private var results: [PodcastDirectoryResult] = []

  func search(term: String) async throws -> [PodcastDirectoryResult] {
    terms.append(term)
    return results
  }

  func setResults(_ results: [PodcastDirectoryResult]) { self.results = results }
}
