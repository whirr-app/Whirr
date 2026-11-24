import Foundation
import WatchPlayback
import WatchProtocol

/// Everything the session queue shares with the adapter, under one lock. A finished file is
/// recorded as a callback in flight, so a WatchKit background task is not completed before the
/// durable commit for it has run.
nonisolated final class WatchRSSTransferState: @unchecked Sendable {
  private let lock = NSLock()
  private var finishByTask: [Int: WatchRSSDownloadFinish] = [:]
  private var hopsByTask: [Int: [URL]] = [:]
  private var pendingCallbacks = 0
  private var backgroundCompletions: [@Sendable () -> Void] = []
  private var backgroundEventsFinished = false

  func recordFinish(_ finish: WatchRSSDownloadFinish, taskIdentifier: Int) {
    lock.lock()
    finishByTask[taskIdentifier] = finish
    pendingCallbacks += 1
    lock.unlock()
  }

  func recordHops(_ hops: [URL], taskIdentifier: Int) {
    lock.lock()
    hopsByTask[taskIdentifier] = hops
    lock.unlock()
  }

  /// Removes and returns everything recorded for one task.
  func take(taskIdentifier: Int) -> (finish: WatchRSSDownloadFinish?, hops: [URL]) {
    lock.lock()
    defer { lock.unlock() }
    #if DEBUG
      lastLoggedProgressStep.removeValue(forKey: taskIdentifier)
    #endif
    return (
      finishByTask.removeValue(forKey: taskIdentifier),
      hopsByTask.removeValue(forKey: taskIdentifier) ?? []
    )
  }

  #if DEBUG
    private var lastLoggedProgressStep: [Int: Int] = [:]

    /// True at most once per 5% of one transfer, so the diagnostic log takes one line per step
    /// however often the delegate reports progress. `fraction` below zero means the length is
    /// unknown, and that is logged once.
    func admitsProgressLine(taskIdentifier: Int, fraction: Double) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      let step = Int(fraction * 20)
      if let last = lastLoggedProgressStep[taskIdentifier], last >= step { return false }
      lastLoggedProgressStep[taskIdentifier] = step
      return true
    }
  #endif

  /// Releases the finished-file callback and returns the WatchKit completions that may now run.
  func endedCallback() -> [@Sendable () -> Void] {
    lock.lock()
    defer { lock.unlock() }
    pendingCallbacks = max(0, pendingCallbacks - 1)
    return drainableCompletions()
  }

  func addBackgroundCompletion(_ completion: @escaping @Sendable () -> Void) {
    lock.lock()
    backgroundEventsFinished = false
    backgroundCompletions.append(completion)
    lock.unlock()
  }

  /// Marks the session's events delivered and returns the completions ready to run: the system has
  /// delivered everything, and no finished file is still being committed. A newly created session
  /// with no events may never call this, so the adapter also calls it on a grace period.
  func noteEventsFinished() -> [@Sendable () -> Void] {
    lock.lock()
    defer { lock.unlock() }
    backgroundEventsFinished = true
    return drainableCompletions()
  }

  private func drainableCompletions() -> [@Sendable () -> Void] {
    guard backgroundEventsFinished, pendingCallbacks == 0, !backgroundCompletions.isEmpty else {
      return []
    }
    let completions = backgroundCompletions
    backgroundCompletions.removeAll()
    backgroundEventsFinished = false
    return completions
  }
}
