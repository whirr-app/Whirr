import Foundation

/// Decides whether a listen reported by the Watch becomes the phone's state for that episode. Pure, and deliberately local to `Persistence`: `WatchProtocol`'s
/// `WatchOfflineConflictPolicy` cannot be imported here, so the four thresholds are copied.
///
/// The rule is the newer listen wins, with the further position breaking a clock tie, as the ABS
/// policy has it. The difference is the near-zero exception: `WatchOfflineConflictPolicy` lets real
/// Watch progress beat a near-zero shared row even when the shared row is newer, because a server
/// reset may be an empty row. Here the phone is the only writer, so a newer near-zero row is a
/// deliberate reset or "mark unplayed" the listener made after listening on the Watch, and it
/// holds. Only a Watch listen that is genuinely newer, or further inside the tie window, moves the
/// row back.
public enum RSSEpisodePeerListen {
  public static let tieWindow: TimeInterval = 60
  public static let futureClockAllowance: TimeInterval = 30
  public static let positionTolerance = 1.0
  public static let meaningfulPosition = 1.0

  public enum Reason: String, Sendable, Equatable, CaseIterable {
    case invalid
    case noListening
    case converged
    case phoneNewer
    case phoneFurther
  }

  public enum Outcome: Sendable, Equatable {
    /// Write the Watch's position and finish with this `updatedAt`.
    case apply(updatedAt: Date)
    case reject(Reason)
  }

  /// `phone` is the stored row, or `nil` when the episode has no state yet. `duration` is the
  /// best-known episode length, used only to bound a corrupt position.
  public static func resolve(
    watchPosition: Double,
    watchFinished: Bool,
    watchListenedAt: Date,
    phone: (position: Double, finished: Bool, updatedAt: Date)?,
    duration: Double?,
    now: Date
  ) -> Outcome {
    guard valid(watchPosition, duration: duration),
      watchListenedAt.timeIntervalSince1970.isFinite
    else { return .reject(.invalid) }

    guard watchPosition >= meaningfulPosition || watchFinished else {
      return .reject(.noListening)
    }

    guard let phone else { return .apply(updatedAt: watchListenedAt) }

    if abs(watchPosition - phone.position) <= positionTolerance, watchFinished == phone.finished {
      return .reject(.converged)
    }

    let watchFurther = further(
      watchPosition: watchPosition, watchFinished: watchFinished,
      phonePosition: phone.position, phoneFinished: phone.finished)
    let horizon = now.addingTimeInterval(futureClockAllowance)

    // A tie may be won by a Watch listen slightly older than the row; the row's `updatedAt` still
    // never moves backward, because the merge across devices compares it.
    if watchListenedAt > horizon {
      // A clock far in the future cannot order the two listens; treat it as the tie it looks like
      // and stamp the write with this device's clock.
      return watchFurther ? .apply(updatedAt: max(now, phone.updatedAt)) : .reject(.phoneFurther)
    }

    if abs(watchListenedAt.timeIntervalSince(phone.updatedAt)) <= tieWindow {
      return watchFurther
        ? .apply(updatedAt: max(watchListenedAt, phone.updatedAt)) : .reject(.phoneFurther)
    }

    if watchListenedAt > phone.updatedAt {
      return .apply(updatedAt: watchListenedAt)
    }
    // Deliberately no near-zero exception: the phone's reset stands.
    return .reject(.phoneNewer)
  }

  private static func further(
    watchPosition: Double, watchFinished: Bool,
    phonePosition: Double, phoneFinished: Bool
  ) -> Bool {
    if watchFinished != phoneFinished {
      return watchFinished
    }
    return watchPosition > phonePosition
  }

  private static func valid(_ position: Double, duration: Double?) -> Bool {
    guard position.isFinite, position >= 0 else { return false }
    guard let duration, duration.isFinite, duration > 0 else { return true }
    return position <= duration + positionTolerance
  }
}
