import Foundation
import Persistence

extension AdSkipCoordinator {
  /// How long a change must hold before the glyph and the player status show it.
  static let defaultActivitySettle: Duration = .seconds(1)

  /// The settled episode under analysis; nil while nothing is, or the setting is off.
  public var analysisActivity: AdSkipAnalysisActivity? { activityChanges.latest }

  /// The current settled activity at once, then every change.
  public nonisolated func analysisActivityUpdates() -> AsyncStream<AdSkipAnalysisActivity?> {
    activityChanges.stream()
  }

  /// Yields whenever the loaded episode's analysis status may have changed, once settled.
  public nonisolated func analysisStatusChanges() -> AsyncStream<Void> {
    statusChanges.stream()
  }

  var liveSettledState: AdSkipSettledState {
    let enabled = isEnabled == true
    let analysing = underAnalysis.flatMap { identity -> AdSkipAnalysisActivity? in
      guard enabled else { return nil }
      let linked = localEpisodes?[identity]?.linkedIdentities ?? []
      return AdSkipAnalysisActivity(identities: Set([identity] + linked))
    }
    return AdSkipSettledState(
      activity: analysing, isEnabled: enabled, hasAllowedSignal: hasAllowedSignal,
      isAllowed: isAllowed, isDeferred: isDeferred, priority: priority,
      isGrantActive: isGrantActive)
  }

  /// Called by every input the status or glyph reads. The publisher settles the change.
  func noteActivityChange() {
    activity.note(liveSettledState, on: self)
  }

  /// Called by the publisher once the settle has passed, on this actor.
  func publishSettledState() {
    activity.publish(liveSettledState)
  }

  /// Whether a publish is waiting out the settle. For tests.
  var hasPendingSettle: Bool { activity.hasPendingSettle }

  /// For tests: the production settle would make every assertion wait a second.
  func setActivitySettle(_ settle: Duration) {
    activity.settle = settle
  }
}
