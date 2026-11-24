import Foundation

/// `SearchModel`'s injected debounce seam, so tests never depend on a real timer. Debounce needs
/// a suspension point (unlike `SyncEngine.SyncClock`, which only reads `now()`): production
/// suspends for real wall-clock time, test fakes resume deterministically.
public protocol SearchClock: Sendable {
  func sleep() async
}

/// Production conformance: a fixed debounce window.
public struct SystemSearchClock: SearchClock, Sendable {
  private let nanoseconds: UInt64

  public init(milliseconds: Int = 300) {
    nanoseconds = UInt64(milliseconds) * 1_000_000
  }

  public func sleep() async {
    try? await Task.sleep(nanoseconds: nanoseconds)
  }
}
