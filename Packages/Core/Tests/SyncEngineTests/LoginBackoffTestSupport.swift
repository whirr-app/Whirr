import Foundation

/// A deterministic, thread-safe clock source for admission-backoff tests.
final class MutableDateSource: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    date.addTimeInterval(interval)
    lock.unlock()
  }
}
