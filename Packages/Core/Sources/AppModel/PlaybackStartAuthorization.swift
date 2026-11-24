/// An optional device-ownership gate installed by the application composition root. A returned
/// position belongs to the requested selection only; an unavailable prior owner leaves playback
/// stopped with actionable copy rather than opening another server session.
public enum PlaybackStartAuthorization: Sendable, Equatable {
  case allowed(position: Double?)
  case denied(message: String)
}
