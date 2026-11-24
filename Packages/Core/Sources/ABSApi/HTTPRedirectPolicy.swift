import Foundation

/// The redirect decision every URLSession transport shares, and the delegate that applies it.
///
/// A redirect is followed only within the request's own origin, never for an authentication route,
/// never to a URL carrying credentials, and never from `https` down to `http`. A composition
/// outside ABSApi may supply its own `HTTPRedirectHandling` (ADR 0004's feed pool) to narrow that
/// further, for example by dropping a credential header before the hop.
///
/// `HTTPRedirectHandling` is per-request handling supplied by compositions outside the ABS client
/// (ADR 0004's feed pool). It returns the request to follow (possibly modified, e.g. with a
/// credential header removed) or nil to refuse the hop. `hopNumber` is 1-based and counts
/// redirects already followed plus this one within a single `send`.
public protocol HTTPRedirectHandling: Sendable {
  func handleRedirect(original: URL, proposed: URLRequest, hopNumber: Int) -> URLRequest?
}

/// The shared redirect decision used by foreground and background URLSession transports.
public enum ABSRedirectPolicy {
  public enum Decision: Sendable, Equatable {
    case allow
    case reject
  }

  public static func evaluate(
    original: URL,
    target: URL,
    isAuthenticationRoute: Bool
  ) -> Decision {
    guard isAuthenticationRoute == false else { return .reject }
    // Embedded userinfo, even an empty user, is a second set of credentials the app did not mint.
    // Origin equality ignores it, so refuse it explicitly on whichever URL carries it.
    guard original.user == nil, original.password == nil,
      target.user == nil, target.password == nil
    else { return .reject }
    guard FeedCredentialOrigin.sameOrigin(original, target) else { return .reject }

    // Keep this explicit even though origin equality already compares schemes. It documents the
    // security invariant and protects it if the origin comparison changes later.
    let originalScheme = original.scheme?.lowercased()
    let targetScheme = target.scheme?.lowercased()
    if originalScheme == "https", targetScheme != "https" { return .reject }
    return .allow
  }
}

struct ABSRedirectHandler: HTTPRedirectHandling {
  let isAuthenticationRoute: Bool

  func handleRedirect(original: URL, proposed: URLRequest, hopNumber _: Int) -> URLRequest? {
    guard let target = proposed.url,
      ABSRedirectPolicy.evaluate(
        original: original, target: target, isAuthenticationRoute: isAuthenticationRoute) == .allow
    else { return nil }
    return proposed
  }
}

final class URLSessionRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let originalURL: URL
  private let redirectHandler: any HTTPRedirectHandling
  private let hopLock = NSLock()
  private var hopNumber = 0

  init(originalURL: URL, redirectHandler: any HTTPRedirectHandling) {
    self.originalURL = originalURL
    self.redirectHandler = redirectHandler
  }

  convenience init(originalURL: URL, isAuthenticationRoute: Bool) {
    self.init(
      originalURL: originalURL,
      redirectHandler: ABSRedirectHandler(isAuthenticationRoute: isAuthenticationRoute))
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection _: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let hopNumber = nextHopNumber()
    guard
      let request = redirectHandler.handleRedirect(
        original: originalURL, proposed: request, hopNumber: hopNumber)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  private func nextHopNumber() -> Int {
    hopLock.lock()
    defer { hopLock.unlock() }
    hopNumber += 1
    return hopNumber
  }
}

/// A request that opted in through `HTTPRequest.reportingRefusedRedirect()` was answered with a
/// redirect `ABSRedirectPolicy` refused. `target` is the `Location` it named, resolved against the
/// request URL, or nil when the response gave none. Descriptions omit it: a redirect target is
/// server-chosen and may carry a host or query the logs must not print (SECURITY.md §7).
public struct RefusedRedirectError: Error, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let target: URL?

  public init(target: URL?) {
    self.target = target
  }

  public var description: String {
    "RefusedRedirectError(target: \(target == nil ? "nil" : "<redacted>"))"
  }

  public var debugDescription: String { description }
}
