import ActivityKit
import Foundation
import WidgetProtocol

/// The production sink: one `Activity<SleepTimerActivityAttributes>` at a time.
@MainActor
final class ActivityKitSleepTimerSink: SleepTimerActivitySink {
  /// Past this, a running activity the app could no longer update (the process was killed) is
  /// marked stale so the view stops claiming a live countdown.
  static let staleGrace: TimeInterval = 60

  private var activity: Activity<SleepTimerActivityAttributes>?

  var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

  var hasActivity: Bool {
    guard let activity else { return false }
    return activity.activityState == .active || activity.activityState == .stale
  }

  func start(_ state: SleepTimerActivityAttributes.ContentState) -> Bool {
    do {
      activity = try Activity.request(
        attributes: SleepTimerActivityAttributes(), content: Self.content(state), pushType: nil)
      return true
    } catch {
      return false
    }
  }

  func update(_ state: SleepTimerActivityAttributes.ContentState) {
    guard let activity else { return }
    let content = Self.content(state)
    Task { await activity.update(content) }
  }

  func endAll() {
    activity = nil
    for activity in Activity<SleepTimerActivityAttributes>.activities {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }

  private static func content(
    _ state: SleepTimerActivityAttributes.ContentState
  ) -> ActivityContent<SleepTimerActivityAttributes.ContentState> {
    ActivityContent(state: state, staleDate: state.endsAt?.addingTimeInterval(staleGrace))
  }
}
