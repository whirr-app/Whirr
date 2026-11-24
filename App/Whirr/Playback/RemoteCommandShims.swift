import MediaPlayer

/// The slice of `MPRemoteCommandCenter` behaviour `RemoteCommandAdapter` needs, wrapped so
/// `RemoteCommandAdapterTests` can inject a fake instead of touching the process-wide
/// `MPRemoteCommandCenter.shared()`. Handler closures take plain values `PlayerCore` understands,
/// not `MPRemoteCommandEvent`, which has no public initialiser a test could construct. Setting a
/// handler also enables that command.
@MainActor
protocol RemoteCommandRegistering: AnyObject {
  func setPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setTogglePlayPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setStopHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setSkipForwardHandler(
    intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setSkipBackwardHandler(
    intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setNextTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setPreviousTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus)
  func setChangePlaybackPositionHandler(_ handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus)
  func setChangePlaybackRateHandler(_ handler: @escaping (Double) -> MPRemoteCommandHandlerStatus)
  /// Replaces the intervals the skip glyphs show, leaving the handlers in place.
  func setSkipIntervals(forwardSeconds: TimeInterval, backwardSeconds: TimeInterval)
  /// The rates the system's rate control steps through.
  func setSupportedPlaybackRates(_ rates: [Double])
  /// Removes every target this adapter registered, across every command it touched.
  func removeAllTargets()
}

/// Real `RemoteCommandRegistering`, wrapping the actual `MPRemoteCommandCenter`. `positionTime`/
/// `playbackRate` are read off the concrete `MPRemoteCommandEvent` subclass here, the only place
/// that type is touched, and handed to callers as plain values.
@MainActor
final class RealRemoteCommandCenter: RemoteCommandRegistering {
  private let center: MPRemoteCommandCenter

  init(center: MPRemoteCommandCenter = .shared()) {
    self.center = center
  }

  func setPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    center.playCommand.isEnabled = true
    center.playCommand.addTarget { _ in handler() }
  }

  func setPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    center.pauseCommand.isEnabled = true
    center.pauseCommand.addTarget { _ in handler() }
  }

  func setTogglePlayPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    center.togglePlayPauseCommand.isEnabled = true
    center.togglePlayPauseCommand.addTarget { _ in handler() }
  }

  func setStopHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    center.stopCommand.isEnabled = true
    center.stopCommand.addTarget { _ in handler() }
  }

  func setSkipForwardHandler(
    intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus
  ) {
    center.skipForwardCommand.isEnabled = true
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: intervalSeconds)]
    center.skipForwardCommand.addTarget { _ in handler() }
  }

  func setSkipBackwardHandler(
    intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus
  ) {
    center.skipBackwardCommand.isEnabled = true
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: intervalSeconds)]
    center.skipBackwardCommand.addTarget { _ in handler() }
  }

  func setNextTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    center.nextTrackCommand.isEnabled = true
    center.nextTrackCommand.addTarget { _ in handler() }
  }

  func setPreviousTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {
    center.previousTrackCommand.isEnabled = true
    center.previousTrackCommand.addTarget { _ in handler() }
  }

  func setChangePlaybackPositionHandler(_ handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus) {
    center.changePlaybackPositionCommand.isEnabled = true
    center.changePlaybackPositionCommand.addTarget { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      return handler(event.positionTime)
    }
  }

  func setChangePlaybackRateHandler(_ handler: @escaping (Double) -> MPRemoteCommandHandlerStatus) {
    center.changePlaybackRateCommand.isEnabled = true
    center.changePlaybackRateCommand.addTarget { event in
      guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
      return handler(Double(event.playbackRate))
    }
  }

  func setSkipIntervals(forwardSeconds: TimeInterval, backwardSeconds: TimeInterval) {
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: forwardSeconds)]
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: backwardSeconds)]
  }

  func setSupportedPlaybackRates(_ rates: [Double]) {
    center.changePlaybackRateCommand.supportedPlaybackRates = rates.map { NSNumber(value: $0) }
  }

  func removeAllTargets() {
    center.playCommand.removeTarget(nil)
    center.pauseCommand.removeTarget(nil)
    center.togglePlayPauseCommand.removeTarget(nil)
    center.stopCommand.removeTarget(nil)
    center.skipForwardCommand.removeTarget(nil)
    center.skipBackwardCommand.removeTarget(nil)
    center.nextTrackCommand.removeTarget(nil)
    center.previousTrackCommand.removeTarget(nil)
    center.changePlaybackPositionCommand.removeTarget(nil)
    center.changePlaybackRateCommand.removeTarget(nil)
  }
}
