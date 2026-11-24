import Persistence
import PlayerCore
import Testing

@testable import Whirr

/// The quick-action row is `Equatable`-gated so a position tick cannot rebuild the native menus
/// beneath it, since a rebuilt `Menu` closes an open menu under the listener's finger. The gate is
/// only as good as its field list: anything the menus read but the identity omits freezes at its
/// first value for the whole session.
@Suite("Quick actions controls identity")
struct QuickActionsControlsIdentityTests {

  private static func identity(
    rate: Double = 1.5,
    hasRateOverride: Bool = false,
    sleepTimerMode: PlayerQuickActionsSleepTimerMode = .off,
    sleepTimerCompletion: SleepTimerMenuPresentation.Completion? = .chapter
  ) -> QuickActionsControls.Identity {
    QuickActionsControls.Identity(
      itemID: "item-1", episodeID: nil,
      sleepTimerMode: sleepTimerMode, rate: rate, hasRateOverride: hasRateOverride,
      sleepTimerCompletion: sleepTimerCompletion,
      encodedRatePresets: "1,1.5,2", encodedTimerPresets: "15,30")
  }

  /// The menu's section header, its Use Default Speed entry, and the label's explicit 1× case all
  /// read this. Omitting it from the gate would leave the menu claiming to edit the default long
  /// after an override existed.
  @Test("creating or clearing an override invalidates the menu")
  func overrideStateParticipatesInTheGate() {
    #expect(Self.identity(hasRateOverride: false) != Self.identity(hasRateOverride: true))
  }

  /// Pinned at 1×: the rate is unchanged, so the override flag is the only thing that can tell the
  /// label to start drawing.
  @Test("an override at the same rate still invalidates the menu")
  func overrideAtAnUnchangedRateStillInvalidates() {
    #expect(
      Self.identity(rate: 1, hasRateOverride: false)
        != Self.identity(rate: 1, hasRateOverride: true))
  }

  @Test("the speed itself and the timer's mode and boundary each invalidate the menu")
  func theOtherMenuInputsParticipate() {
    #expect(Self.identity(rate: 1.5) != Self.identity(rate: 1.8))
    #expect(
      Self.identity() != Self.identity(sleepTimerMode: .countdown(configuredSeconds: 900)))
    #expect(Self.identity() != Self.identity(sleepTimerCompletion: .episode))
  }

  /// Rows that differ only in values the menus never read compare equal, so a playhead tick
  /// rebuilds nothing.
  @Test("identical menu inputs compare equal, so a position tick rebuilds nothing")
  func equalInputsCompareEqual() {
    #expect(Self.identity() == Self.identity())
  }
}
