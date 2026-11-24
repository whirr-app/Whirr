import AppModel
import Foundation

/// `NativeFeedManaging`'s fake. It keeps a live set of feeds that have a credential, so
/// `saveBasicCredential` makes the next `hasCredential` answer true and `clearCredential` makes it
/// false, as the real store would. Every call is recorded in order.
///
/// Two gates park a call mid-flight: hold `credentialReadGate` to suspend `hasCredential` before
/// it answers, and `saveGate` to suspend `saveBasicCredential` before it stores anything.
public final class FakeNativeFeedManaging: NativeFeedManaging, @unchecked Sendable {
  /// One protocol call, with the arguments the tests assert on.
  public enum Call: Sendable, Equatable {
    case unsubscribe(feedID: Int64)
    case hasCredential(feedID: Int64)
    case saveBasicCredential(feedID: Int64, username: String, password: String)
    case clearCredential(feedID: Int64)
  }

  /// Every call, in order, recorded before the call is gated or answered.
  public let recorder = CallRecorder<Call>(label: "FakeNativeFeedManaging calls")

  /// Hold it (`hold()`) to park `hasCredential` until the test releases it. The read answers
  /// whether the feed had a credential when it started, whatever happens while it is parked.
  /// Open by default.
  public let credentialReadGate = TestGate<Void>(
    label: "FakeNativeFeedManaging.hasCredential")

  /// Hold it (`hold()`) to park `saveBasicCredential` before it stores the credential. Open by
  /// default.
  public let saveGate = TestGate<Void>(label: "FakeNativeFeedManaging.saveBasicCredential")

  private let configured: Locked<Set<Int64>>
  private let unsubscribeFailure = Locked<(any Error)?>(nil)
  private let readFailure = Locked<(any Error)?>(nil)
  private let saveFailure = Locked<(any Error)?>(nil)
  private let clearFailure = Locked<(any Error)?>(nil)
  private let unsubscribeHook = Locked<(@Sendable (Int64) async -> Void)?>(nil)

  /// - Parameter configuredFeedIDs: the feeds that start with a stored credential.
  public init(configuredFeedIDs: Set<Int64> = []) {
    configured = Locked(configuredFeedIDs)
  }

  /// The calls made so far, in order.
  public var calls: [Call] { recorder.calls }

  /// The feeds that currently have a stored credential.
  public var configuredFeedIDs: Set<Int64> { configured.value }

  /// Makes `unsubscribe` throw `error` after recording the call; `nil` makes it succeed again.
  public func stubUnsubscribeFailure(_ error: (any Error)?) {
    unsubscribeFailure.value = error
  }

  /// Makes `hasCredential` throw `error`; `nil` makes it answer again.
  public func stubReadFailure(_ error: (any Error)?) {
    readFailure.value = error
  }

  /// Makes `saveBasicCredential` throw `error` without storing anything; `nil` restores it.
  public func stubSaveFailure(_ error: (any Error)?) {
    saveFailure.value = error
  }

  /// Makes `clearCredential` throw `error` without clearing anything; `nil` restores it.
  public func stubClearFailure(_ error: (any Error)?) {
    clearFailure.value = error
  }

  /// Runs `hook` inside every `unsubscribe`, after the call is recorded and before any stubbed
  /// failure. A test records its own events there to interleave the unsubscribe with other steps
  /// (stopping playback first, say) in one ordered log.
  public func setUnsubscribeHook(_ hook: (@Sendable (Int64) async -> Void)?) {
    unsubscribeHook.value = hook
  }

  public func unsubscribe(feedId: Int64) async throws {
    recorder.record(.unsubscribe(feedID: feedId))
    if let hook = unsubscribeHook.value { await hook(feedId) }
    if let failure = unsubscribeFailure.value { throw failure }
  }

  public func hasCredential(feedId: Int64) async throws -> Bool {
    recorder.record(.hasCredential(feedID: feedId))
    let snapshot = configured.value.contains(feedId)
    await credentialReadGate.pass()
    if let failure = readFailure.value { throw failure }
    return snapshot
  }

  public func saveBasicCredential(username: String, password: String, feedId: Int64) async throws {
    recorder.record(
      .saveBasicCredential(feedID: feedId, username: username, password: password))
    await saveGate.pass()
    if let failure = saveFailure.value { throw failure }
    configured.withValue { _ = $0.insert(feedId) }
  }

  public func clearCredential(feedId: Int64) async throws {
    recorder.record(.clearCredential(feedID: feedId))
    if let failure = clearFailure.value { throw failure }
    configured.withValue { _ = $0.remove(feedId) }
  }
}
