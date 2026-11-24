import Foundation
import Persistence

/// Cancel flag the batch reads between episodes. It never cancels an in-flight save task.
public final class NativeEpisodeServerSaveBatchCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

public struct NativeEpisodeServerSaveBatchRequest: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let feedId: Int64
  /// Ordered, already de-duplicated row ids supplied by the caller.
  public let episodeIds: [Int64]
  /// The caller's destination choice, if a previous run already asked the user.
  public let choice: ServerPodcastSaveChoice?

  public init(feedId: Int64, episodeIds: [Int64], choice: ServerPodcastSaveChoice?) {
    self.feedId = feedId
    self.episodeIds = episodeIds
    self.choice = choice
  }

  public var description: String {
    "NativeEpisodeServerSaveBatchRequest(feedId: \(feedId), episodeCount: \(episodeIds.count), "
      + "hasChoice: \(choice != nil))"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public struct NativeEpisodeServerSaveBatchEpisodeOutcome: Sendable, Equatable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let episodeId: Int64
  public let outcome: NativeEpisodeServerSaveOutcome

  public init(episodeId: Int64, outcome: NativeEpisodeServerSaveOutcome) {
    self.episodeId = episodeId
    self.outcome = outcome
  }

  public var description: String {
    "NativeEpisodeServerSaveBatchEpisodeOutcome(episodeId: <redacted>, "
      + "outcome: \(outcome.description))"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public enum NativeEpisodeServerSaveBatchStop: Sendable, Equatable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  case completed
  case cancelled
  case needsChoice(
    episodeId: Int64,
    attemptID: Int64,
    prompt: NativeEpisodeServerSaveChoicePrompt)
  case failed(episodeId: Int64, category: NativeEpisodeServerSaveErrorCategory)
  case uncertain(
    episodeId: Int64,
    attemptID: Int64,
    category: NativeEpisodeServerSaveErrorCategory)

  public var description: String {
    switch self {
    case .completed: return "NativeEpisodeServerSaveBatchStop(completed)"
    case .cancelled: return "NativeEpisodeServerSaveBatchStop(cancelled)"
    case .needsChoice: return "NativeEpisodeServerSaveBatchStop(needsChoice)"
    case .failed(_, let category):
      return "NativeEpisodeServerSaveBatchStop(failed, category: \(category.rawValue))"
    case .uncertain(_, _, let category):
      return "NativeEpisodeServerSaveBatchStop(uncertain, category: \(category.rawValue))"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public struct NativeEpisodeServerSaveBatchResult: Sendable, Equatable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let outcomes: [NativeEpisodeServerSaveBatchEpisodeOutcome]
  public let stop: NativeEpisodeServerSaveBatchStop
  public let notAttempted: [Int64]
  public let serverItemID: String?

  public init(
    outcomes: [NativeEpisodeServerSaveBatchEpisodeOutcome],
    stop: NativeEpisodeServerSaveBatchStop,
    notAttempted: [Int64],
    serverItemID: String?
  ) {
    self.outcomes = outcomes
    self.stop = stop
    self.notAttempted = notAttempted
    self.serverItemID = serverItemID
  }

  public var description: String {
    "NativeEpisodeServerSaveBatchResult(outcomeCount: \(outcomes.count), "
      + "stop: \(stop.description), "
      + "notAttemptedCount: \(notAttempted.count), hasServerItemID: \(serverItemID != nil))"
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

public protocol NativeEpisodeServerSaveBatchSaving: Sendable {
  func saveBatch(
    _ request: NativeEpisodeServerSaveBatchRequest,
    cancellation: NativeEpisodeServerSaveBatchCancellationToken,
    onEpisodeOutcome: @escaping @Sendable (NativeEpisodeServerSaveBatchEpisodeOutcome) async -> Void
  ) async -> NativeEpisodeServerSaveBatchResult
}

public struct NoOpNativeEpisodeServerSaveBatchSaving: NativeEpisodeServerSaveBatchSaving {
  public init() {}

  public func saveBatch(
    _ request: NativeEpisodeServerSaveBatchRequest,
    cancellation: NativeEpisodeServerSaveBatchCancellationToken,
    onEpisodeOutcome: @escaping @Sendable (NativeEpisodeServerSaveBatchEpisodeOutcome) async -> Void
  ) async -> NativeEpisodeServerSaveBatchResult {
    guard let first = request.episodeIds.first else {
      return NativeEpisodeServerSaveBatchResult(
        outcomes: [], stop: .completed, notAttempted: [], serverItemID: nil)
    }
    let outcome = NativeEpisodeServerSaveOutcome.failed(
      attemptID: nil, state: .failed, category: .permissionChanged)
    let entry = NativeEpisodeServerSaveBatchEpisodeOutcome(episodeId: first, outcome: outcome)
    return NativeEpisodeServerSaveBatchResult(
      outcomes: [entry],
      stop: .failed(episodeId: first, category: .permissionChanged),
      notAttempted: Array(request.episodeIds.dropFirst()),
      serverItemID: nil)
  }
}
