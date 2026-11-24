import SwiftUI
import Testing

@testable import Whirr

@Suite("Sleep timer sheet detent")
struct SleepTimerSheetDetentTests {
  @Test("a tall phone window keeps the half-height sheet")
  func tallWindowKeepsHalfHeight() {
    let maxDetentValue = 2 * SleepTimerSheetDetent.requiredHeight + 40
    #expect(
      SleepTimerSheetDetent.height(maxDetentValue: maxDetentValue) == maxDetentValue / 2)
  }

  @Test("a short window grows the sheet to hold the form")
  func shortWindowHoldsTheForm() {
    // An iPhone Duo panel, open or closed, offers about 620 pt: half of it clips the wheel.
    #expect(
      SleepTimerSheetDetent.height(maxDetentValue: 620) == SleepTimerSheetDetent.requiredHeight)
  }

  @Test("the sheet never asks for more than the window has")
  func neverExceedsTheWindow() {
    #expect(SleepTimerSheetDetent.height(maxDetentValue: 400) == 400)
    #expect(SleepTimerSheetDetent.height(maxDetentValue: -1) == 0)
  }

  @Test("the player opens the timer at its fitted height and lets it reach full height")
  func playerUsesTheFittedDetent() {
    #expect(
      PlayerSleepTimerSheet.compactDetents == [.custom(SleepTimerSheetDetent.self), .large])
  }
}
