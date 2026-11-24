import DesignSystem
import SwiftUI
import Testing

@testable import Whirr

@Suite("Directory podcast detail transition")
struct DirectoryPodcastDetailTransitionTests {
  @Test("the zoom runs only when available and Reduce Motion is off")
  func zoomPolicy() {
    #expect(DirectoryPodcastDetailTransitionPolicy.usesZoom(reduceMotion: false, isAvailable: true))
    #expect(
      DirectoryPodcastDetailTransitionPolicy.usesZoom(reduceMotion: true, isAvailable: true)
        == false)
    #expect(
      DirectoryPodcastDetailTransitionPolicy.usesZoom(reduceMotion: false, isAvailable: false)
        == false)
  }

  @Test("a regular window gets a page sheet; compact or unpublished gets the full screen")
  func containerPolicy() {
    #expect(DirectoryPodcastDetailTransitionPolicy.container(for: .regular) == .pageSheet)
    #expect(DirectoryPodcastDetailTransitionPolicy.container(for: .compact) == .fullScreen)
    #expect(DirectoryPodcastDetailTransitionPolicy.container(for: nil) == .fullScreen)
  }

  @Test("a compact or narrow page keeps the base margin")
  func compactAndNarrowPagesKeepTheBaseMargin() {
    let base = WhirrSpacing.medium
    #expect(
      DirectoryPodcastDetailLayout.contentHorizontalInset(
        availableWidth: 393, horizontalSizeClass: .compact) == base)
    #expect(
      DirectoryPodcastDetailLayout.contentHorizontalInset(
        availableWidth: 834, horizontalSizeClass: nil) == base)
    #expect(
      DirectoryPodcastDetailLayout.contentHorizontalInset(
        availableWidth: 0, horizontalSizeClass: .regular) == base)
    #expect(
      DirectoryPodcastDetailLayout.contentHorizontalInset(
        availableWidth: PodcastsViewPresentation.episodeReadingMeasure, horizontalSizeClass: .regular)
        == base)
  }

  @Test("a regular page sheet bounds the page to the show page's reading measure")
  func aRegularPageSheetIsBoundedToTheReadingMeasure() {
    // An 834 pt `.page` sheet (iPad portrait) reports `.regular`; its content is centred at 760 pt.
    #expect(
      DirectoryPodcastDetailLayout.contentHorizontalInset(
        availableWidth: 834, horizontalSizeClass: .regular) == WhirrSpacing.medium + 37)
  }

  @Test("the directory page shares the followed show page's row rule")
  func directoryPageMatchesTheShowPage() {
    for width in stride(from: CGFloat(0), through: 2000, by: 50) {
      for sizeClass in [UserInterfaceSizeClass.compact, .regular, nil] {
        #expect(
          DirectoryPodcastDetailLayout.contentHorizontalInset(
            availableWidth: width, horizontalSizeClass: sizeClass)
            == PodcastsViewPresentation.boundedRowHorizontalInset(
              availableWidth: width, horizontalSizeClass: sizeClass))
      }
    }
  }

  @Test("a tall phone page keeps the square hero")
  func tallPageKeepsTheSquareHero() {
    #expect(DirectoryPodcastDetailLayout.heroHeight(availableWidth: 402, pageHeight: 874) == 402)
  }

  @Test("a short page caps the hero so the title and author clear the Follow pill")
  func shortPageCapsTheHero() throws {
    // A half-open iPhone Duo panel: a square hero put the Follow pill over the author line.
    let height = try #require(
      DirectoryPodcastDetailLayout.heroHeight(availableWidth: 475, pageHeight: 669))
    #expect(height == (669 * DirectoryPodcastDetailLayout.heroMaximumPageFraction).rounded(.down))
    #expect(height < 475)
  }

  @Test("an unmeasured page keeps the square hero")
  func unmeasuredPageKeepsTheSquare() {
    #expect(DirectoryPodcastDetailLayout.heroHeight(availableWidth: 0, pageHeight: 669) == nil)
    #expect(DirectoryPodcastDetailLayout.heroHeight(availableWidth: 475, pageHeight: 0) == nil)
  }

}
