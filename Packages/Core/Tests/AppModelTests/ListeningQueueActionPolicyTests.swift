import Persistence
import Testing

@testable import AppModel

/// The one player-aware availability policy every item surface consults. Each case is a line of
/// the product contract's "Queue availability in item menus" section.
@Suite("Listening queue action policy")
struct ListeningQueueActionPolicyTests {
  @Test("no Now Playing identity offers no queue actions at all")
  func noNowPlayingIdentityOffersNoQueueActions() {
    let availability = ListeningQueueActionPolicy.availability(
      itemID: "book-1", episodeID: nil, category: .audiobook, nowPlaying: nil)

    #expect(availability == .none)
    #expect(availability.offersPlayNext == false)
    #expect(availability.offersAddToUpNext == false)
    #expect(availability.isEmpty)
  }

  @Test("a different Now Playing identity offers both ends of the queue")
  func aDifferentNowPlayingIdentityOffersBothQueueActions() {
    let book = ListeningQueueActionPolicy.availability(
      itemID: "book-1", episodeID: nil, category: .audiobook,
      nowPlaying: .audiobook(itemID: "book-2"))
    let episode = ListeningQueueActionPolicy.availability(
      itemID: "show-1", episodeID: "ep-1", category: .podcast,
      nowPlaying: .audiobook(itemID: "book-2"))

    #expect(book == .both)
    #expect(episode == .both)
    #expect(book.actions == [.playNext, .addToUpNext])
  }

  @Test("the current Now Playing identity offers neither action for itself")
  func theNowPlayingIdentityItselfOffersNeither() {
    let book = ListeningQueueActionPolicy.availability(
      itemID: "book-1", episodeID: nil, category: .audiobook,
      nowPlaying: .audiobook(itemID: "book-1"))
    let episode = ListeningQueueActionPolicy.availability(
      itemID: "show-1", episodeID: "ep-1", category: .podcast,
      nowPlaying: .podcastEpisode(itemID: "show-1", episodeID: "ep-1"))

    #expect(book == .none)
    #expect(episode == .none)
  }

  /// A sibling episode of the show that is playing is a different identity, so it keeps both.
  @Test("a sibling episode of the playing show still offers both actions")
  func aSiblingEpisodeOfThePlayingShowStillOffersBoth() {
    let availability = ListeningQueueActionPolicy.availability(
      itemID: "show-1", episodeID: "ep-2", category: .podcast,
      nowPlaying: .podcastEpisode(itemID: "show-1", episodeID: "ep-1"))

    #expect(availability == .both)
  }

  @Test("native RSS current and sibling episodes use the third queue identity")
  func nativeRSSAvailabilityUsesTheThirdIdentity() throws {
    let current = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "ep-1"))
    #expect(
      ListeningQueueActionPolicy.identity(
        itemID: "rss:7", episodeID: "ep-1", category: .podcast) == current)
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: "rss:7", episodeID: "ep-1", category: .podcast,
        nowPlaying: current) == .none)
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: "rss:7", episodeID: "ep-2", category: .podcast,
        nowPlaying: current) == .both)
  }

  @Test("a row already in the queue offers neither action")
  func aRowAlreadyInTheQueueOffersNeither() {
    let availability = ListeningQueueActionPolicy.availability(
      itemID: "book-1", episodeID: nil, category: .audiobook,
      nowPlaying: .audiobook(itemID: "book-2"), isAlreadyQueued: true)

    #expect(availability == .none)
  }

  @Test("an ebook is never queueable, whatever is playing")
  func anEbookIsNeverQueueable() {
    #expect(
      ListeningQueueActionPolicy.identity(itemID: "book-1", episodeID: nil, category: .ebook)
        == nil)
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: "book-1", episodeID: nil, category: .ebook,
        nowPlaying: .audiobook(itemID: "book-2")) == .none)
  }

  /// A podcast show row names no episode, so there is nothing the queue could hold. The store
  /// would reject the whole-item identity outright (`episodeIdentityRequired`).
  @Test("a podcast show row without an episode is not queueable")
  func aPodcastShowRowWithoutAnEpisodeIsNotQueueable() {
    #expect(
      ListeningQueueActionPolicy.identity(itemID: "show-1", episodeID: nil, category: .podcast)
        == nil)
    #expect(
      ListeningQueueActionPolicy.availability(
        itemID: "show-1", episodeID: nil, category: .podcast,
        nowPlaying: .audiobook(itemID: "book-1")) == .none)
  }

  @Test("an audiobook carrying an episode id is not queueable")
  func anAudiobookCarryingAnEpisodeIdIsNotQueueable() {
    #expect(
      ListeningQueueActionPolicy.identity(
        itemID: "book-1", episodeID: "ep-1", category: .audiobook) == nil)
  }

  @Test("a queueable row resolves to the identity the store accepts")
  func aQueueableRowResolvesToTheStoresIdentity() {
    #expect(
      ListeningQueueActionPolicy.identity(itemID: "book-1", episodeID: nil, category: .audiobook)
        == .audiobook(itemID: "book-1"))
    #expect(
      ListeningQueueActionPolicy.identity(itemID: "mixed-book", episodeID: nil, category: .audiobook)
        == .audiobook(itemID: "mixed-book"))
    #expect(
      ListeningQueueActionPolicy.identity(
        itemID: "show-1", episodeID: "ep-1", category: .podcast)
        == .podcastEpisode(itemID: "show-1", episodeID: "ep-1"))
  }

  /// The canonical podcast episode inventory is filtered by the same policy every other surface
  /// uses, rather than each menu deciding for itself which of the two entries to drop.
  @Test("applying the policy withdraws exactly the queue entries it withholds")
  func applyingThePolicyWithdrawsExactlyTheQueueEntries() {
    let canonical: [MediaItemAction] = [
      .playPause, .playNext, .addToUpNext, .download, .markAsFinished, .openShow,
    ]

    #expect(ListeningQueueActionPolicy.apply(.both, to: canonical) == canonical)
    #expect(
      ListeningQueueActionPolicy.apply(.none, to: canonical) == [
        .playPause, .download, .markAsFinished, .openShow,
      ])
  }
}
