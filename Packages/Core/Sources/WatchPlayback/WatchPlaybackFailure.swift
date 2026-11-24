import ABSApi
import Foundation

/// What the Watch's audio engine throws. It lives here, not in the app, so `WatchPlaybackFailure`
/// can classify it. A superseded operation throws `CancellationError` instead.
public enum WatchAudioEngineError: Error, Sendable, Equatable {
  /// Nothing is loaded, or the loaded item cannot be played.
  case unplayable
  /// The audio session refused activation or no output route is available.
  case noOutput
  /// The player abandoned a seek that no newer operation superseded.
  case seekUnfinished
}

/// How a Watch start, resume, seek or renewal ended when it did not succeed, as far as the screen
/// needs to know. `cancelled` is not a failure: a pause, stop, newer start, handoff or logout
/// superseded the operation, and the screen says nothing. Anything else gets the message of
/// the request that failed.
public enum WatchPlaybackFailure: Sendable, Equatable {
  case cancelled
  case failed

  public var showsMessage: Bool { self != .cancelled }

  public init(_ error: any Error) {
    let superseded =
      switch error {
      case is CancellationError: true
      case let error as URLError: error.code == .cancelled
      case let error as WatchPlaybackCoordinatorError: error == .cancelled
      // A request from a session that has since been replaced.
      case let error as WatchLibraryError: error == .staleRequest
      case let error as APIError: error == .cancelled
      default: false
      }
    self = superseded ? .cancelled : .failed
  }
}
