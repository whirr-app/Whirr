import Foundation
import PodcastFeeds
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("Add feed model directory detail", .timeLimit(.minutes(1)))
struct AddFeedModelDirectoryDetailTests {
  private let feedURL = URL(string: "https://feeds.example.test/x.xml")!
  private let otherURL = URL(string: "https://feeds.example.test/y.xml")!
  private let publishedAt = FeedValueParsing.pubDate("Wed, 03 Sep 2025 10:00:00 +0000")

  private var preview: FeedPreview {
    FeedPreview(
      feedURL: feedURL, title: "A Feed", author: "An Author", artworkURL: nil,
      synopsis: "<p>About <b>the</b> show</p>", episodeCount: 42,
      recentEpisodes: [
        FeedPreviewEpisode(
          title: "Newest", publishedAt: publishedAt, duration: 3723,
          synopsis: "<p>Notes &amp; links</p><p>More</p>"),
        FeedPreviewEpisode(title: nil, publishedAt: nil, duration: nil, synopsis: nil),
      ])
  }

  private func results() -> [PodcastDirectoryResult] {
    [
      PodcastDirectoryResult(
        feedURL: feedURL, title: "Found", author: "Host",
        artworkURL: URL(string: "https://images.example.test/100.jpg"),
        largeArtworkURL: URL(string: "https://images.example.test/600.jpg"), episodeCount: 40),
      PodcastDirectoryResult(
        feedURL: otherURL, title: "Also found", author: nil, artworkURL: nil, episodeCount: nil),
    ]
  }

  private func searchedModel(
    previews: any FeedPreviewProviding, following: any NativeFeedFollowing = DetailStubFollowing()
  ) async -> AddFeedModel {
    let model = AddFeedModel(
      previews: previews, following: following, directory: DetailStubDirectory(results: results()))
    await model.submit("found")
    return model
  }

  @Test func theHeaderComesFromTheDirectoryResultBeforeTheFeedArrives() async {
    let previews = FakeFeedPreviewProviding()
    previews.hold()
    let model = await searchedModel(previews: previews)

    let opening = Task { @MainActor in await model.openDirectoryDetail(feedURL: feedURL) }
    await previews.waitForRequestCount(1)

    let detail = model.directoryDetail(for: feedURL)
    #expect(detail?.title == "Found")
    #expect(detail?.author == "Host")
    #expect(detail?.artworkURL == URL(string: "https://images.example.test/100.jpg"))
    #expect(detail?.largeArtworkURL == URL(string: "https://images.example.test/600.jpg"))
    #expect(detail?.heroArtworkURL == results().first?.heroArtworkURL)
    #expect(detail?.episodeCountText == "40 episodes")
    #expect(detail?.content == .loading)

    await previews.complete(url: feedURL, with: preview)
    await opening.value
  }

  @Test func aLoadedDetailShowsPlainTextNotesAndTheFeedsCount() async {
    let model = await searchedModel(previews: FakeFeedPreviewProviding(result: .success(preview)))

    await model.openDirectoryDetail(feedURL: feedURL)

    let detail = model.directoryDetail(for: feedURL)
    #expect(detail?.episodeCountText == "42 episodes")
    guard case .loaded(let description, let episodes) = detail?.content else {
      Issue.record("expected loaded content, got \(String(describing: detail?.content))")
      return
    }
    #expect(description == "About the show")
    #expect(episodes.count == 2)
    #expect(episodes[0].title == "Newest")
    #expect(episodes[0].metadata == "Sep 3, 2025 · 1 hr 2 min")
    #expect(episodes[0].notes == "Notes & links\n\nMore")
    #expect(episodes[1].title == PodcastCopy.untitledEpisode)
    #expect(episodes[1].metadata == nil)
    #expect(episodes[1].notes == nil)
    #expect(episodes[0].id != episodes[1].id)
  }

  @Test func aFailedDetailReportsItAndOpeningAgainRetries() async {
    let previews = FakeFeedPreviewProviding(result: .failure(.unreachable))
    let model = await searchedModel(previews: previews)

    await model.openDirectoryDetail(feedURL: feedURL)
    #expect(
      model.directoryDetail(for: feedURL)?.content
        == .failed(message: AddFeedSheetPresentation.directoryFollowMessage(for: .unreachable)))

    previews.stubResult(.success(preview))
    await model.openDirectoryDetail(feedURL: feedURL)
    guard case .loaded = model.directoryDetail(for: feedURL)?.content else {
      Issue.record("retry did not load")
      return
    }
    #expect(previews.requestCount == 2)
  }

  @Test func reopeningALoadedDetailDoesNotFetchAgain() async {
    let previews = FakeFeedPreviewProviding(result: .success(preview))
    let model = await searchedModel(previews: previews)

    await model.openDirectoryDetail(feedURL: feedURL)
    await model.openDirectoryDetail(feedURL: feedURL)

    #expect(previews.urls == [feedURL])
  }

  @Test func closingCancelsTheLoadAndALateResultCannotRestoreIt() async {
    let previews = FakeFeedPreviewProviding()
    previews.hold()
    let model = await searchedModel(previews: previews)

    let opening = Task { @MainActor in await model.openDirectoryDetail(feedURL: feedURL) }
    await previews.waitForRequestCount(1)
    model.closeDirectoryDetail()
    await previews.complete(url: feedURL, with: preview)
    await opening.value

    #expect(model.directoryDetailPhase == .idle)
    #expect(previews.cancelledURLs == [feedURL])
  }

  @Test func openingAnotherResultIgnoresTheEarlierLoad() async {
    let previews = FakeFeedPreviewProviding()
    previews.hold()
    let model = await searchedModel(previews: previews)

    let first = Task { @MainActor in await model.openDirectoryDetail(feedURL: feedURL) }
    await previews.waitForRequestCount(1)
    let second = Task { @MainActor in await model.openDirectoryDetail(feedURL: otherURL) }
    await previews.waitForRequestCount(2)
    await previews.complete(url: feedURL, with: preview)
    await first.value

    #expect(model.directoryDetailPhase == .loading(otherURL))

    await previews.complete(url: otherURL, with: preview)
    await second.value
    #expect(model.directoryDetailPhase == .loaded(otherURL, preview))
  }

  @Test func onlyADisplayedResultCanBeOpened() async {
    let previews = FakeFeedPreviewProviding(result: .success(preview))
    let model = await searchedModel(previews: previews)
    let stranger = URL(string: "https://feeds.example.test/stranger.xml")!

    await model.openDirectoryDetail(feedURL: stranger)

    #expect(model.directoryDetailPhase == .idle)
    #expect(model.directoryDetail(for: stranger) == nil)
    #expect(previews.urls.isEmpty)
  }

  @Test func followingFromALoadedDetailReusesItsPreview() async {
    let previews = FakeFeedPreviewProviding(result: .success(preview))
    let following = DetailStubFollowing()
    let model = await searchedModel(previews: previews, following: following)
    await model.openDirectoryDetail(feedURL: feedURL)

    await model.followDirectoryResult(feedURL: feedURL)

    #expect(previews.urls == [feedURL])
    #expect(await following.previews == [preview])
    #expect(model.isDirectoryResultFollowed(feedURL))
    #expect(model.directoryDetailPhase == .loaded(feedURL, preview))
  }

  @Test func aRowFollowIsNotCancelledByOpeningADetail() async {
    let previews = FakeFeedPreviewProviding()
    previews.hold()
    let following = DetailStubFollowing()
    let model = await searchedModel(previews: previews, following: following)

    let follow = Task { @MainActor in await model.followDirectoryResult(feedURL: otherURL) }
    await previews.waitForRequestCount(1)
    let opening = Task { @MainActor in await model.openDirectoryDetail(feedURL: feedURL) }
    await previews.waitForRequestCount(2)

    await previews.complete(url: otherURL, with: preview)
    await follow.value
    #expect(model.isDirectoryResultFollowed(otherURL))
    #expect(model.directoryDetailPhase == .loading(feedURL))

    await previews.complete(url: feedURL, with: preview)
    await opening.value
    #expect(model.directoryDetailPhase == .loaded(feedURL, preview))
  }

  @Test func aNewSearchOrResetClosesTheDetail() async {
    let model = await searchedModel(previews: FakeFeedPreviewProviding(result: .success(preview)))
    await model.openDirectoryDetail(feedURL: feedURL)

    await model.submit("something else")
    #expect(model.directoryDetailPhase == .idle)

    await model.submit("found")
    await model.openDirectoryDetail(feedURL: feedURL)
    model.reset()
    #expect(model.directoryDetailPhase == .idle)
  }
}

private actor DetailStubDirectory: PodcastDirectorySearching {
  let results: [PodcastDirectoryResult]
  init(results: [PodcastDirectoryResult]) { self.results = results }
  func search(term _: String) async throws -> [PodcastDirectoryResult] { results }
}

private actor DetailStubFollowing: NativeFeedFollowing {
  private(set) var previews: [FeedPreview] = []

  func followedFeedURLs() async throws -> [URL] { [] }

  func follow(_ preview: FeedPreview, subscribedAt: Date) async throws -> Int64 {
    try await follow(preview, credential: nil, subscribedAt: subscribedAt)
  }

  func follow(
    _ preview: FeedPreview, credential _: PodcastFeedCredential?, subscribedAt _: Date
  ) async throws -> Int64 {
    previews.append(preview)
    return Int64(previews.count)
  }
}
