import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

struct HomeCardSelectionTests {
  @Test("Continue Listening has one canonical playback target")
  func continueListeningHasCanonicalPlaybackTarget() {
    let item = Self.item(category: .podcast, episodeID: "episode")

    #expect(
      ContinueListeningCardSelection.target(for: item)
        == .init(itemID: "item", episodeID: "episode"))
  }

  @Test("ordinary Home cards open item detail")
  func ordinaryCardOpensItemDetail() {
    let item = Self.item(category: .audiobook)

    #expect(HomeCardSelection.destination(for: item, in: .recentlyAdded) == .item(item.itemSummary))
  }

  @Test("Continue Listening audiobooks resume playback")
  func audiobookContinuationResumesPlayback() {
    let item = Self.item(category: .audiobook)

    #expect(
      HomeCardSelection.destination(for: item, in: .continueListening)
        == .resume(itemID: "item", episodeID: nil))
  }

  @Test("Continue Listening podcast episodes resume playback")
  func podcastContinuationResumesPlayback() {
    let item = Self.item(category: .podcast, episodeID: "episode")

    #expect(
      HomeCardSelection.destination(for: item, in: .continueListening)
        == .resume(itemID: "item", episodeID: "episode"))
  }

  @Test("Continue Listening audiobooks can open details instead of playing")
  func audiobookContinuationOpensDetailsWhenImmediatePlaybackIsOff() {
    let item = Self.item(category: .audiobook)

    #expect(
      HomeCardSelection.destination(
        for: item, in: .continueListening, opensContinueCardImmediately: false)
        == .item(item.itemSummary))
  }

  @Test("a Continue Listening podcast without an episode opens its show when not playing")
  func podcastContinuationWithoutEpisodeOpensShowWhenImmediatePlaybackIsOff() {
    let item = Self.item(category: .podcast)

    #expect(
      HomeCardSelection.destination(
        for: item, in: .continueListening, opensContinueCardImmediately: false)
        == .item(item.itemSummary))
  }

  @Test("Continue Listening podcast episodes can open their sheet instead of playing")
  func podcastContinuationOpensEpisodeWhenImmediatePlaybackIsOff() {
    let item = Self.item(category: .podcast, episodeID: "episode")

    #expect(
      HomeCardSelection.destination(
        for: item, in: .continueListening, opensContinueCardImmediately: false)
        == .episode(itemID: "item", episodeID: "episode"))
  }

  @Test("Continue Reading ebooks open the reader")
  func ebookContinuationOpensReader() {
    let item = Self.item(category: .ebook)

    #expect(
      HomeCardSelection.destination(for: item, in: .continueReading)
        == .read(itemID: "item", title: "Title", category: .ebook))
  }

  @Test("Continue Reading ebooks open details instead of the reader when the preference is off")
  func ebookContinuationOpensDetailsWhenImmediateOpeningIsOff() {
    let item = Self.item(category: .ebook)

    #expect(
      HomeCardSelection.destination(
        for: item, in: .continueReading, opensContinueCardImmediately: false)
        == .item(item.itemSummary))
  }

  @Test("Downloaded podcast cards open the show with its Downloaded filter")
  func downloadedPodcastOpensFilteredShow() {
    let item = Self.item(category: .podcast, episodeID: "episode")

    #expect(
      HomeCardSelection.destination(for: item, in: .downloaded)
        == .downloadedPodcast(item.itemSummary))
  }

  private static func item(
    category: ItemMediaCategory,
    episodeID: String? = nil
  ) -> HomeItem {
    HomeItem(
      serverItemId: "item", title: "Title", author: "Author", category: category,
      durationSeconds: 3_600, progressSeconds: 600, isFinished: false,
      addedAt: Date(timeIntervalSince1970: 1), isDownloaded: false,
      episodeID: episodeID, episodeTitle: episodeID == nil ? nil : "Episode")
  }
}
