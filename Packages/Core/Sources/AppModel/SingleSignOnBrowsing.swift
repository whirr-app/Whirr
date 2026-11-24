import Foundation

/// The browser session single sign-on runs in. The App adapts SwiftUI's
/// `WebAuthenticationSession`; tests use a fake. The screen passes one in for each sign-in rather
/// than composition holding one, because the session belongs to the presenting view.
@MainActor
public protocol SingleSignOnBrowsing {
  /// Opens `url` and returns the URL the browser was sent to on `callbackScheme`, or nil when the
  /// user closed the browser. A cancel is not an error: the screen stays as it was, silently.
  ///
  /// `prefersEphemeralSession` keeps the identity provider's cookies out of Safari's shared jar
  /// (setup is ephemeral, same-account recovery is shared).
  func authenticate(at url: URL, callbackScheme: String, prefersEphemeralSession: Bool) async throws -> URL?
}
