import CoreGraphics
import Testing

@testable import Whirr

@Suite("Inline Up Next presentation")
struct InlineUpNextPresentationTests {

  @Test("only a portrait phone at standard text sizes shows the queue inline")
  func placementIsInlineOnlyForCompactRegularHeightStandardText() {
    #expect(
      InlineUpNextPresentation.placement(
        widthClass: .compact, isCompactHeight: false, isAccessibilitySize: false) == .inline)
    #expect(
      InlineUpNextPresentation.placement(
        widthClass: .compact, isCompactHeight: true, isAccessibilitySize: false) == .sheet)
    #expect(
      InlineUpNextPresentation.placement(
        widthClass: .regular, isCompactHeight: false, isAccessibilitySize: false) == .sheet)
    #expect(
      InlineUpNextPresentation.placement(
        widthClass: .compact, isCompactHeight: false, isAccessibilitySize: true) == .sheet)
  }

  @Test("one flag drives exactly one presentation")
  func oneFlagDrivesExactlyOnePresentation() {
    for placement in [InlineUpNextPresentation.Placement.inline, .sheet] {
      #expect(
        InlineUpNextPresentation.isSheetPresented(isShowingUpNext: false, placement: placement)
          == false)
      #expect(
        InlineUpNextPresentation.isInlineShown(isShowingUpNext: false, placement: placement)
          == false)
      let sheet = InlineUpNextPresentation.isSheetPresented(
        isShowingUpNext: true, placement: placement)
      let inline = InlineUpNextPresentation.isInlineShown(
        isShowingUpNext: true, placement: placement)
      #expect(sheet != inline)
      #expect(inline == (placement == .inline))
    }
  }

  @Test("the quick action toggles the queue")
  func quickActionToggles() {
    var isShowing = false
    InlineUpNextPresentation.toggle(&isShowing)
    #expect(isShowing)
    InlineUpNextPresentation.toggle(&isShowing)
    #expect(isShowing == false)
  }

  @Test("only the sheet freezes the committed identity; closing either reconciles")
  func onlyTheSheetFreezesIdentity() {
    #expect(InlineUpNextPresentation.freezesCommittedIdentity(.sheet))
    #expect(InlineUpNextPresentation.freezesCommittedIdentity(.inline) == false)
  }

  @Test("the header is exactly as tall as its thumbnail and padding")
  func headerHeightIsThumbnailPlusPadding() {
    let header = InlineUpNextPresentation.header
    #expect(header.height == header.artworkSize + header.verticalPadding * 2)
    #expect(header.artworkSize >= 44)
  }

  @Test("the cover's corner radius scales down with a thumbnail and caps at the page radius")
  func cornerRadiusScalesWithCover() {
    #expect(InlineUpNextPresentation.artworkCornerRadius(coverSize: 380) == 18)
    #expect(InlineUpNextPresentation.artworkCornerRadius(coverSize: 210) == 18)
    let thumbnail = InlineUpNextPresentation.artworkCornerRadius(
      coverSize: InlineUpNextPresentation.header.artworkSize)
    #expect(thumbnail < 18)
    #expect(thumbnail >= 6)
  }
}
