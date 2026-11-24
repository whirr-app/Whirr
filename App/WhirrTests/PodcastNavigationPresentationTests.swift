import AppModel
import Persistence
import Testing

@testable import Whirr

@Suite("Podcast navigation presentation")
struct PodcastNavigationPresentationTests {
  @Test("A downloaded Library filter carries through to a podcast show")
  func downloadedPodcastRouteCarriesDownloadedFilter() {
    let item = ItemSummary(
      serverItemId: "show", mediaKind: "podcast", title: "Show", author: nil,
      durationSeconds: nil, category: .podcast)

    let route = PodcastNavigationPresentation.route(item: item, podcastFilter: .downloaded)
    switch route {
    case .podcastShow(let itemID, let filter, let seed):
      #expect(itemID == "show")
      #expect(filter == .downloaded)
      #expect(seed == item)
    default:
      Issue.record("expected a podcast show route")
    }
  }

  @Test(
    "Podcast selections open a show while existing media keeps item detail",
    arguments: [
      (ItemMediaCategory.podcast, NavigationModel.Route.podcastShow(itemID: "item")),
      (ItemMediaCategory.audiobook, NavigationModel.Route.itemDetail(itemID: "item")),
      (ItemMediaCategory.ebook, NavigationModel.Route.itemDetail(itemID: "item")),
    ])
  func selectionRoute(category: ItemMediaCategory, expected: NavigationModel.Route) {
    #expect(PodcastNavigationPresentation.route(itemID: "item", category: category) == expected)
  }
}
