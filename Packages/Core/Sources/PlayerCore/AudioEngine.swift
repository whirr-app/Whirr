import Foundation

/// The engine boundary PlayerCore commands (see ARCHITECTURE.md §4). The AVPlayer-backed adapter
/// lives in the app target and stays dumb. `AVPlayer`/`AVQueuePlayer` are `@MainActor`, so this
/// protocol is too, not `Sendable`; the production adapter and `PlayerController` both run on the
/// main actor and neither is an actor.
///
/// Every command after `load` applies to the track the latest `load` established. `load` alone
/// advances `generation`, and every event on `events` is tagged with the generation active when
/// its work started, so `PlayerController` can discard a stale event from a displaced track.
@MainActor
public protocol AudioEngine: AnyObject {
  /// Readiness, position, buffering, completion and failure events, tagged by the generation of
  /// the `load` call they belong to. One continuous stream for the adapter's lifetime, so a single
  /// consumer subscribes once (as with `AppLifecycle.transitions`).
  var events: AsyncStream<AudioEngineEvent> { get }

  /// Loads `track` and seeks to `localOffset` within it at `rate`, replacing whatever the engine
  /// was doing. Does not start playback; a `play` command decides that.
  ///
  /// With a `trim` map the engine plays only the kept audio, but every offset crossing this
  /// protocol stays in the file's own time. An engine that cannot honour it plays the track whole
  /// and reports `trimDeclined`, so the reducer's accounting follows what is heard.
  func load(track: PlaybackTrack, localOffset: Double, rate: Double, generation: Int, trim: PlayerTrimMap?)
  func play()
  func pause()
  /// Seeks within the loaded track without changing `generation`. A different track needs `load`.
  func seek(toLocalOffset offset: Double)
  func setRate(_ rate: Double)
  /// Sets output amplitude, 0...1. PlayerCore owns this value and always restores it to 1.0 when
  /// a fade ends or playback is reset, so an adapter never has to remember a fade.
  func setVolume(_ volume: Double)
  /// Reports `positionUpdated` the moment playback reaches `offset` in the currently loaded track,
  /// replacing any boundary set before; nil clears it. Periodic
  /// ticks are too coarse in the background to start a skip on time. A `load` clears the boundary;
  /// `PlayerReducer` sets it again after every load and seek.
  func setBoundary(atLocalOffset offset: Double?)
  func stop()
}

/// Why an engine command could not be carried out. `isRecoverable` distinguishes a failure
/// `PlayerReducer.handle(_:PlayerIntent)`'s `.retry` may retry (e.g. a transient stream error)
/// from one it may not (e.g. a malformed/unusable stream resource).
public struct AudioEngineFailure: Sendable, Equatable {
  public let isRecoverable: Bool
  /// The server rejected the stream request as unauthenticated. A narrower question than
  /// `isRecoverable`: retrying this failure with the credential the resource was already stamped
  /// with can only reproduce it, so it is the one category `PlayerController` renews stream
  /// authorization for before reloading (`StreamAuthorizationRenewing`).
  public let isAuthenticationFailure: Bool
  public let message: String

  public init(isRecoverable: Bool, isAuthenticationFailure: Bool = false, message: String) {
    self.isRecoverable = isRecoverable
    self.isAuthenticationFailure = isAuthenticationFailure
    self.message = message
  }

  /// Classifies an `AVPlayerItem`'s own failure, as the App-target adapter observes it: the
  /// item's `error` plus the HTTP status its error log last recorded (`0` when it recorded none).
  ///
  /// The stream path fetches through a Bearer-stamped asset inside AVFoundation, so a `401` never
  /// passes through the transport layer that owns the reactive refresh. It arrives here as a raw
  /// `NSURLError` (`NSURLErrorDomain` -1013), or as a plain `401` in the error log when
  /// AVFoundation reports only a generic media error. Both count.
  ///
  /// A `403` does not: it is a decision about the account, which renewing a token cannot change.
  public init(assetLoadError error: any Error, responseStatusCode: Int) {
    self.init(
      isRecoverable: true,
      isAuthenticationFailure: responseStatusCode == 401
        || Self.chainContainsAuthenticationError(error as NSError),
      message: error.localizedDescription)
  }

  /// Walks `NSUnderlyingErrorKey`, bounded: AVFoundation routinely wraps the URL-loading error
  /// one or two levels down inside its own `AVFoundationErrorDomain` error.
  private static func chainContainsAuthenticationError(_ error: NSError) -> Bool {
    var current: NSError? = error
    var depth = 0
    while let candidate = current, depth < 4 {
      if candidate.domain == NSURLErrorDomain,
        candidate.code == NSURLErrorUserAuthenticationRequired
          || candidate.code == NSURLErrorUserCancelledAuthentication
      {
        return true
      }
      current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
      depth += 1
    }
    return false
  }
}

/// One event `AudioEngine.events` emits, always tagged with the `generation` of the `load` call
/// it belongs to (see `AudioEngine`'s documentation for why).
public enum AudioEngineEvent: Sendable, Equatable {
  /// The engine can produce audio for the current generation. Emitted both after the initial
  /// `load` and after a mid-playback rebuffer recovers.
  case ready(generation: Int)
  /// The engine is waiting on data and cannot currently play.
  case buffering(generation: Int)
  /// The engine's current position within the loaded track, as that track's own local offset.
  /// `PlayerReducer` maps this back to the book's global position via `PlaybackTimeline`.
  case positionUpdated(generation: Int, localOffset: Double)
  /// The engine's measurement of the loaded track's full extent in its local timebase, emitted
  /// whenever AVFoundation resolves or revises it (possibly well after `ready` for a progressive
  /// stream). `PlayerReducer` only extends an under-running declared duration, never shrinks one.
  case durationObserved(generation: Int, localDuration: Double)
  /// The current track played to its end.
  case trackFinished(generation: Int)
  case failed(generation: Int, AudioEngineFailure)
  /// The `load` for this generation was given a trim map it could not honour, so the track plays
  /// whole. The reducer drops its map for the item without reloading.
  case trimDeclined(generation: Int)
}
