import Foundation

/// The production `PlaybackCadenceScheduling` conformance: a plain `Task.sleep`-backed deadline,
/// Foundation-only (ARCHITECTURE.md restricts Network/UIKit to App-side adapters, and a bare timer
/// needs neither). At most one deadline is pending: `reschedule` cancels the outstanding `Task`
/// first, and a cancelled task's `action` never runs. `Task.sleep` throws on cancellation, and the
/// `isCancelled` check after it guards a cancellation that lands as the sleep completes.
public actor SystemPlaybackCadenceScheduler: PlaybackCadenceScheduling {
  private var pending: Task<Void, Never>?

  public init() {}

  public func reschedule(after interval: TimeInterval, action: @escaping @Sendable () async -> Void) async {
    pending?.cancel()
    pending = Task {
      let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard Task.isCancelled == false else { return }
      await action()
    }
  }

  public func cancelPending() async {
    pending?.cancel()
    pending = nil
  }
}
