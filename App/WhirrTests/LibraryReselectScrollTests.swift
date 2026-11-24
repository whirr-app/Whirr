import CoreGraphics
import Testing

@testable import Whirr

@Suite("Library reselect scroll")
struct LibraryReselectScrollTests {
  // Measured on an iPhone 17: a collapsed search bar is laid out at zero height and fits 54pt;
  // shown, it is 54pt tall.
  @Test("a collapsed drawer hides the whole search bar")
  func collapsedDrawerIsHidden() {
    #expect(LibraryReselectScroll.hiddenDrawerHeight(fullHeight: 54, visibleHeight: 0) == 54)
  }

  @Test("a shown drawer hides nothing")
  func shownDrawerHidesNothing() {
    #expect(LibraryReselectScroll.hiddenDrawerHeight(fullHeight: 54, visibleHeight: 54) == 0)
  }

  @Test("a partly revealed drawer hides the remainder")
  func partlyRevealedDrawerHidesTheRemainder() {
    #expect(LibraryReselectScroll.hiddenDrawerHeight(fullHeight: 54, visibleHeight: 20) == 34)
  }

  @Test("the hidden height is never negative")
  func hiddenHeightIsNeverNegative() {
    #expect(LibraryReselectScroll.hiddenDrawerHeight(fullHeight: 54, visibleHeight: 60) == 0)
    #expect(LibraryReselectScroll.hiddenDrawerHeight(fullHeight: 0, visibleHeight: -4) == 0)
  }

  @Test("the resting offset is the same whether the drawer is collapsed or shown")
  func restingOffsetIncludesTheHiddenDrawer() {
    let collapsed = LibraryReselectScroll.restingOffset(adjustedTopInset: 116, hiddenDrawerHeight: 54)
    let shown = LibraryReselectScroll.restingOffset(adjustedTopInset: 170, hiddenDrawerHeight: 0)
    #expect(collapsed == -170)
    #expect(shown == -170)
  }

  @Test("a list already resting at its true top is finished")
  func restingListIsFinished() {
    let step = LibraryReselectScroll.step(
      offset: -167.8, restingOffset: -168, viewportHeight: 874, corrections: 0, animated: true)
    #expect(step == .finished)
  }

  // An animated scroll across a self-sizing list drifts as the rows it passes are measured; the
  // top edge is an absolute offset, so a jump reaches it exactly.
  @Test("a far scroll jumps rather than animating across unmeasured rows")
  func farScrollJumps() {
    let step = LibraryReselectScroll.step(
      offset: 514_191, restingOffset: -168, viewportHeight: 874, corrections: 0, animated: true)
    #expect(step == .move(to: -168, animated: false))
  }

  @Test("a short correction animates")
  func nearScrollAnimates() {
    let step = LibraryReselectScroll.step(
      offset: -2, restingOffset: -168, viewportHeight: 874, corrections: 1, animated: true)
    #expect(step == .move(to: -168, animated: true))
  }

  @Test("Reduce Motion never animates")
  func reduceMotionNeverAnimates() {
    let step = LibraryReselectScroll.step(
      offset: -2, restingOffset: -168, viewportHeight: 874, corrections: 0, animated: false)
    #expect(step == .move(to: -168, animated: false))
  }

  @Test("corrections are bounded, so a list that will not settle is left alone")
  func correctionsAreBounded() {
    let step = LibraryReselectScroll.step(
      offset: -2, restingOffset: -168, viewportHeight: 874,
      corrections: LibraryReselectScroll.maximumCorrections, animated: true)
    #expect(step == .finished)
  }
}
