import Foundation
import SwiftUI
import TipKit

/// The once-only popover on the player's overflow button that introduces Look Back, shown the
/// first time a book's player is opened after a sleep timer paused it: the moment the listener has
/// lost their place. TipKit keeps it to once and retires it when Look Back is used.
struct LookBackTip: Tip {
  /// Set when the player opens with a sleep-timer pause pending (`LookBackTipTrigger`), never at
  /// the pause itself, so the tip cannot appear over a player left on screen while they sleep.
  @Parameter static var isEligible: Bool = false

  var title: Text { Text(LookBackCopy.tipTitle) }
  var message: Text? { Text(LookBackCopy.tipMessage) }
  var image: Image? { Image(systemName: LookBackCopy.menuSymbol) }
  var rules: [Rule] { [#Rule(Self.$isEligible) { $0 }] }
}

/// The pending half of the tip's trigger. A sleep-timer pause is recorded here, durably, because
/// the listener often wakes to a relaunched app; the next player open or return to the app turns
/// it into eligibility.
nonisolated enum LookBackTipTrigger {
  static let pendingKey = "lookBackTip.sleepTimerPausePending"

  static func recordSleepTimerPause(in defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: pendingKey)
  }

  /// True, once, when a pause was recorded since the last open.
  static func consumePending(in defaults: UserDefaults = .standard) -> Bool {
    guard defaults.bool(forKey: pendingKey) else { return false }
    defaults.removeObject(forKey: pendingKey)
    return true
  }
}

enum LookBackTipConfiguration {
  /// Called once at launch. TipKit stores which tips were shown in its own datastore.
  static func configure() {
    try? Tips.configure()
  }
}

extension View {
  /// On a book's expanded player: a pending sleep-timer pause makes the Look Back tip eligible
  /// when the player appears or the app comes back to it. Kept out of `ExpandedPlayerView`, as the
  /// Look Back sheet is, because that file is at the size where a split is due.
  func lookBackTipTrigger(isBook: Bool) -> some View {
    modifier(LookBackTipTriggerModifier(isBook: isBook))
  }
}

private struct LookBackTipTriggerModifier: ViewModifier {
  let isBook: Bool
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content
      .onAppear(perform: promote)
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { promote() }
      }
  }

  private func promote() {
    guard isBook, LookBackTipTrigger.consumePending() else { return }
    LookBackTip.isEligible = true
  }
}
