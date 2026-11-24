import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for `RemoteCommandRegistering`. Captures every handler that
/// `RemoteCommandAdapter.register()` wires, and counts setter calls so duplicate registration is
/// visible. Never touches the real, process-wide `MPRemoteCommandCenter.shared()`.
@MainActor
final class FakeRemoteCommandRegistering: RemoteCommandRegistering {
  private(set) var playHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var pauseHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var togglePlayPauseHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var stopHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var skipForwardHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var skipForwardIntervalSeconds: TimeInterval?
  private(set) var skipBackwardHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var skipBackwardIntervalSeconds: TimeInterval?
  private(set) var nextTrackHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var previousTrackHandler: (() -> MPRemoteCommandHandlerStatus)?
  private(set) var changePlaybackPositionHandler: ((TimeInterval) -> MPRemoteCommandHandlerStatus)?
  private(set) var changePlaybackRateHandler: ((Double) -> MPRemoteCommandHandlerStatus)?

  /// Incremented by every `set*Handler` call, so a test can assert each command is registered
  /// exactly once even if `register()` runs twice.
  private(set) var setterCallCount = 0
  private(set) var removeAllTargetsCallCount = 0
  private(set) var skipIntervalUpdates: [[TimeInterval]] = []
  private(set) var supportedPlaybackRates: [[Double]] = []

  func setSkipIntervals(forwardSeconds: TimeInterval, backwardSeconds: TimeInterval) {
    skipIntervalUpdates.append([forwardSeconds, backwardSeconds])
    skipForwardIntervalSeconds = forwardSeconds
    skipBackwardIntervalSeconds = backwardSeconds
  }

  func setSupportedPlaybackRates(_ rates: [Double]) {
    supportedPlaybackRates.append(rates)
  }

  func setPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    playHandler = handler
  }

  func setPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    pauseHandler = handler
  }

  func setTogglePlayPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    togglePlayPauseHandler = handler
  }

  func setStopHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    stopHandler = handler
  }

  func setSkipForwardHandler(
    intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus
  ) {
    setterCallCount += 1
    skipForwardIntervalSeconds = intervalSeconds
    skipForwardHandler = handler
  }

  func setSkipBackwardHandler(
    intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus
  ) {
    setterCallCount += 1
    skipBackwardIntervalSeconds = intervalSeconds
    skipBackwardHandler = handler
  }

  func setNextTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    nextTrackHandler = handler
  }

  func setPreviousTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    previousTrackHandler = handler
  }

  func setChangePlaybackPositionHandler(_ handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    changePlaybackPositionHandler = handler
  }

  func setChangePlaybackRateHandler(_ handler: @escaping (Double) -> MPRemoteCommandHandlerStatus) {
    setterCallCount += 1
    changePlaybackRateHandler = handler
  }

  func removeAllTargets() {
    removeAllTargetsCallCount += 1
  }
}
