import CoreGraphics
import DesignSystem
import Foundation
import Testing

@testable import Whirr

@Suite("Expanded player layout presentation")
struct ExpandedPlayerLayoutPresentationTests {

  @Test("compact input keeps the legacy stacked plan and page-bottom chrome")
  func compactWidthKeepsLegacyStackedPlan() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .compact,
      pageWidth: 393,
      upperRegionHeight: 500,
      measuredMetadataHeight: 100,
      isAccessibilitySize: false)

    guard case .compactStacked(let stacked) = plan else {
      Issue.record("Compact width must use the compact stacked plan")
      return
    }

    #expect(stacked.chromePlacement == .pageBottom)
    #expect(stacked.contentWidth == 345)
    #expect(stacked.overflowPolicy == .upperRegionScroll)
  }

  @Test("regular portrait uses a wide centered cluster")
  func regularPortraitUsesWideCenteredCluster() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular,
      pageWidth: 834,
      upperRegionHeight: 900,
      measuredMetadataHeight: 160,
      isAccessibilitySize: false)

    guard case .regularStacked(let stacked) = plan else {
      Issue.record("834×1210 regular input must use the regular stacked plan")
      return
    }

    #expect(stacked.contentWidth == 706)
    #expect(stacked.artworkSize == ExpandedPlayerLayoutPresentation.regularArtworkMaximumSize)
    #expect(stacked.artworkToMetadataSpacing == WhirrSpacing.xLarge)
    #expect(stacked.upperSlackAbove > 0)
    #expect(abs(stacked.upperSlackAbove - stacked.upperSlackBelow) < 0.001)
    #expect(
      abs(
        stacked.upperSlackAbove + stacked.clusterHeight + stacked.upperSlackBelow
          - stacked.upperRegionHeight) < 0.001)
  }

  @Test("regular portrait reaches the large artwork cap")
  func regularPortraitReachesTheLargeArtworkCap() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular,
      pageWidth: 834,
      upperRegionHeight: 980,
      measuredMetadataHeight: 160,
      isAccessibilitySize: false)

    guard case .regularStacked(let stacked) = plan else {
      Issue.record("834×1210 regular input must use the regular stacked plan")
      return
    }

    #expect(stacked.artworkSize == ExpandedPlayerLayoutPresentation.regularArtworkMaximumSize)
    #expect(stacked.artworkSize == 620)
  }

  @Test("regular landscape is height-bound rather than cap-bound")
  func regularLandscapeIsHeightBoundNotCapBound() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular,
      pageWidth: 1210,
      upperRegionHeight: 450,
      measuredMetadataHeight: 72,
      isAccessibilitySize: false)

    guard case .regularStacked(let stacked) = plan else {
      Issue.record("1210×834 regular input must use the regular stacked plan")
      return
    }

    #expect(stacked.artworkSize == 315)
    #expect(
      stacked.artworkSize < ExpandedPlayerLayoutPresentation.regularArtworkMaximumSize - 100)
    #expect(stacked.artworkSize >= ExpandedPlayerLayoutPresentation.artworkMinimumSize)
  }

  @Test("the regular cap does not change the compact plan")
  func compactPlanIsUnchangedByTheRegularCap() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .compact,
      pageWidth: 560,
      upperRegionHeight: 700,
      measuredMetadataHeight: 100,
      isAccessibilitySize: false)

    guard case .compactStacked(let stacked) = plan else {
      Issue.record("Compact width must use the compact stacked plan")
      return
    }

    #expect(stacked.contentWidth == 512)
    #expect(stacked.artworkSize == ExpandedPlayerView.maximumCoverSize)
    #expect(stacked.artworkSize == 380)
  }

  @Test("accessibility regular plans preserve floors and the scroll fallback")
  func accessibilityRegularPlanPreservesFloorsAndScrollFallback() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular,
      pageWidth: 1210,
      upperRegionHeight: 350,
      measuredMetadataHeight: 600,
      isAccessibilitySize: true)

    guard case .regularStacked(let stacked) = plan else {
      Issue.record("The regular landscape must retain its stacked arrangement")
      return
    }

    #expect(stacked.artworkSize >= ExpandedPlayerLayoutPresentation.artworkMinimumSize)
    #expect(stacked.quickActionMinimumHeight == 72)
    #expect(stacked.allowsVerticalOverflow)
    #expect(stacked.metadataHeight == 600)
    #expect(stacked.metadataHeight > stacked.upperRegionHeight)
    #expect(stacked.overflowPolicy == .upperRegionScroll)
  }

  @Test("metadata growth stays out of the chrome placement decision")
  func chromePlacementKeepsMetadataOutOfTheChromeBudget() {
    let shortMetadata = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular,
      pageWidth: 1210,
      upperRegionHeight: 600,
      measuredMetadataHeight: 96,
      isAccessibilitySize: false)
    let longMetadata = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular,
      pageWidth: 1210,
      upperRegionHeight: 600,
      measuredMetadataHeight: 512,
      isAccessibilitySize: false)

    guard
      case .regularStacked(let shortPlan) = shortMetadata,
      case .regularStacked(let longPlan) = longMetadata
    else {
      Issue.record("The comparison fixtures must both use the regular stacked plan")
      return
    }

    #expect(shortPlan.metadataHeight < longPlan.metadataHeight)
    #expect(shortPlan.upperRegionHeight == longPlan.upperRegionHeight)
    #expect(shortPlan.chromePlacement == longPlan.chromePlacement)
    #expect(shortPlan.chromePlacement == .pageBottom)
  }

  @Test("an iPhone landscape page puts the cover beside the details")
  func compactHeightLandscapeUsesSideBySidePlan() {
    // iPhone 17 landscape: 852pt less two 59pt side insets, 393pt less the 28pt dismiss handle.
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .compact,
      isCompactHeight: true,
      pageWidth: 734,
      upperRegionHeight: 365,
      measuredMetadataHeight: 100,
      isAccessibilitySize: false)

    guard case .sideBySide(let side) = plan else {
      Issue.record("A compact-height page must use the side-by-side plan")
      return
    }

    #expect(side.horizontalPadding == WhirrSpacing.large)
    #expect(side.columnSpacing == WhirrSpacing.xLarge)
    #expect(side.artworkSize == 341)
    #expect(side.detailColumnWidth == 313)
    #expect(
      side.horizontalPadding * 2 + side.artworkSize + side.columnSpacing
        + side.detailColumnWidth == 734)
  }

  @Test("a Pro Max landscape page is side by side even at regular width")
  func regularWidthCompactHeightUsesSideBySidePlan() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular,
      isCompactHeight: true,
      pageWidth: 838,
      upperRegionHeight: 412,
      measuredMetadataHeight: 100,
      isAccessibilitySize: false)

    guard case .sideBySide(let side) = plan else {
      Issue.record("Compact height must win over regular width")
      return
    }

    #expect(side.artworkSize == 380)
    #expect(side.detailColumnWidth == 378)
  }

  @Test("a short, narrow landscape page gives the details column its minimum width first")
  func narrowLandscapeKeepsTheDetailColumnMinimum() {
    // iPhone SE landscape: no side insets, 375pt less the dismiss handle.
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .compact,
      isCompactHeight: true,
      pageWidth: 667,
      upperRegionHeight: 347,
      measuredMetadataHeight: 100,
      isAccessibilitySize: true)

    guard case .sideBySide(let side) = plan else {
      Issue.record("An SE landscape page must still fit side by side")
      return
    }

    #expect(side.detailColumnWidth == ExpandedPlayerLayoutPresentation.sideBySideDetailMinimumWidth)
    #expect(side.artworkSize == 287)
    #expect(side.quickActionMinimumHeight == 72)
  }

  @Test("a compact-height page too narrow for two columns stays stacked")
  func compactHeightTooNarrowFallsBackToStacked() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .compact,
      isCompactHeight: true,
      pageWidth: 500,
      upperRegionHeight: 300,
      measuredMetadataHeight: 100,
      isAccessibilitySize: false)

    guard case .compactStacked = plan else {
      Issue.record("Below the cover and column minimums the page must stay stacked")
      return
    }
  }

  @Test("a tall regular-height page keeps the stacked plans")
  func regularHeightKeepsStackedPlans() {
    let compact = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .compact, isCompactHeight: false, pageWidth: 734, upperRegionHeight: 365,
      measuredMetadataHeight: 100, isAccessibilitySize: false)
    let regular = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular, isCompactHeight: false, pageWidth: 1210, pageHeight: 834,
      upperRegionHeight: 450, measuredMetadataHeight: 72, isAccessibilitySize: false)

    guard case .compactStacked = compact, case .regularStacked = regular else {
      Issue.record("iPad and portrait pages keep the stacked composition")
      return
    }
  }

  @Test("an opened iPhone Duo page puts the cover beside the details")
  func shortRegularPageUsesSideBySidePlan() {
    // The Duo's inner screen is 951×669pt and regular in both size classes; its page is shorter
    // than the stacked chrome needs to keep the regular cover above its floor.
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular, isCompactHeight: false, pageWidth: 951, pageHeight: 645,
      upperRegionHeight: 645, measuredMetadataHeight: 100, isAccessibilitySize: false)

    guard case .sideBySide(let side) = plan else {
      Issue.record("A short regular page must use the side-by-side plan")
      return
    }
    #expect(side.artworkSize == 380)
    #expect(side.detailColumnWidth == 491)

    // The region under the dismiss handle re-resolves to the same composition.
    let region = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular, isCompactHeight: false, pageWidth: 951, pageHeight: 645,
      upperRegionHeight: 617, measuredMetadataHeight: 100, isAccessibilitySize: false)
    #expect(region.sideBySidePlan == side)
  }

  @Test("an iPad mini landscape page stays stacked")
  func iPadMiniLandscapeStaysStacked() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .regular, isCompactHeight: false, pageWidth: 1133, pageHeight: 720,
      upperRegionHeight: 720, measuredMetadataHeight: 72, isAccessibilitySize: false)

    guard case .regularStacked = plan else {
      Issue.record("iPad landscape keeps one stacked arrangement")
      return
    }
    #expect(720 >= ExpandedPlayerLayoutPresentation.shortRegularPageMaximumHeight)
  }

  @Test("a short compact-width page without compact height stays stacked")
  func shortCompactWidthPageStaysStacked() {
    let plan = ExpandedPlayerLayoutPresentation.resolve(
      widthClass: .compact, isCompactHeight: false, pageWidth: 466, pageHeight: 640,
      upperRegionHeight: 640, measuredMetadataHeight: 100, isAccessibilitySize: false)

    guard case .compactStacked = plan else {
      Issue.record("The closed Duo keeps the compact stacked plan")
      return
    }
  }

  @Test("each composition has one page scroll view, with the chrome outside it")
  func everyCompositionUsesOnePageScrollViewOutsideTheChrome() throws {
    let layoutSource = try Self.source(named: "ExpandedPlayerLayoutView.swift")
    let chromeSource = try Self.source(named: "PlayerChromeRegion.swift")
    let layoutText = try ViewSourceScan.executableText(of: layoutSource)
    let chromeText = try ViewSourceScan.executableText(of: chromeSource)

    #expect(ViewSourceScan.occurrences(of: ["    ScrollView {"], in: layoutText) == 1)
    // Side by side passes no mode; the stacked page passes whether it is the Up Next header.
    let stackedPageScroll = "playerPageScrollView(isInlineQueueHeader: isShowingInlineQueue) {"
    #expect(ViewSourceScan.occurrences(of: ["playerPageScrollView {"], in: layoutText) == 1)
    #expect(ViewSourceScan.occurrences(of: [stackedPageScroll], in: layoutText) == 1)
    #expect(ViewSourceScan.occurrences(of: ["ScrollView"], in: chromeText) == 0)

    // Side by side, the cover sits outside the one scroll view and the chrome follows it.
    let sideStart = try #require(layoutText.range(of: "private func sideBySidePage("))
    let sideEnd = try #require(
      layoutText.range(of: "  private func stackedPage", range: sideStart.upperBound..<layoutText.endIndex))
    let sideText = String(layoutText[sideStart.lowerBound..<sideEnd.lowerBound])
    let sideScroll = try #require(sideText.range(of: "playerPageScrollView {"))
    let sideArtwork = try #require(sideText.range(of: "ExpandedPlayerArtwork("))
    let sideChrome = try #require(sideText.range(of: "playerChrome"))
    #expect(sideArtwork.lowerBound < sideScroll.lowerBound)
    #expect(sideScroll.lowerBound < sideChrome.lowerBound)
    #expect(ViewSourceScan.occurrences(of: ["playerPageScrollView {"], in: sideText) == 1)

    let stackedStart = try #require(layoutText.range(of: "private func stackedPage("))
    let nextFunction = try #require(
      layoutText.range(of: "  private func stackedScrollView", range: stackedStart.upperBound..<layoutText.endIndex))
    let stackedText = String(layoutText[stackedStart.lowerBound..<nextFunction.lowerBound])
    let scrollOffset = try #require(stackedText.range(of: "stackedScrollView("))
    let chromeOffset = try #require(stackedText.range(of: "playerChrome"))

    #expect(scrollOffset.lowerBound < chromeOffset.lowerBound)

    let scrollStart = try #require(layoutText.range(of: "private func stackedScrollView("))
    let pageScrollStart = try #require(
      layoutText.range(of: "  private func playerPageScrollView", range: scrollStart.upperBound..<layoutText.endIndex))
    let scrollText = String(layoutText[scrollStart.lowerBound..<pageScrollStart.lowerBound])
    #expect(ViewSourceScan.occurrences(of: [stackedPageScroll], in: scrollText) == 1)
    #expect(ViewSourceScan.occurrences(of: ["ExpandedPlayerArtwork"], in: scrollText) == 1)
    #expect(ViewSourceScan.occurrences(of: ["playerChrome"], in: scrollText) == 0)
  }

  @Test("the artwork request uses the regular cap shared with Now Playing")
  func artworkRequestIsOneRungSharedWithNowPlaying() {
    #expect(
      ExpandedPlayerView.artworkRequestSize(forIdiom: .pad)
        == ExpandedPlayerLayoutPresentation.regularArtworkMaximumSize)
    #expect(ExpandedPlayerView.artworkRequestSize(forIdiom: .pad) == 620)
    #expect(ExpandedPlayerView.artworkRequestSize(forIdiom: .phone) == 380)
  }

  @Test("the page scroll view lets the cover shadow spill only while its content fits")
  func pageScrollClipsOnlyWhenContentOverflows() {
    #expect(
      !ExpandedPlayerLayoutPresentation.pageScrollClipsContent(
        contentHeight: 600, containerHeight: 600, isInlineQueueHeader: false))
    #expect(
      !ExpandedPlayerLayoutPresentation.pageScrollClipsContent(
        contentHeight: 600.4, containerHeight: 600, isInlineQueueHeader: false))
    #expect(
      ExpandedPlayerLayoutPresentation.pageScrollClipsContent(
        contentHeight: 640, containerHeight: 600, isInlineQueueHeader: false))
  }

  @Test("the Up Next header never clips the cover shadow, even while its frame springs past the content")
  func inlineQueueHeaderNeverClips() {
    // The header's frame overshoots on its spring as the cover lands; a clip for those frames cut
    // the shadow in a hard line along the header's bottom edge.
    #expect(
      !ExpandedPlayerLayoutPresentation.pageScrollClipsContent(
        contentHeight: 80, containerHeight: 77.5, isInlineQueueHeader: true))
    #expect(
      !ExpandedPlayerLayoutPresentation.pageScrollClipsContent(
        contentHeight: 640, containerHeight: 600, isInlineQueueHeader: true))
  }

  private static func source(named name: String) throws -> URL {
    guard let source = try ViewSourceScan.appSources().first(where: { $0.lastPathComponent == name })
    else {
      throw NSError(
        domain: "ExpandedPlayerLayoutPresentationTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing App source \(name)"])
    }
    return source
  }
}
