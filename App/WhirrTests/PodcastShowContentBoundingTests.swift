import Foundation
import SwiftUI
import Testing

@testable import Whirr

@Suite("Podcast show content bounding")
struct PodcastShowContentBoundingTests {
  @Test("compact and invalid widths keep the base inset")
  func compactAndInvalidWidthsKeepTheBaseInset() {
    let baseInset: CGFloat = 19

    #expect(
      PodcastsViewPresentation.boundedRowHorizontalInset(
        availableWidth: 930, horizontalSizeClass: .compact, baseInset: baseInset)
        == baseInset)
    #expect(
      PodcastsViewPresentation.boundedRowHorizontalInset(
        availableWidth: 930, horizontalSizeClass: nil, baseInset: baseInset)
        == baseInset)

    for width in [CGFloat.zero, -1, .nan, .infinity, -.infinity] {
      #expect(
        PodcastsViewPresentation.boundedRowHorizontalInset(
          availableWidth: width, horizontalSizeClass: .regular, baseInset: baseInset)
          == baseInset)
    }
  }

  @Test func aRegular930PointSurfaceAdds85PointsToTheBaseInset() {
    let baseInset: CGFloat = 19

    #expect(
      PodcastsViewPresentation.boundedRowHorizontalInset(
        availableWidth: 930, horizontalSizeClass: .regular, baseInset: baseInset)
        == baseInset + 85)
  }

  @Test func aRegularSurfaceBelowTheReadingMeasureKeepsTheBaseInset() {
    let baseInset: CGFloat = 19

    #expect(
      PodcastsViewPresentation.boundedRowHorizontalInset(
        availableWidth: PodcastsViewPresentation.episodeReadingMeasure - 1,
        horizontalSizeClass: .regular,
        baseInset: baseInset)
        == baseInset)
  }
}
