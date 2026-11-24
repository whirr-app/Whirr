import SwiftUI
import Testing

@testable import Whirr

struct ItemDetailBlurbPresentationTests {
  @Test("collapsed shows a fixed three lines, open shows the whole blurb")
  func lineLimitFollowsTheDisclosure() {
    #expect(ItemDetailBlurbPresentation.lineLimit(isExpanded: false) == 3)
    #expect(ItemDetailBlurbPresentation.lineLimit(isExpanded: true) == nil)
  }

  @Test("Reduce Motion drops the growth rather than shortening it")
  func reduceMotionSuppressesTheAnimation() {
    #expect(ItemDetailBlurbPresentation.motion(reduceMotion: true) == nil)
    #expect(ItemDetailBlurbPresentation.motion(reduceMotion: false) != nil)
  }

  @Test("the control names the next tap, and the hint says what it will do")
  func labelAndHintNameTheAction() {
    #expect(ItemDetailBlurbPresentation.toggleLabel(isExpanded: false) == "More")
    #expect(ItemDetailBlurbPresentation.toggleLabel(isExpanded: true) == "Less")
    #expect(ItemDetailBlurbPresentation.toggleHint(isExpanded: false) == "Shows the full description")
    #expect(ItemDetailBlurbPresentation.toggleHint(isExpanded: true) == "Shows less of the description")
  }
}
