import DesignSystem
import Persistence
import Testing

@testable import Whirr

/// The pure row projection over `[ListeningQueueItem]`: ordering, `canMoveEarlier`/`canMoveLater`
/// edges, which row is "Next", selectability, and the media glyph and context-menu inventory per
/// category.
@Suite("Listening queue presentation")
struct ListeningQueueViewPresentationTests {
  @Test func rowsPreserveOrderAndCarryTheIdentity() throws {
    let expectedAudiobook = try #require(
      ListeningIdentity.audiobook(itemID: "item-first"))
    let expectedRSS = try #require(
      ListeningIdentity.rssEpisode(feedID: 7, episodeID: "gone"))
    let rows = ListeningQueueViewPresentation.rows([
      try Self.audiobook("first", position: 0),
      try Self.rssEpisode("gone", position: 1, tombstone: true),
      try Self.audiobook("last", position: 2),
    ])

    #expect(rows.map(\.id) == [1, 2, 3])
    #expect(rows.map(\.primaryTitle) == ["first", "gone", "last"])
    #expect(rows[0].identity == expectedAudiobook)
    #expect(rows[1].identity == expectedRSS)
  }

  @Test func aChapterRowIsNamedByItsChapterOverItsBookAndAuthor() throws {
    let book = try Self.audiobook("Dune", position: 0)
    let chapter = ListeningQueueChapter(start: 100, end: 200, title: "The Storm")
    let rows = ListeningQueueViewPresentation.rows([
      ListeningQueueItem(
        id: book.id, position: 0, identity: book.identity, primaryTitle: book.primaryTitle,
        secondaryTitle: book.secondaryTitle, category: .audiobook, isTombstone: false, chapter: chapter),
      try Self.audiobook("whole", position: 1),
    ])

    #expect(rows[0].primaryTitle == "The Storm")
    #expect(rows[0].secondaryTitle == "Dune · Author of Dune")
    #expect(rows[0].itemTitle == "Dune")
    #expect(rows[0].itemAuthor == "Author of Dune")
    #expect(rows[0].chapter == chapter)
    #expect(rows[0].mediaKindLabel == "Audiobook chapter")
    #expect(rows[0].mediaKind == .audiobook)

    #expect(rows[1].primaryTitle == "whole")
    #expect(rows[1].secondaryTitle == "Author of whole")
    #expect(rows[1].chapter == nil)
    #expect(rows[1].mediaKindLabel == "Audiobook")
  }

  @Test func onlyTheFirstRowIsMarkedNext() throws {
    let rows = ListeningQueueViewPresentation.rows([
      try Self.audiobook("first", position: 0),
      try Self.audiobook("middle", position: 1),
      try Self.audiobook("last", position: 2),
    ])

    #expect(rows.map(\.isNext) == [true, false, false])
  }

  @Test func aSingleRowQueueIsStillNext() throws {
    let rows = ListeningQueueViewPresentation.rows([try Self.audiobook("only", position: 0)])
    #expect(rows.map(\.isNext) == [true])
  }

  @Test func anEmptyQueueProjectsNoRows() {
    #expect(ListeningQueueViewPresentation.rows([]).isEmpty)
  }

  @Test func tombstoneRowsAreUnselectableButKeepTheirOrder() throws {
    let rows = ListeningQueueViewPresentation.rows([
      try Self.audiobook("first", position: 0),
      try Self.episode("gone", position: 1, tombstone: true),
      try Self.audiobook("last", position: 2),
    ])

    #expect(rows.map(\.isSelectable) == [true, false, true])
  }

  @Test func moveEdgesRespectFirstAndLastRow() throws {
    let rows = ListeningQueueViewPresentation.rows([
      try Self.audiobook("first", position: 0),
      try Self.audiobook("middle", position: 1),
      try Self.audiobook("last", position: 2),
    ])

    #expect(rows.map(\.canMoveEarlier) == [false, true, true])
    #expect(rows.map(\.canMoveLater) == [true, true, false])
  }

  @Test func aSingleRowQueueCanMoveNeitherDirection() throws {
    let rows = ListeningQueueViewPresentation.rows([try Self.audiobook("only", position: 0)])
    #expect(rows[0].canMoveEarlier == false)
    #expect(rows[0].canMoveLater == false)
  }

  @Test func mediaKindMapsCategoryToTheMatchingGlyph() {
    #expect(ListeningQueueViewPresentation.mediaKind(for: .audiobook) == .audiobook)
    #expect(ListeningQueueViewPresentation.mediaKind(for: .podcast) == .podcast)
  }

  @Test func mediaKindLabelDistinguishesAnEpisodeFromItsShow() {
    #expect(ListeningQueueViewPresentation.mediaKindLabel(for: .audiobook) == "Audiobook")
    #expect(ListeningQueueViewPresentation.mediaKindLabel(for: .podcast) == "Podcast episode")
  }

  @Test func positionTextDescribesRankAndTotal() {
    #expect(ListeningQueueViewPresentation.positionText(rank: 2, total: 4) == "Position 2 of 4")
  }

  @Test func contextActionsOfferPlayNowAndOpenBookForAnAudiobook() {
    let actions = ListeningQueueViewPresentation.contextActions(for: .audiobook)
    #expect(actions.map(\.id) == ["play-now", "open-item"])
    #expect(actions.map(\.label) == ["Play Now", "View Details"])
  }

  @Test func contextActionsOfferPlayNowAndOpenEpisodeForAnEpisode() {
    let actions = ListeningQueueViewPresentation.contextActions(for: .podcast)
    #expect(actions.map(\.id) == ["play-now", "open-item"])
    #expect(actions.map(\.label) == ["Play Now", "View Details"])
  }

  private static func audiobook(
    _ title: String, position: Int, tombstone: Bool = false
  ) throws -> ListeningQueueItem {
    ListeningQueueItem(
      id: Int64(position + 1), position: position,
      identity: try #require(ListeningIdentity.audiobook(itemID: "item-\(title)")),
      primaryTitle: title, secondaryTitle: "Author of \(title)",
      category: .audiobook, isTombstone: tombstone)
  }

  private static func episode(
    _ episodeID: String, position: Int, tombstone: Bool = false
  ) throws -> ListeningQueueItem {
    ListeningQueueItem(
      id: Int64(position + 1), position: position,
      identity: try #require(
        ListeningIdentity.podcastEpisode(
          itemID: "item-\(episodeID)", episodeID: episodeID)),
      primaryTitle: episodeID, secondaryTitle: "Show for \(episodeID)",
      category: .podcast, isTombstone: tombstone)
  }

  private static func rssEpisode(
    _ episodeID: String, position: Int, tombstone: Bool = false
  ) throws -> ListeningQueueItem {
    ListeningQueueItem(
      id: Int64(position + 1), position: position,
      identity: try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: episodeID)),
      primaryTitle: episodeID, secondaryTitle: "Native Show",
      category: .podcast, isTombstone: tombstone)
  }
}
