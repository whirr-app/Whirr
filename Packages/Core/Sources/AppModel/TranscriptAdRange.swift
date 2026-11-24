/// One stretch the transcript marks as an ad: what the player will skip, as the player joins it.
public struct TranscriptAdRange: Sendable, Equatable {
  public enum Origin: Sendable, Equatable {
    /// Found by analysis, from the audio or the learned library.
    case detected
    /// Found from the listener's transcript, as a host-read sponsor spot.
    case hostRead
    /// Marked by the listener.
    case listener
  }

  public let start: Double
  public let end: Double
  public let origin: Origin

  public init(start: Double, end: Double, origin: Origin) {
    self.start = start
    self.end = end
    self.origin = origin
  }
}
