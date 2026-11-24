import ABSApi
import Foundation

/// `FeedCredentialStoring`'s fake: an in-memory credential per feed that records every call in
/// order. Each operation can be made to throw, and `setSaveHook` runs a test's own code inside
/// `save`, for a test that needs to observe or disturb the world at that moment (read the
/// database, cancel the calling task).
public final class FakeFeedCredentialStoring: FeedCredentialStoring, @unchecked Sendable {
  /// One protocol call.
  public enum Call: Sendable, Equatable {
    case save(feedID: Int64)
    case load(feedID: Int64)
    case clear(feedID: Int64)
  }

  /// Every call in order, recorded before any hook runs or failure is thrown.
  public let recorder = CallRecorder<Call>(label: "FakeFeedCredentialStoring")
  public var calls: [Call] { recorder.calls }

  private let stored = Locked<[Int64: FeedCredential]>([:])
  private let saveFailure = Locked<(any Error)?>(nil)
  private let loadFailure = Locked<(any Error)?>(nil)
  private let clearFailure = Locked<(any Error)?>(nil)
  private let saveHook = Locked<(@Sendable (Int64) throws -> Void)?>(nil)

  public init() {}

  /// The credentials currently stored, by feed ID.
  public var credentials: [Int64: FeedCredential] { stored.value }

  /// Makes `save` throw `error` without storing anything; `nil` makes it succeed again.
  public func stubSaveFailure(_ error: (any Error)?) {
    saveFailure.value = error
  }

  /// Makes `load` throw `error`; `nil` makes it answer again.
  public func stubLoadFailure(_ error: (any Error)?) {
    loadFailure.value = error
  }

  /// Makes `clear` throw `error` without clearing anything; `nil` makes it succeed again.
  public func stubClearFailure(_ error: (any Error)?) {
    clearFailure.value = error
  }

  /// Runs `hook` inside every `save` with the feed ID, after the call is recorded and before any
  /// stubbed failure. A hook that throws fails the save without storing anything.
  public func setSaveHook(_ hook: (@Sendable (Int64) throws -> Void)?) {
    saveHook.value = hook
  }

  public func save(_ credential: FeedCredential, forFeedID feedID: Int64) throws {
    recorder.record(.save(feedID: feedID))
    if let hook = saveHook.value { try hook(feedID) }
    if let failure = saveFailure.value { throw failure }
    stored.withValue { $0[feedID] = credential }
  }

  public func load(forFeedID feedID: Int64) throws -> FeedCredential? {
    recorder.record(.load(feedID: feedID))
    if let failure = loadFailure.value { throw failure }
    return stored.value[feedID]
  }

  public func clear(forFeedID feedID: Int64) throws {
    recorder.record(.clear(feedID: feedID))
    if let failure = clearFailure.value { throw failure }
    stored.withValue { _ = $0.removeValue(forKey: feedID) }
  }
}
