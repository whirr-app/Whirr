import ABSApi
import Foundation

/// Tells a streaming start that failed because the server was not there from one that failed for a
/// reason the user can act on.
///
/// User-facing: an unrecognised error says "Couldn't start playback. Try again.", wrong advice
/// when the server is down.
///
/// Only a transport failure counts as an outage. Any HTTP response, including a 500, proves the
/// server answered and keeps its own error (as `ServerReachabilityEvent.responded` treats any
/// status code as proof of reachability).
public enum PlaybackStartFailureClassification: Sendable {
  public static func isServerUnreachable(_ error: any Error) -> Bool {
    // A cancelled request proves nothing either way: the app stopped waiting and the server was
    // never asked to answer. Treating it as an outage would blame the server for a screen the
    // user dismissed.
    if let urlError = error as? URLError {
      return urlError.code != .cancelled
    }
    if let apiError = error as? APIError {
      return apiError == .transport
    }
    return false
  }
}
