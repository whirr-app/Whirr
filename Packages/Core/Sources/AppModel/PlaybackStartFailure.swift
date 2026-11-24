/// Why playback did not begin, together with who was waiting for it.
///
/// The same message arrives from a play the user just tapped and from the automatic continuation
/// after a title completes. The first has someone looking at the screen; the second typically
/// happens with the device pocketed. A surface that cannot tell them apart either interrupts a
/// listener who asked for nothing or stays silent for one who is waiting.
public struct PlaybackStartFailure: Sendable, Equatable {
  public enum Origin: Sendable, Equatable {
    /// A play the user asked for and is waiting on.
    case requested
    /// Automatic continuation into the next queued title after one finished.
    case queueAdvance
    /// Automatic continuation into the active smart list's next episode (ADR 0016). Surfaces like
    /// `.queueAdvance`: silently, in the player's recoverable-error phase.
    case listAdvance

    /// True for the continuations nobody is waiting on. Neither ends a smart list run.
    public var isAutomatic: Bool { self != .requested }
  }

  public let message: String
  public let origin: Origin

  public init(message: String, origin: Origin) {
    self.message = message
    self.origin = origin
  }
}
