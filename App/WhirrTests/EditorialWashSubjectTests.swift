import ABSApi
import Foundation
import Persistence
import Testing

@testable import Whirr

/// A subject is what a screen hands the wash provider. The one thing it has to get right is
/// that a device-owned podcast's subject carries the feed's artwork source, because the
/// coordinator cannot colour an `rss:` id from the id alone.
@Suite("Editorial wash subject")
struct EditorialWashSubjectTests {
  private static let artworkURL = URL(string: "https://images.example.com/show.jpg")!
  private static let feedURL = URL(string: "https://example.com/show.xml")!
  private static let rssItemID = PodcastSourceIdentity.rss(feedId: 7)!.itemId

  @Test("a device show's summary carries its feed artwork; a server item carries none")
  func itemSummarySubjects() {
    let rss = ItemSummary(
      serverItemId: Self.rssItemID, mediaKind: "podcast", title: "Show", author: nil,
      durationSeconds: nil, category: .podcast, artworkURL: Self.artworkURL,
      artworkFeedURL: Self.feedURL)
    let server = ItemSummary(
      serverItemId: "li_1", mediaKind: "book", title: "Book", author: nil, durationSeconds: nil)

    #expect(rss.washSubject.itemID == Self.rssItemID)
    #expect(rss.washSubject.artworkSource == rss.providerArtworkSource)
    #expect(rss.washSubject.artworkSource != nil)
    #expect(server.washSubject == .audiobookshelf("li_1", revision: .unversioned))
  }

  @Test("an episode is keyed by its show and carries the show's feed artwork")
  func episodeSubject() {
    let episode = Self.episode(id: "ep-1")

    #expect(episode.washSubject.itemID == Self.rssItemID)
    #expect(episode.washSubject.artworkSource == episode.providerArtworkSource)
    #expect(episode.washSubject.artworkSource != nil)
  }

  @Test("a saved entry resolves to the same subject as the episode or item it saved")
  func savedEntrySubjects() {
    let episode = Self.episode(id: "ep-1")
    let savedEpisode = SavedShelfItem(
      identity: .rssEpisode(itemID: episode.itemID, episodeID: episode.episodeID),
      savedAt: Date(), subjectTitle: episode.title, contextTitle: episode.showTitle,
      category: .podcast, itemSummary: nil, episode: episode, isUnavailable: false)
    let tombstone = SavedShelfItem(
      identity: .rssEpisode(itemID: episode.itemID, episodeID: episode.episodeID),
      savedAt: Date(), subjectTitle: episode.title, contextTitle: episode.showTitle,
      category: .podcast, itemSummary: nil, episode: episode, isUnavailable: true)

    #expect(savedEpisode.washSubject == episode.washSubject)
    #expect(tombstone.washSubject == episode.washSubject)
    #expect(savedEpisode.washSubject.itemID == savedEpisode.identity.itemID)
  }

  @Test("a downloaded feed is keyed by its canonical rss id with its own artwork")
  func downloadedFeedSubject() {
    let feed = RSSDownloadedFeed(
      id: 7, title: "Show", author: "Host", sourceURL: Self.feedURL, episodes: [],
      artworkURL: Self.artworkURL)
    let bare = RSSDownloadedFeed(id: 7, title: "Show", sourceURL: Self.feedURL, episodes: [])

    #expect(feed.washSubject.itemID == Self.rssItemID)
    #expect(feed.washSubject.artworkSource == feed.providerArtworkSource)
    #expect(feed.washSubject.artworkSource != nil)
    #expect(
      bare.washSubject
        == EditorialWashSubject(
          itemID: Self.rssItemID, artworkSource: nil, artworkRevision: .unversioned))
  }

  @Test("a page of subjects folds one show's many episodes into one source entry")
  func sourcesByIDFoldsDuplicates() {
    let subjects =
      [Self.episode(id: "ep-1"), Self.episode(id: "ep-2")].map(\.washSubject)
      + [EditorialWashSubject.audiobookshelf("li_1", revision: .unversioned)]

    #expect(subjects.itemIDs == [Self.rssItemID, Self.rssItemID, "li_1"])
    #expect(subjects.sourcesByID.count == 1)
    #expect(subjects.sourcesByID[Self.rssItemID] == subjects[0].artworkSource)
  }

  @Test("Home's shelf preload and the Podcasts list keep one subject per show, with its source")
  func shelfAndListSubjects() {
    let episodes = [Self.episode(id: "ep-1"), Self.episode(id: "ep-2")]

    let shelf = HomeArtworkPrefetching.washSubjects(for: .podcastEpisodes(episodes))
    #expect(shelf.itemIDs == HomeArtworkPrefetching.orderedIDs(for: .podcastEpisodes(episodes)))
    #expect(shelf.sourcesByID == HomeArtworkPrefetching.sourcesByID(for: .podcastEpisodes(episodes)))

    let list = PodcastsViewPresentation.latestEpisodeWashSubjects(for: .all, episodes: episodes)
    #expect(list == [episodes[0].washSubject])
    #expect(list.itemIDs == PodcastsViewPresentation.latestEpisodeWashItemIDs(for: .all, episodes: episodes))
    #expect(PodcastsViewPresentation.latestEpisodeWashSubjects(for: .yourShows, episodes: episodes).isEmpty)
  }

  private static func episode(id: String) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: rssItemID, showTitle: "Show", showAuthor: "Host", episodeID: id, title: "Episode \(id)",
      subtitle: nil, publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 60,
      artworkURL: artworkURL, artworkFeedURL: feedURL)
  }
}
