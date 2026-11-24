import AppModel
import AuthenticationServices
import Foundation
import SwiftUI

/// The browser single sign-on runs in: SwiftUI's `WebAuthenticationSession`, which presents
/// `ASWebAuthenticationSession` from the calling view's window.
///
/// The callback returns here, never through `onOpenURL`. The `whirr` scheme is also registered for
/// widget links, but `RootView.onOpenURL` accepts only `whirr://widget/…`, so a stray
/// `whirr://oauth` link reaches no code path (SECURITY.md rule 10). No additional header fields:
/// the first page is the identity provider's, and proxy headers never go to another address
/// (SECURITY.md rule 5).
struct SingleSignOnBrowser: SingleSignOnBrowsing {
  let session: WebAuthenticationSession

  func authenticate(at url: URL, callbackScheme: String, prefersEphemeralSession: Bool) async throws -> URL? {
    do {
      return try await session.authenticate(
        using: url, callback: .customScheme(callbackScheme),
        preferredBrowserSession: prefersEphemeralSession ? .ephemeral : .shared,
        additionalHeaderFields: [:])
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      return nil
    }
  }
}
