import DesignSystem
import PlayerCore
import SwiftUI

/// What the restart banner says. Pure, so the wording is pinned without a view.
enum SleepTimerRestartPresentation {
  static let displayDuration: Double = 3

  /// The countdown's length when it has one, so the listener knows how long they have. Timers
  /// pinned to a boundary say only that the timer is back: end of chapter and end of item reduce
  /// to the same mode, and naming the wrong one would be worse than naming neither.
  static func message(for timer: SleepTimerState) -> String {
    guard case .countdown = timer.mode, let seconds = timer.configuredSeconds, seconds >= 60 else {
      return "Sleep timer restarted"
    }
    return "Sleep timer restarted for \(Int(seconds / 60)) min"
  }
}

/// A brief note over the bottom of the expanded player when a resume brings the sleep timer back.
/// It reacts to the change rather than the value, so opening the player later does not replay a
/// notice about something that already happened. A leaf of its own because it reads the live
/// timer, which ticks every second while a countdown runs.
struct SleepTimerRestartBanner: View {
  let player: any PlaybackControlling

  @State private var message: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let timer = player.quickActionsSleepTimer
    ZStack {
      if let message {
        banner(message)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.08), value: message)
    .allowsHitTesting(false)
    .onChange(of: timer.restartedOnResume) { _, restarted in
      message = restarted ? SleepTimerRestartPresentation.message(for: timer) : nil
    }
    .sensoryFeedback(trigger: message) { _, new in new == nil ? nil : .success }
    .task(id: message) {
      guard let message else { return }
      AccessibilityNotification.Announcement(message).post()
      try? await Task.sleep(for: .seconds(SleepTimerRestartPresentation.displayDuration))
      guard Task.isCancelled == false else { return }
      self.message = nil
    }
  }

  private func banner(_ message: String) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      Image(systemName: "moon.zzz")
        .font(WhirrTypeToken.headline.font)
        .frame(width: 28, height: 28)
        .background(.primary.opacity(0.08), in: Circle())
        .accessibilityHidden(true)

      Text(message)
        .font(WhirrTypeToken.body.font.weight(.semibold))
        .lineLimit(2)
    }
    .padding(.horizontal, WhirrSpacing.medium)
    .padding(.vertical, WhirrSpacing.xSmall)
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
    .background(.regularMaterial, in: Capsule())
    .overlay {
      Capsule().stroke(.primary.opacity(0.1), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    .padding(.horizontal, WhirrSpacing.medium)
    .padding(.bottom, WhirrSpacing.large)
  }
}
