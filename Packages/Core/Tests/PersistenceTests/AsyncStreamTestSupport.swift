import Foundation

enum AsyncStreamTestSupport {
  static func first<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
    for await value in stream { return value }
    return nil
  }
}
