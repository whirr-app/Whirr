import Foundation

/// The boundary that wakes `PlayerController` when a sustained stream buffer reaches its
/// deadline. It is main-actor-bound like `AudioEngine`: one continuous stream belongs to the
/// scheduler for its entire lifetime, and the controller is its one consumer.
@MainActor
public protocol PlayerStallScheduling: AnyObject {
  /// Deadlines this scheduler has reached, each carrying the token it was scheduled with.
  var timeouts: AsyncStream<Int> { get }
  /// Replaces any pending deadline with a new one `seconds` from now, tagged `token`.
  func schedule(after seconds: Double, token: Int)
  /// Drops any pending deadline. Idempotent.
  func cancel()
}

/// Production stall scheduler backed by one cancellable task. Replacing a deadline cancels the
/// previous task before installing the new one, so at most one timeout can be pending at a time.
@MainActor
public final class TaskPlayerStallScheduler: PlayerStallScheduling {
  public let timeouts: AsyncStream<Int>

  private let continuation: AsyncStream<Int>.Continuation
  private var task: Task<Void, Never>?

  public init() {
    var continuation: AsyncStream<Int>.Continuation!
    timeouts = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  public func schedule(after seconds: Double, token: Int) {
    task?.cancel()
    task = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(seconds))
        guard Task.isCancelled == false else { return }
        self?.continuation.yield(token)
      } catch {
        // Cancellation is the normal path when buffering resolves or a new deadline supersedes it.
      }
    }
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }

  deinit {
    task?.cancel()
    continuation.finish()
  }
}
