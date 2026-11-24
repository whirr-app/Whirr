import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for the account-scoped playback availability and recovery binding. Kept separate
/// from `FakeAdapterPlaybackControlling` so tests can prove the adapter does not infer a terminal
/// transport failure from PlayerCore's phase alone.
@MainActor
final class FakePlaybackAvailability: PlaybackAvailabilityProviding {
  var unavailableReason: ServerUnreachableReason?
  var isTerminalRemotePlaybackFailure = false
  var recoveryResult = true
  private(set) var recoveryCallCount = 0
  private var changeHandler: (@MainActor () -> Void)?

  func setChangeHandler(_ handler: (@MainActor () -> Void)?) {
    changeHandler = handler
  }

  func notifyChange() {
    changeHandler?()
  }

  func recoverPlayback() -> Bool {
    recoveryCallCount += 1
    return recoveryResult
  }

  var freshLocalSessionResumeResult = false
  private(set) var freshLocalSessionResumeCallCount = 0

  func resumeThroughFreshLocalSessionIfLatched() -> Bool {
    freshLocalSessionResumeCallCount += 1
    return freshLocalSessionResumeResult
  }
}
