import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

struct WatchArtworkRevisionsTests {
  private let account = try! WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
  private let other = try! WatchAccountStamp(accountIdentityHash: "b", serverIdentityHash: "s")
  private let capabilities = WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true)

  @Test func catalogueRevisionReachesEveryEpisodeOfTheShow() throws {
    var revisions = WatchArtworkRevisions()
    let snapshot = try WatchCatalogueSnapshot(
      accountStamp: account,
      items: [
        WatchCatalogueItem(
          id: "row", selection: .audiobookshelf(itemID: "show", episodeID: "one"), title: "Episode",
          capabilities: capabilities, artworkRevision: "1790000000123")
      ])

    let learned = revisions.learn(from: snapshot)
    #expect(learned)
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "show", episodeID: "two"), accountStamp: account).revision
        == "1790000000123")
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "show", episodeID: nil), accountStamp: other).revision
        == "unversioned")
    let relearned = revisions.learn(from: snapshot)
    #expect(!relearned, "an unchanged revision is not a change")
  }

  @Test func browseShowRowsTeachTheirRevisionAndUndatedRowsKeepTheLastOne() throws {
    var revisions = WatchArtworkRevisions()
    let dated = try WatchBrowseShowRow(id: .audiobookshelf(itemID: "show"), title: "Show", artworkRevision: "1")
    let undated = try WatchBrowseShowRow(id: .audiobookshelf(itemID: "show"), title: "Show")

    revisions.learn([.show(dated)], accountStamp: account)
    let undatedChanged = revisions.learn([.show(undated)], accountStamp: account)
    #expect(!undatedChanged)
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "show", episodeID: nil), accountStamp: account)
        == WatchArtworkReference(selection: .audiobookshelf(itemID: "show", episodeID: nil), revision: "1"))

    let replaced = try WatchBrowseShowRow(id: .audiobookshelf(itemID: "show"), title: "Show", artworkRevision: "2")
    let replacedChanged = revisions.learn([.show(replaced)], accountStamp: account)
    #expect(replacedChanged)
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "show", episodeID: "e"), accountStamp: account).revision == "2")
  }

  @Test func retainingAccountsForgetsTheOthers() throws {
    var revisions = WatchArtworkRevisions()
    let row = try WatchBrowseShowRow(id: .nativeFeed(feedID: "9"), title: "Feed", artworkRevision: "1")
    revisions.learn([.show(row)], accountStamp: account)
    revisions.learn([.show(row)], accountStamp: other)

    revisions.retain(accounts: [other])

    let selection = WatchSelection.nativeFeed(feedID: "9", episodeID: "cover")
    #expect(revisions.reference(for: selection, accountStamp: account).revision == "unversioned")
    #expect(revisions.reference(for: selection, accountStamp: other).revision == "1")
  }
  @Test func aManifestTeachesItsDatedCoversUnderTheStampItIsFiledAs() throws {
    var revisions = WatchArtworkRevisions()
    let manifest = try WatchArtworkManifest(
      accountStamp: account, authenticatedAccountStamp: other,
      covers: [
        WatchArtworkCover(reference: .init(source: .audiobookshelf(itemID: "book"), revision: "5"), size: .row),
        WatchArtworkCover(reference: .init(source: .audiobookshelf(itemID: "book"), revision: "5"), size: .player),
        WatchArtworkCover(reference: .init(source: .nativeFeed(feedID: "9")), size: .row),
      ])

    let learned = revisions.learn(manifest, as: other)
    let relearned = revisions.learn(manifest, as: other)
    #expect(learned)
    #expect(!relearned)
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "book", episodeID: nil), accountStamp: other).revision == "5")
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "book", episodeID: nil), accountStamp: account).revision
        == "unversioned")
    #expect(
      revisions.reference(for: .nativeFeed(feedID: "9", episodeID: "e"), accountStamp: other).revision == "unversioned")
  }

  @Test func aFullAccountRefusesNewCoversButKeepsUpdatingKnownOnes() throws {
    var revisions = WatchArtworkRevisions()
    let rows = try (0..<WatchArtworkRevisions.maxCoversPerAccount).map {
      WatchBrowseRow.show(
        try WatchBrowseShowRow(id: .audiobookshelf(itemID: "b\($0)"), title: "B", artworkRevision: "1"))
    }
    revisions.learn(rows, accountStamp: account)
    let extra = try WatchBrowseShowRow(id: .audiobookshelf(itemID: "extra"), title: "E", artworkRevision: "1")
    let addedPastCap = revisions.learn([.show(extra)], accountStamp: account)
    #expect(!addedPastCap)
    let updated = try WatchBrowseShowRow(id: .audiobookshelf(itemID: "b0"), title: "B", artworkRevision: "2")
    let updatedKnown = revisions.learn([.show(updated)], accountStamp: account)
    #expect(updatedKnown)
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "b0", episodeID: nil), accountStamp: account).revision == "2")
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "b1", episodeID: nil), accountStamp: account).revision == "1")
    #expect(
      revisions.reference(for: .audiobookshelf(itemID: "extra", episodeID: nil), accountStamp: account).revision
        == "unversioned")
  }
}
