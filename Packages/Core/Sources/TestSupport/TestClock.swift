import Foundation

/// A movable wall clock for tests that need to read `now` and advance it between fetches. The
/// default start is the epoch the Ebook delivery tests pin their stamped floors to.
public final class TestClock: @unchecked Sendable {
  private let current: Locked<Date>

  public init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
    current = Locked(date)
  }

  public var now: Date { current.value }

  public func advance(by interval: TimeInterval) {
    current.withValue { $0 = $0.addingTimeInterval(interval) }
  }
}
