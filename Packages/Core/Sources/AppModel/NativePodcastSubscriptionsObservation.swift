import Foundation
import Persistence

/// Adapts the device preference boundary for aggregate Home observations.
///
/// A finite stream that emits no value has no enabled-state checkpoint to offer. Treating that
/// case as `false` lets an aggregate reach a deterministic, safe projection while preserving the
/// loading state for a stream that is still open and has not emitted yet.
extension NativePodcastSubscriptionsReading {
  func observeEnabledOrFalse() -> AsyncStream<Bool> {
    let source = observeEnabled()
    return AsyncStream { continuation in
      let task = Task {
        var emitted = false
        for await enabled in source {
          emitted = true
          continuation.yield(enabled)
        }
        if emitted == false && Task.isCancelled == false {
          continuation.yield(false)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
