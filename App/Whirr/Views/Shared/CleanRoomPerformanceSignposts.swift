import os

enum CleanRoomPerformanceSignposts {
  private static let signposter = OSSignposter(
    subsystem: "com.remoteconcern.whirr", category: .pointsOfInterest)

  static func withInterval<Result>(
    _ name: StaticString, operation: () throws -> Result
  ) rethrows -> Result {
    guard signposter.isEnabled else { return try operation() }
    return try signposter.withIntervalSignpost(name, around: operation)
  }

  static func beginInterval(_ name: StaticString, object: AnyObject) -> OSSignpostIntervalState? {
    guard signposter.isEnabled else { return nil }
    return signposter.beginInterval(name, id: signposter.makeSignpostID(from: object))
  }

  static func endInterval(_ name: StaticString, state: OSSignpostIntervalState?) {
    guard let state else { return }
    signposter.endInterval(name, state)
  }
}
