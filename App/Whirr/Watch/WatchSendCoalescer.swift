import Foundation

/// Coalesces a Watch send publisher's planning passes: one debounced pass at a time, and a pass
/// that a later schedule superseded publishes nothing.
///
/// The pass runs off a weak reference to the publisher that started it, so a pending pass never
/// keeps that publisher alive.
@MainActor
final class WatchSendCoalescer {
  private let debounce: Duration
  private var task: Task<Void, Never>?
  private var token = 0
  private var stopped = false

  init(debounce: Duration) {
    self.debounce = debounce
  }

  /// Starts a debounced pass, cancelling any pass still waiting. `run` receives this call's token
  /// and must check `isCurrent(_:)` after every suspension before it publishes, because a later
  /// schedule makes an earlier pass stale.
  func schedule(_ run: @escaping @MainActor (_ token: Int) async -> Void) {
    guard !stopped else { return }
    token &+= 1
    let token = token
    task?.cancel()
    let debounce = debounce
    task = Task { [weak self] in
      if debounce > .zero { try? await Task.sleep(for: debounce) }
      guard let self, !Task.isCancelled else { return }
      await run(token)
      if self.token == token { self.task = nil }
    }
  }

  /// Whether a pass started with `token` is still the one whose results may be applied.
  func isCurrent(_ token: Int) -> Bool {
    token == self.token
  }

  /// Set by `stop()`; a pass checks it after every suspension so a stopped publisher sends nothing.
  var isStopped: Bool { stopped }

  /// Refuses further passes and cancels the pending one. A pass already running sees `isStopped`
  /// and returns without publishing.
  func stop() {
    stopped = true
    task?.cancel()
    task = nil
  }

  /// Waits for the pending pass; tests observe the result through it.
  func settle() async {
    while let pending = task {
      await pending.value
      if task == nil { return }
    }
  }
}
