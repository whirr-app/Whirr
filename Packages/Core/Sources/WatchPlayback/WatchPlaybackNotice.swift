/// What holds the Watch's library while it restores, installs, signs out or starts a download.
/// A start waits for none of them; it is refused, and says which.
public enum WatchBusyHolder: Sendable, Equatable {
  case restoring
  case installing
  case signingOut
  case downloading
}

/// Whether a start can begin, and if not, why.
public enum WatchPlaybackReadiness: Sendable, Equatable {
  case ready
  /// The saved account is still being restored at launch.
  case launching
  case signedOut
  case busy(WatchBusyHolder)

  public var refusal: WatchPlaybackNotice? {
    switch self {
    case .ready: nil
    case .launching: .launching
    case .signedOut: .signedOut
    case .busy(let holder): .busy(holder)
    }
  }
}

/// A message the Watch's playback shows. Every refusal and failure has one; a cancellation has
/// none.
public enum WatchPlaybackNotice: Sendable, Equatable {
  case nativeFeed
  case launching
  case signedOut
  case busy(WatchBusyHolder)
  case nothingToResume
  case startFailed
  case resumeFailed
  case seekFailed
  case streamFailed
  case streamLost
  case downloadFailed
  case audioReset
  case reconnectToStream
  case phoneUnavailable
  case phoneUnreachable

  public var text: String {
    switch self {
    case .nativeFeed: "Send this episode to your Watch from iPhone."
    case .launching: "Whirr is still starting. Try again in a moment."
    case .signedOut: "On your iPhone, open Whirr → Settings → Apple Watch."
    case .busy(.restoring): "Whirr is still connecting. Try again in a moment."
    case .busy(.installing): "Whirr is connecting to your iPhone. Try again in a moment."
    case .busy(.signingOut): "Whirr is signing out."
    case .busy(.downloading): "Whirr is starting a download. Try again in a moment."
    case .nothingToResume: "Choose something to play."
    case .startFailed: "Couldn’t start on Watch. Check the connection and audio output, then retry."
    case .resumeFailed: "Choose an available audio output and try again."
    case .seekFailed: "Couldn’t seek. Try again."
    case .streamFailed: "Couldn’t stream this on Watch. Check the connection, or download it first."
    case .streamLost: "Lost the stream. Tap play to try again."
    case .downloadFailed: "Couldn’t play this download. Remove it and download it again."
    case .audioReset: "Audio stopped. Tap play to continue."
    case .reconnectToStream: "Reconnect using your iPhone to continue streaming."
    case .phoneUnavailable: "Open Whirr on your nearby iPhone, then try again."
    case .phoneUnreachable: "Couldn’t reach iPhone. Paused on Watch."
    }
  }
}
