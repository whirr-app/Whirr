import Foundation

/// Marks playback the Watch itself caused. A start or resume run for a Watch command must not ask
/// the Watch to pause, or it would pause the device that just handed over. The scope covers
/// the command's execution, and `isRecent` its short aftermath, because the phone's playing
/// transition is published after the command returns.
@MainActor
final class WatchCommandScope {
  static let grace: TimeInterval = 5
  private var depth = 0
  private var lastEndedAt: Date?
  private let now: @MainActor () -> Date

  init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }

  var isExecuting: Bool { depth > 0 }

  /// The position a Watch `.play` handed over, while that command executes.
  private var handed: (itemID: String, episodeID: String?, position: Double)?

  /// The handed-over position for the title now starting, if a Watch command named one for it.
  func handedPosition(itemID: String, episodeID: String?) -> Double? {
    guard depth > 0, let handed, handed.itemID == itemID, handed.episodeID == episodeID else { return nil }
    return handed.position
  }

  /// Executing, or finished within `grace`.
  var isRecent: Bool {
    depth > 0 || lastEndedAt.map { now().timeIntervalSince($0) < Self.grace } ?? false
  }

  func run<T>(
    handing position: (itemID: String, episodeID: String?, position: Double)? = nil, _ body: () async -> T
  ) async -> T {
    depth += 1
    let previous = handed
    if let position { handed = position }
    defer {
      depth -= 1
      handed = previous
      lastEndedAt = now()
    }
    return await body()
  }
}
