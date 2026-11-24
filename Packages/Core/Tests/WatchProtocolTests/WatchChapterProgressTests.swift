import Foundation
import Testing

@testable import WatchProtocol

@Suite struct WatchChapterProgressTests {
  @Test func chapterMetadataSurvivesWireAndCache() throws {
    let row = try WatchCatalogueItem(
      id: "book", selection: .audiobookshelf(itemID: "book", episodeID: nil),
      title: "Book", progressSeconds: 1800, durationSeconds: 7200, isCurrentPlayback: true,
      capabilities: .init(phonePlayable: true, watchPlayable: true))
    let snapshot = try WatchCatalogueSnapshot(accountStamp: WatchProtocolFixtures.accountStamp(), items: [row])
    var json = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(snapshot)) as? [String: Any])
    var rows = try #require(json["items"] as? [[String: Any]])
    rows[0]["chapterTitle"] = "Chapter 3"
    rows[0]["chapterStartSeconds"] = 1500.0
    rows[0]["chapterEndSeconds"] = 2400.0
    json["items"] = rows
    let decoded = try WatchWireCodec.decode(
      WatchCatalogueSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    let cache = try WatchCatalogueCache(expectedAccountStamp: decoded.accountStamp, snapshot: decoded)
    let restored = try WatchWireCodec.decode(WatchCatalogueCache.self, from: WatchWireCodec.encode(cache))
    let restoredSnapshot = try #require(restored.snapshot)
    let encoded = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(restoredSnapshot)) as? [String: Any])
    let result = try #require((encoded["items"] as? [[String: Any]])?.first)
    #expect(result["chapterTitle"] as? String == "Chapter 3")
    #expect(result["chapterStartSeconds"] as? Double == 1500)
    #expect(result["chapterEndSeconds"] as? Double == 2400)
  }
  @Test func invalidChapterBoundsAreRejectedAndLegacyRowsStayValid() throws {
    for bounds: (Double?, Double?) in [(nil, 10), (5, nil), (10, 10), (-1, 10), (.nan, 10), (0, .infinity), (0, 101)] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchCatalogueItem(
          id: "book", selection: .audiobookshelf(itemID: "book", episodeID: nil),
          title: "Book", durationSeconds: 100, chapterStartSeconds: bounds.0, chapterEndSeconds: bounds.1,
          capabilities: .init(phonePlayable: true, watchPlayable: true))
      }
    }
    let row = try WatchCatalogueItem(
      id: "book", selection: .audiobookshelf(itemID: "book", episodeID: nil),
      title: "Book", durationSeconds: 100, capabilities: .init(phonePlayable: true, watchPlayable: true))
    let restored = try JSONDecoder().decode(WatchCatalogueItem.self, from: JSONEncoder().encode(row))
    #expect(restored.chapterTitle == nil && restored.chapterStartSeconds == nil && restored.chapterEndSeconds == nil)
  }

}
