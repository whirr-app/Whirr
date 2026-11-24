import AppModel
import Persistence
import Testing

@testable import Whirr

@Suite("Home more view presentation")
struct HomeMoreViewPresentationTests {
  private func makeItem(author: String? = "Octavia Butler") -> HomeItem {
    HomeItem(
      serverItemId: "item-1", title: "Kindred", author: author, category: .audiobook,
      durationSeconds: nil, progressSeconds: 0, ebookProgress: 0, isFinished: false,
      addedAt: nil, isDownloaded: false, episodeID: nil, episodeTitle: nil)
  }

  @Test("loading and empty states overlay a mounted list without intercepting pull")
  func nonLoadedStatesUseNonInterceptingOverlays() {
    for state in [HomeMoreModel.State.loading, .empty] {
      let placeholder = HomeMoreViewPresentation.placeholder(for: state)

      #expect(placeholder != nil)
      #expect(placeholder?.allowsHitTesting == false)
    }

    #expect(HomeMoreViewPresentation.placeholder(for: .loaded) == nil)
  }

  @Test("editorial item rows promote their existing subtitle to the eyebrow")
  func editorialItemRowTextPromotesSubtitle() {
    let presentation = HomeMoreItemRowPresentation(
      item: makeItem(), section: .recentlyAdded)

    let text = HomeMoreEditorialRowPresentation.text(from: presentation)

    #expect(text.eyebrow == "Octavia Butler")
    #expect(text.subtitle == nil)
  }

  @Test("editorial item rows omit an empty eyebrow when the subtitle is absent")
  func editorialItemRowTextOmitsMissingSubtitle() {
    let presentation = HomeMoreItemRowPresentation(
      item: makeItem(author: nil), section: .continueReading)

    let text = HomeMoreEditorialRowPresentation.text(from: presentation)

    #expect(text.eyebrow == nil)
    #expect(text.subtitle == nil)
  }
}
