import Persistence
import Testing

@testable import AppModel

private func makeItem(
  title: String = "Carl's Doomsday Scenario",
  author: String? = "Matt Dinniman",
  category: ItemMediaCategory = .audiobook,
  durationSeconds: Double? = 1000,
  progressSeconds: Double = 250,
  ebookProgress: Double = 0,
  isFinished: Bool = false,
  episodeID: String? = nil,
  episodeTitle: String? = nil
) -> HomeItem {
  HomeItem(
    serverItemId: "li_1",
    title: title,
    author: author,
    category: category,
    durationSeconds: durationSeconds,
    progressSeconds: progressSeconds,
    ebookProgress: ebookProgress,
    isFinished: isFinished,
    addedAt: nil,
    isDownloaded: false,
    episodeID: episodeID,
    episodeTitle: episodeTitle)
}

@Suite struct HomeCardTextTests {
  @Test("a book reads title then author, with its listening progress as the bar")
  func bookCard() {
    let text = HomeCardText(item: makeItem(), showsProgress: true)
    #expect(text.title == "Carl's Doomsday Scenario")
    #expect(text.subtitle == "Matt Dinniman")
    #expect(text.badgeCategory == .audiobook)
    #expect(text.progressFraction == 0.25)
  }

  @Test("an empty or missing author yields no second line rather than a blank one")
  func emptyAuthorHasNoSubtitle() {
    #expect(HomeCardText(item: makeItem(author: nil), showsProgress: false).subtitle == nil)
    #expect(HomeCardText(item: makeItem(author: ""), showsProgress: false).subtitle == nil)
  }

  @Test("a podcast continuation leads with the episode and names its show second")
  func episodeContinuation() {
    let item = makeItem(
      title: "The Show", author: "Host", category: .podcast, episodeID: "ep_1",
      episodeTitle: "Episode One")
    let text = HomeCardText(item: item, showsProgress: true)
    #expect(text.title == "Episode One")
    #expect(text.subtitle == "The Show")

    let untitled = HomeCardText(
      item: makeItem(category: .podcast, episodeID: "ep_1"), showsProgress: true)
    #expect(untitled.title == PodcastCopy.untitledEpisode)
  }

  @Test("without progress a podcast row is its show, not an episode")
  func podcastWithoutProgressIsTheShow() {
    let item = makeItem(
      title: "The Show", author: "Host", category: .podcast, episodeID: "ep_1",
      episodeTitle: "Episode One")
    let text = HomeCardText(item: item, showsProgress: false)
    #expect(text.title == "The Show")
    #expect(text.subtitle == "Host")
  }

  @Test("ebook progress swaps both the badge and the bar's source")
  func ebookProgress() {
    let text = HomeCardText(
      item: makeItem(ebookProgress: 0.6), showsProgress: true, usesEbookProgress: true)
    #expect(text.badgeCategory == .ebook)
    #expect(text.progressFraction == 0.6)
  }

  @Test("a displayed position replaces the persisted listening progress, not reading progress")
  func displayedPositionReplacesListeningProgress() {
    #expect(
      HomeCardText(item: makeItem(), showsProgress: true, progressSeconds: 500).progressFraction
        == 0.5)
    #expect(
      HomeCardText(
        item: makeItem(ebookProgress: 0.6), showsProgress: true, usesEbookProgress: true,
        progressSeconds: 500
      ).progressFraction == 0.6)
  }

  @Test("a finished item, or a surface without progress, draws no bar")
  func barSuppression() {
    #expect(
      HomeCardText(item: makeItem(isFinished: true), showsProgress: true).progressFraction == nil)
    #expect(HomeCardText(item: makeItem(), showsProgress: false).progressFraction == nil)
    #expect(
      HomeCardText(item: makeItem(durationSeconds: nil), showsProgress: true).progressFraction
        == nil)
  }
}
