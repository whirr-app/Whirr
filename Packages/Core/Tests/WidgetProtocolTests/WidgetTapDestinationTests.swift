import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetTapDestinationTests {

  static let destinations: [WidgetTapDestination] = [
    .item(token: "3F2A-b9c0"),
    .item(token: String(repeating: "a", count: 64)),
    .player,
    .listeningStats,
    .latestEpisodes,
    .smartList(id: 1),
    .smartList(id: .max),
  ]

  @Test(arguments: destinations)
  func roundTrips(destination: WidgetTapDestination) throws {
    let url = try #require(destination.url)
    #expect(WidgetTapDestination(url: url) == destination)
  }

  @Test func linksHaveTheDocumentedShape() {
    #expect(WidgetTapDestination.item(token: "abc-1").url?.absoluteString == "whirr://widget/item/abc-1")
    #expect(WidgetTapDestination.player.url?.absoluteString == "whirr://widget/player")
    #expect(WidgetTapDestination.listeningStats.url?.absoluteString == "whirr://widget/stats")
    #expect(WidgetTapDestination.latestEpisodes.url?.absoluteString == "whirr://widget/new-episodes")
    #expect(WidgetTapDestination.smartList(id: 42).url?.absoluteString == "whirr://widget/smart-list/42")
  }

  /// The token was validated when the snapshot was decoded; a token that fails here never came
  /// from the publisher, so it gets no link rather than a malformed one.
  @Test(arguments: ["", "a/b", "a.b", "a b", "é", String(repeating: "a", count: 65)])
  func anInvalidTokenHasNoLink(token: String) {
    #expect(WidgetTapDestination.item(token: token).url == nil)
  }

  @Test(arguments: [Int64(0), -1, .min])
  func aNonPositiveListHasNoLink(id: Int64) {
    #expect(WidgetTapDestination.smartList(id: id).url == nil)
  }

  @Test func schemeAndHostAreCaseInsensitive() throws {
    let url = try #require(URL(string: "WHIRR://Widget/player"))
    #expect(WidgetTapDestination(url: url) == .player)
  }

  /// Once the scheme is registered any app or web page can open a `whirr://` link, so everything
  /// outside the documented forms is refused, including the sign-in callback.
  @Test(arguments: [
    "https://widget/player",
    "whirr://oauth?code=x&state=y",
    "whirr://oauth/player",
    "whirr://library/player",
    "whirr:widget/player",
    "whirr:///player",
    "whirr://widget",
    "whirr://widget/",
    "whirr://widget/player/",
    "whirr://widget/player?x=1",
    "whirr://widget/player#x",
    "whirr://widget:80/player",
    "whirr://user@widget/player",
    "whirr://user:pw@widget/player",
    "whirr://widget/stats/extra",
    "whirr://widget/unknown",
    "whirr://widget/item",
    "whirr://widget/item/",
    "whirr://widget/item/abc/",
    "whirr://widget/item/abc/def",
    "whirr://widget/item/a%2Fb",
    "whirr://widget/item/a.b",
    "whirr://widget/item/a%20b",
    "whirr://widget/item/abc?token=x",
    "whirr://widget//item/abc",
    "whirr://widget/ITEM/abc",
    "whirr://widget/item/" + String(repeating: "a", count: 65),
    "whirr://widget/smart-list",
    "whirr://widget/smart-list/",
    "whirr://widget/smart-list/0",
    "whirr://widget/smart-list/-1",
    "whirr://widget/smart-list/+1",
    "whirr://widget/smart-list/01",
    "whirr://widget/smart-list/abc",
    "whirr://widget/smart-list/1/2",
    "whirr://widget/smart-list/%31",
    "whirr://widget/smart-list/9223372036854775808",
    "whirr://widget/smart-list/1?x=1",
  ])
  func refusesEverythingElse(string: String) throws {
    let url = try #require(URL(string: string))
    #expect(WidgetTapDestination(url: url) == nil)
  }
}
