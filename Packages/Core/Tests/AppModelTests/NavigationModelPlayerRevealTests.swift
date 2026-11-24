import Foundation
import Testing

@testable import AppModel

/// The player's View Details and Up Next's Open reveal a book's page behind the collapsing player.
/// The Podcasts tab is episode-led, so a book revealed from there lands on Library instead of
/// leaving a book page under a highlighted Podcasts tab, where it outlived every tab switch.
@Suite struct NavigationModelPlayerRevealTests {
  @MainActor
  @Test("a book revealed from the Podcasts tab lands on Library and leaves Podcasts at its root")
  func bookFromPodcastsLandsOnLibrary() {
    let model = NavigationModel(presentation: .shell, section: .podcasts)

    model.revealFromPlayer(.itemDetail(itemID: "book"))

    #expect(model.section == .library)
    #expect(model[pathFor: .library] == [.itemDetail(itemID: "book")])
    #expect(model[pathFor: .podcasts].isEmpty)
  }

  @MainActor
  @Test("the reveal keeps Library's own stack beneath the book")
  func bookFromPodcastsKeepsLibraryStack() {
    let model = NavigationModel(presentation: .shell, section: .library)
    model.navigate(to: .itemDetail(itemID: "other"))
    model.navigate(to: NavigationModel.Destination(section: .podcasts))

    model.revealFromPlayer(.itemDetail(itemID: "book"))

    #expect(
      model[pathFor: .library] == [.itemDetail(itemID: "other"), .itemDetail(itemID: "book")])
  }

  @MainActor
  @Test("a book already on top of Library is shown, not stacked on itself")
  func bookAlreadyOnLibraryIsNotDuplicated() {
    let model = NavigationModel(presentation: .shell, section: .library)
    model.navigate(to: .itemDetail(itemID: "book"))
    model.navigate(to: NavigationModel.Destination(section: .podcasts))

    model.revealFromPlayer(.itemDetail(itemID: "book"))

    #expect(model.section == .library)
    #expect(model[pathFor: .library] == [.itemDetail(itemID: "book")])
  }

  @MainActor
  @Test("on a mixed section a book still pushes where the listener is")
  func bookFromHomePushesOnHome() {
    let model = NavigationModel(presentation: .shell, section: .home)

    model.revealFromPlayer(.itemDetail(itemID: "book"))

    #expect(model.section == .home)
    #expect(model[pathFor: .home] == [.itemDetail(itemID: "book")])
  }

  @MainActor
  @Test("a show revealed from the Podcasts tab stays on Podcasts")
  func showFromPodcastsStays() {
    let model = NavigationModel(presentation: .shell, section: .podcasts)

    model.revealFromPlayer(.podcastShow(itemID: "show"))

    #expect(model.section == .podcasts)
    #expect(model[pathFor: .podcasts] == [.podcastShow(itemID: "show")])
  }

  @MainActor
  @Test("at regular width the book's card rises over Library's root")
  func bookCardFromPodcasts() {
    let model = NavigationModel(presentation: .shell, section: .podcasts)
    model.setItemDetailPresentation(.card)

    model.revealFromPlayer(.itemDetail(itemID: "book"))

    #expect(model.section == .library)
    #expect(model[pathFor: .library].isEmpty)
    #expect(model.presentedItemDetail?.itemID == "book")
  }
}
