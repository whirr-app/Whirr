import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
import WidgetProtocol

/// The sleep-timer Live Activity. It names no title, show or item: the system's Now Playing card
/// already shows what is playing, and this is drawn on the Lock Screen. A tap outside its buttons
/// opens the expanded player; the buttons keep their intents.
struct SleepTimerLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: SleepTimerActivityAttributes.self) { context in
      SleepTimerLockScreenView(state: context.state, isStale: context.isStale)
        .activityBackgroundTint(nil)
        .widgetURL(WidgetTapDestination.player.url)
    } dynamicIsland: { context in
      DynamicIsland {
        // The leading and trailing regions sit beside the camera and are narrow, so the title
        // there truncated. They carry the glyph and the countdown; the title goes in the centre
        // region beneath the camera, which is wide enough for "End of Chapter".
        DynamicIslandExpandedRegion(.leading) {
          SleepTimerIslandGlyph()
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          SleepTimerRemainingText(state: context.state, isStale: context.isStale)
            .font(.title2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: 110, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          SleepTimerIslandCaption(state: context.state, isStale: context.isStale)
        }
        DynamicIslandExpandedRegion(.bottom) {
          SleepTimerButtons(state: context.state)
            .padding(.top, 10)
            .padding(.horizontal, 4)
        }
      } compactLeading: {
        Image(systemName: "moon.fill")
          .accessibilityLabel("Sleep timer")
      } compactTrailing: {
        SleepTimerRemainingText(state: context.state, isStale: context.isStale)
          .monospacedDigit()
          .frame(maxWidth: 52)
      } minimal: {
        Image(systemName: "moon.fill")
          .accessibilityLabel("Sleep timer")
      }
      .widgetURL(WidgetTapDestination.player.url)
    }
  }
}

struct SleepTimerLockScreenView: View {
  let state: SleepTimerActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label(SleepTimerActivityText.title(for: state.label), systemImage: "moon.fill")
          .font(.headline)
        Spacer(minLength: 8)
        SleepTimerRemainingText(state: state, isStale: isStale)
          .font(.title2.monospacedDigit().weight(.semibold))
      }
      if let detail = SleepTimerActivityText.detail(for: state, isStale: isStale) {
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      SleepTimerButtons(state: state)
    }
    .padding()
  }
}

/// The expanded island's leading glyph: the moon on a tinted disc, sized to fill the region's
/// height beside the camera.
struct SleepTimerIslandGlyph: View {
  var body: some View {
    Image(systemName: "moon.zzz.fill")
      .font(.title3)
      .foregroundStyle(.indigo)
      .frame(width: 44, height: 44)
      .background(.indigo.opacity(0.25), in: Circle())
      .accessibilityLabel("Sleep timer")
  }
}

/// The expanded island's centre: what kind of timer this is, and when playback stops or why the
/// countdown is not moving.
struct SleepTimerIslandCaption: View {
  let state: SleepTimerActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(spacing: 2) {
      Text(SleepTimerActivityText.title(for: state.label))
        .font(.subheadline.weight(.semibold))
      Group {
        if let detail = SleepTimerActivityText.detail(for: state, isStale: isStale) {
          Text(detail)
        } else if let endsAt = state.endsAt {
          Text("Stops at \(endsAt, style: .time)")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .minimumScaleFactor(0.8)
  }
}

/// A system-driven countdown while the timer runs; the frozen time left otherwise.
struct SleepTimerRemainingText: View {
  let state: SleepTimerActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    if !isStale, let endsAt = state.endsAt, endsAt > .now {
      Text(timerInterval: Date.now...endsAt, countsDown: true)
        .multilineTextAlignment(.trailing)
    } else {
      Text(SleepTimerActivityText.remaining(state.remainingSeconds))
        .multilineTextAlignment(.trailing)
    }
  }
}

struct SleepTimerButtons: View {
  let state: SleepTimerActivityAttributes.ContentState

  var body: some View {
    HStack(spacing: 12) {
      if state.canExtend {
        Button(intent: ExtendSleepTimerIntent()) {
          Label("15 min", systemImage: "plus")
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Extend by 15 minutes")
      }
      Button(intent: CancelSleepTimerIntent()) {
        Label("Cancel", systemImage: "xmark")
          .frame(maxWidth: .infinity)
      }
      .accessibilityLabel("Cancel sleep timer")
    }
    .buttonStyle(.bordered)
    .font(.subheadline.weight(.semibold))
  }
}

enum SleepTimerActivityText {
  static func title(for label: SleepTimerActivityLabel) -> String {
    switch label {
    case .countdown: "Sleep Timer"
    case .endOfChapter: "End of Chapter"
    case .endOfEpisode: "End of Episode"
    case .endOfBook: "End of Book"
    }
  }

  static func detail(for state: SleepTimerActivityAttributes.ContentState, isStale: Bool) -> String? {
    if isStale { return "Open Whirr to update" }
    if state.isFading { return "Fading out" }
    if !state.isRunning { return "Paused" }
    return nil
  }

  /// "14:32", or "1:05:00" from an hour up.
  static func remaining(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.up))
    let hours = total / 3600
    let minutes = total / 60 % 60
    let secs = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%d:%02d", minutes, secs)
  }
}

#Preview("Running", as: .content, using: SleepTimerActivityAttributes()) {
  SleepTimerLiveActivity()
} contentStates: {
  try! SleepTimerActivityAttributes.ContentState(
    label: .countdown, isRunning: true, endsAt: .now.addingTimeInterval(14 * 60 + 32),
    remainingSeconds: 14 * 60 + 32, canExtend: true, isFading: false)
  try! SleepTimerActivityAttributes.ContentState(
    label: .endOfChapter, isRunning: false, endsAt: nil, remainingSeconds: 8 * 60,
    canExtend: false, isFading: false)
}
