import Foundation

/// Minimal mutex so the fakes can be mutable and still satisfy Swift 6 strict concurrency.
/// Test-only; production services use actors or GRDB's own queueing (see ARCHITECTURE.md).
public final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  public init(_ value: Value) {
    self.storage = value
  }

  public var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      storage = newValue
    }
  }

  @discardableResult
  public func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }
}
