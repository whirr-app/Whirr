import Foundation
import Testing

@testable import ABSApi

@Suite("HTTP transport security")
struct HTTPTypesTests {
  @Test("dedicated sessions have no shared cookie, credential, or URL cache state")
  func dedicatedSessionConfigurationIsIsolated() {
    let configuration = URLSessionHTTPClient.makeDedicatedSession().configuration

    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.httpCookieAcceptPolicy == .never)
  }

  @Test("foreground sessions apply distinct ordinary-API and progress-sync resource budgets")
  func dedicatedSessionConfigurationsApplyTimeoutPolicies() {
    let ordinary = URLSessionHTTPClient.makeDedicatedSession(for: .ordinaryAPI).configuration
    let progressSync = URLSessionHTTPClient.makeDedicatedSession(for: .progressSync).configuration

    #expect(ordinary.timeoutIntervalForRequest == 15)
    #expect(ordinary.timeoutIntervalForResource == 120)
    #expect(progressSync.timeoutIntervalForRequest == 15)
    #expect(progressSync.timeoutIntervalForResource == 30)
  }

  @Test("artwork transport gets its own longer budget than ordinary API calls")
  func artworkSessionConfigurationAppliesTimeoutPolicy() {
    let artwork = URLSessionHTTPClient.makeDedicatedSession(for: .coverArtwork).configuration

    // A cover the server has not resized yet can take far longer than an API call that only reads
    // a row. Fifteen seconds is what leaves the slowest covers permanently blank.
    #expect(artwork.timeoutIntervalForRequest == 60)
    #expect(artwork.timeoutIntervalForResource == 300)
  }

  @Test("cover requests use the artwork session, not the shared API pool")
  func coverRequestRoutesToArtworkSession() async throws {
    let ordinaryConfiguration = URLSessionConfiguration.ephemeral
    ordinaryConfiguration.protocolClasses = [CannotConnectURLProtocol.self]
    let artworkConfiguration = URLSessionConfiguration.ephemeral
    artworkConfiguration.protocolClasses = [TimeoutURLProtocol.self]
    let client = URLSessionHTTPClient(
      ordinarySession: URLSession(configuration: ordinaryConfiguration),
      progressSyncSession: URLSession(configuration: ordinaryConfiguration),
      downloadSession: URLSession(configuration: ordinaryConfiguration),
      coverArtworkSession: URLSession(configuration: artworkConfiguration)
    )
    let request = HTTPRequest(
      method: .get,
      url: try #require(URL(string: "https://books.example.test/api/items/item-1/cover")),
      headers: [:],
      body: nil,
      transportClass: .coverArtwork
    )

    do {
      _ = try await client.send(request)
      Issue.record("expected the URL loading system to report a timeout")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    } catch {
      Issue.record("expected raw URLError, received \(type(of: error))")
    }
  }

  @Test("URLSession failures remain raw URL errors for transport classifiers")
  func timeoutRemainsRawURLError() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TimeoutURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = URLSessionHTTPClient(session: session)
    let request = HTTPRequest(
      method: .get,
      url: try #require(URL(string: "https://books.example.test/status")),
      headers: [:],
      body: nil
    )

    do {
      _ = try await client.send(request)
      Issue.record("expected the URL loading system to report a timeout")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    } catch {
      Issue.record("expected raw URLError, received \(type(of: error))")
    }
  }

  @Test("progress-sync requests use the short-resource session")
  func progressSyncRequestRoutesToProgressSyncSession() async throws {
    let ordinaryConfiguration = URLSessionConfiguration.ephemeral
    ordinaryConfiguration.protocolClasses = [CannotConnectURLProtocol.self]
    let progressSyncConfiguration = URLSessionConfiguration.ephemeral
    progressSyncConfiguration.protocolClasses = [TimeoutURLProtocol.self]
    let ordinarySession = URLSession(configuration: ordinaryConfiguration)
    let progressSyncSession = URLSession(configuration: progressSyncConfiguration)
    let client = URLSessionHTTPClient(
      ordinarySession: ordinarySession,
      progressSyncSession: progressSyncSession,
      downloadSession: ordinarySession
    )
    let request = HTTPRequest(
      method: .post,
      url: try #require(URL(string: "https://books.example.test/api/session/id/sync")),
      headers: [:],
      body: Data(),
      transportClass: .progressSync
    )

    do {
      _ = try await client.send(request)
      Issue.record("expected the URL loading system to report a timeout")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    } catch {
      Issue.record("expected raw URLError, received \(type(of: error))")
    }
  }

  @Test("redirect policy permits only same-origin non-downgrading targets")
  func redirectPolicyMatrix() throws {
    let original = try #require(URL(string: "https://books.example.test:8443/api/items"))
    let cases: [(String, Bool)] = [
      ("https://books.example.test:8443/api/items/next", true),
      ("https://other.example.test:8443/api/items/next", false),
      ("https://books.example.test:9443/api/items/next", false),
      ("http://books.example.test:8443/api/items/next", false),
    ]

    for (targetString, allowed) in cases {
      let target = try #require(URL(string: targetString))
      #expect(
        ABSRedirectPolicy.evaluate(
          original: original, target: target, isAuthenticationRoute: false)
          == (allowed ? .allow : .reject))
    }

    let plainHTTP = try #require(URL(string: "http://books.example.test/api/items"))
    let plainHTTPTarget = try #require(URL(string: "http://books.example.test:80/api/items/next"))
    #expect(
      ABSRedirectPolicy.evaluate(
        original: plainHTTP, target: plainHTTPTarget, isAuthenticationRoute: false) == .allow)
    #expect(
      ABSRedirectPolicy.evaluate(
        original: original,
        target: original,
        isAuthenticationRoute: true) == .reject)
  }

  /// Embedded userinfo is a second set of credentials the app did not mint. Origin equality
  /// ignores it, so the policy has to refuse it explicitly on whichever URL carries it, for both
  /// same-origin and cross-origin targets.
  @Test("redirect policy refuses userinfo on either URL")
  func redirectPolicyRefusesUserinfo() throws {
    let original = try #require(URL(string: "https://books.example.test:8443/api/items"))
    let credentialOriginal = try #require(
      URL(string: "https://user:pass@books.example.test:8443/api/items"))
    let cases: [(name: String, original: URL, target: String)] = [
      (
        "same-origin target with userinfo", original,
        "https://user:pass@books.example.test:8443/api/items/next"
      ),
      (
        "cross-origin target with userinfo", original,
        "https://user:pass@other.example.test:8443/api/items/next"
      ),
      (
        "original with userinfo, same-origin target", credentialOriginal,
        "https://books.example.test:8443/api/items/next"
      ),
    ]

    for testCase in cases {
      let target = try #require(URL(string: testCase.target))
      #expect(
        ABSRedirectPolicy.evaluate(
          original: testCase.original, target: target, isAuthenticationRoute: false) == .reject,
        "\(testCase.name)")
    }

    let cleanTarget = try #require(
      URL(string: "https://books.example.test:8443/api/items/next"))
    #expect(
      ABSRedirectPolicy.evaluate(
        original: original, target: cleanTarget, isAuthenticationRoute: false) == .allow,
      "a clean same-origin redirect is still followed")
  }

  @Test("the URLSession redirect delegate applies the shared decision")
  func redirectDelegateUsesPolicy() throws {
    let original = try #require(URL(string: "https://books.example.test/api/items"))
    let target = try #require(URL(string: "https://other.example.test/api/items"))
    let response = try #require(
      HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
    let task = URLSession(configuration: .ephemeral).dataTask(with: original)
    var callbackRequest: URLRequest?
    let delegate = URLSessionRedirectDelegate(originalURL: original, isAuthenticationRoute: false)

    delegate.urlSession(
      URLSession(configuration: .ephemeral), task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: target), completionHandler: { callbackRequest = $0 })

    #expect(callbackRequest == nil)
  }

  @Test("the URLSession redirect delegate delegates refusal to a request handler")
  func redirectDelegateUsesRedirectHandlerToRefuse() throws {
    let original = try #require(URL(string: "https://books.example.test/api/items"))
    let target = try #require(URL(string: "https://other.example.test/api/items"))
    let response = try #require(
      HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
    let task = URLSession(configuration: .ephemeral).dataTask(with: original)
    let handler = RecordingRedirectHandler(result: nil)
    var callbackRequest: URLRequest?
    let delegate = URLSessionRedirectDelegate(originalURL: original, redirectHandler: handler)

    delegate.urlSession(
      URLSession(configuration: .ephemeral), task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: target), completionHandler: { callbackRequest = $0 })

    #expect(callbackRequest == nil)
  }

  @Test("the URLSession redirect delegate forwards a handler's modified request")
  func redirectDelegateUsesRedirectHandlerToModifyRequest() throws {
    let original = try #require(URL(string: "https://books.example.test/api/items"))
    let target = try #require(URL(string: "https://other.example.test/api/items"))
    let response = try #require(
      HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
    let task = URLSession(configuration: .ephemeral).dataTask(with: original)
    var modifiedRequest = URLRequest(url: target)
    modifiedRequest.setValue(nil, forHTTPHeaderField: "Authorization")
    let handler = RecordingRedirectHandler(result: modifiedRequest)
    var callbackRequest: URLRequest?
    let delegate = URLSessionRedirectDelegate(originalURL: original, redirectHandler: handler)
    var proposedRequest = URLRequest(url: target)
    proposedRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

    delegate.urlSession(
      URLSession(configuration: .ephemeral), task: task, willPerformHTTPRedirection: response,
      newRequest: proposedRequest, completionHandler: { callbackRequest = $0 })

    #expect(callbackRequest == modifiedRequest)
  }

  @Test("the URLSession redirect delegate numbers successive hops")
  func redirectDelegateNumbersSuccessiveHops() throws {
    let original = try #require(URL(string: "https://books.example.test/api/items"))
    let response = try #require(
      HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
    let task = URLSession(configuration: .ephemeral).dataTask(with: original)
    let handler = RecordingRedirectHandler(result: URLRequest(url: original))
    let delegate = URLSessionRedirectDelegate(originalURL: original, redirectHandler: handler)

    for _ in 1...3 {
      delegate.urlSession(
        URLSession(configuration: .ephemeral), task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: original), completionHandler: { _ in })
    }

    #expect(handler.hopNumbers == [1, 2, 3])
  }

  @Test("the ABS redirect delegate forwards same-origin requests unmodified")
  func absRedirectDelegateForwardsSameOriginRequest() throws {
    let original = try #require(URL(string: "https://books.example.test/api/items"))
    let target = try #require(URL(string: "https://books.example.test/api/items/next"))
    let response = try #require(
      HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
    let task = URLSession(configuration: .ephemeral).dataTask(with: original)
    var proposedRequest = URLRequest(url: target)
    proposedRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    var callbackRequest: URLRequest?
    let delegate = URLSessionRedirectDelegate(originalURL: original, isAuthenticationRoute: false)

    delegate.urlSession(
      URLSession(configuration: .ephemeral), task: task, willPerformHTTPRedirection: response,
      newRequest: proposedRequest, completionHandler: { callbackRequest = $0 })

    #expect(callbackRequest == proposedRequest)
  }

  @Test("the response accumulator stops at its cap")
  func responseAccumulatorEnforcesCap() throws {
    var accumulator = ResponseBodyAccumulator(maximumBytes: 2)
    try accumulator.append(1)
    try accumulator.append(2)
    #expect(accumulator.data == Data([1, 2]))
    #expect(throws: APIError.payloadTooLarge) {
      try accumulator.append(3)
    }
  }

  @Test("the accumulator assembles bodies larger than one staging block byte for byte")
  func responseAccumulatorAssemblesAcrossStagingBlocks() throws {
    let source = (0..<(200 * 1024)).map { UInt8($0 % 251) }
    var accumulator = ResponseBodyAccumulator(maximumBytes: source.count)
    for byte in source {
      try accumulator.append(byte)
    }
    accumulator.finish()

    #expect(accumulator.data == Data(source))
    #expect(throws: APIError.payloadTooLarge) {
      try accumulator.append(0)
    }
  }

  @Test("the accumulator reports staged bytes before it is finished")
  func responseAccumulatorReadsBeforeFinish() throws {
    var accumulator = ResponseBodyAccumulator(maximumBytes: nil)
    try accumulator.append(7)
    #expect(accumulator.data == Data([7]))
    accumulator.finish()
    #expect(accumulator.data == Data([7]))
  }

  @Test("a declared Content-Length over the cap is rejected before body iteration")
  func contentLengthAdmissionEnforcesCap() {
    #expect(throws: APIError.payloadTooLarge) {
      try ResponseBodyAdmission.validateContentLength("11", maximumBytes: 10)
    }
    #expect(throws: Never.self) {
      try ResponseBodyAdmission.validateContentLength("10", maximumBytes: 10)
    }
    #expect(throws: Never.self) {
      try ResponseBodyAdmission.validateContentLength("not-a-length", maximumBytes: 10)
    }
  }

  @Test("redirect-handler sends return a 304 response")
  func redirectHandlerReturnsNotModified() async throws {
    let client = URLSessionHTTPClient(session: URLSession(configuration: .sessionWith304))
    let request = try statusRequest()

    let response = try await client.send(request, redirectHandler: NoRedirectHandler())

    #expect(response.statusCode == 304)
    #expect(
      response.headers.first { $0.key.caseInsensitiveCompare("ETag") == .orderedSame }?.value
        == "\"stub\"")
    #expect(response.body.isEmpty)
  }

  @Test("plain sends still reject a 304 response")
  func plainSendRejectsNotModified() async throws {
    let client = URLSessionHTTPClient(session: URLSession(configuration: .sessionWith304))

    await #expect(throws: APIError.transport) { try await client.send(statusRequest()) }
  }

  @Test("redirect-handler sends still reject refused redirects")
  func redirectHandlerRejects302() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RedirectURLProtocol.self]
    let client = URLSessionHTTPClient(session: URLSession(configuration: configuration))

    await #expect(throws: APIError.transport) {
      try await client.send(statusRequest(), redirectHandler: NoRedirectHandler())
    }
  }

  /// The one transport exception. `allHeaderFields` joins several `Set-Cookie` fields with commas,
  /// and an `Expires` date contains commas too, so this is the parsing that matters.
  @Test("an opted-in request gets its redirect and the origin's cookies back")
  func optedInRequestSurfacesRedirectAndCookies() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CookieRedirectURLProtocol.self]
    let client = URLSessionHTTPClient(session: URLSession(configuration: configuration))

    let response = try await client.send(try statusRequest().surfacingRedirectAndCookies())

    #expect(response.statusCode == 302)
    #expect(
      response.headers.first { $0.key.caseInsensitiveCompare("Location") == .orderedSame }?.value
        == "https://idp.example.test/authorize")
    #expect(
      response.cookies == [
        HTTPResponseCookie(name: "connect.sid", value: "s%3Asession.sig"),
        HTTPResponseCookie(name: "auth_method", value: "openid-mobile"),
      ])
  }

  /// The redirect is still refused; only the error changes, so setup can name where the address
  /// points instead of calling it unreachable.
  @Test("an opted-in request reports a refused redirect and where it pointed")
  func optedInRequestReportsRefusedRedirect() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RedirectURLProtocol.self]
    let client = URLSessionHTTPClient(session: URLSession(configuration: configuration))
    let expected = RefusedRedirectError(target: URL(string: "https://other.example.test/status"))

    await #expect(throws: expected) {
      try await client.send(try statusRequest().reportingRefusedRedirect())
    }
  }

  @Test("a refused redirect's description never prints its target")
  func refusedRedirectDescriptionIsRedacted() throws {
    let error = RefusedRedirectError(target: URL(string: "https://secret.example.test/x?token=1"))

    #expect(String(describing: error).contains("secret.example.test") == false)
    #expect(String(reflecting: error).contains("secret.example.test") == false)
  }

  @Test("a plain request still refuses the same redirect and is never given cookies")
  func plainRequestStillRefusesTheRedirect() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CookieRedirectURLProtocol.self]
    let client = URLSessionHTTPClient(session: URLSession(configuration: configuration))

    await #expect(throws: APIError.transport) { try await client.send(statusRequest()) }
  }

  /// A hostile or broken server can omit `Content-Length` and stream far more than a caller asked
  /// for. The accumulator, not the header, is the real bound: it must reject the byte after the
  /// budget even when the body arrives in several chunks.
  @Test("a chunked body without Content-Length is stopped at the request's byte cap")
  func streamedBodyWithoutContentLengthEnforcesRequestCap() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkedBodyURLProtocol.self]
    let client = URLSessionHTTPClient(session: URLSession(configuration: configuration))
    let request = HTTPRequest(
      method: .get, url: try #require(URL(string: "https://books.example.test/status")),
      headers: [:], body: nil, maximumResponseBytes: 4)

    await #expect(throws: APIError.payloadTooLarge) { _ = try await client.send(request) }
  }

  /// The declared length is refused before a single body byte is consumed, so an over-cap header
  /// cannot make the transport buffer the whole response first.
  @Test("a declared Content-Length over the request's cap is rejected before the body")
  func declaredContentLengthOverRequestCapIsRejected() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeclaredLengthURLProtocol.self]
    let client = URLSessionHTTPClient(session: URLSession(configuration: configuration))
    let request = HTTPRequest(
      method: .get, url: try #require(URL(string: "https://books.example.test/status")),
      headers: [:], body: nil, maximumResponseBytes: 4)

    await #expect(throws: APIError.payloadTooLarge) { _ = try await client.send(request) }
  }

  private func statusRequest() throws -> HTTPRequest {
    HTTPRequest(
      method: .get, url: try #require(URL(string: "https://books.example.test/status")), headers: [:],
      body: nil)
  }
}

private final class RecordingRedirectHandler: HTTPRedirectHandling, @unchecked Sendable {
  private let result: URLRequest?
  private(set) var hopNumbers: [Int] = []

  init(result: URLRequest?) {
    self.result = result
  }

  func handleRedirect(original _: URL, proposed _: URLRequest, hopNumber: Int) -> URLRequest? {
    hopNumbers.append(hopNumber)
    return result
  }
}

private final class TimeoutURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
  }

  override func stopLoading() {}
}

private final class CannotConnectURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
  }

  override func stopLoading() {}
}

/// Deliberately omits `Content-Length` and delivers three times the test's four-byte budget in
/// separate chunks, so the transport cannot rely on the header to bound the response.
private final class ChunkedBodyURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in ["abcd", "efgh", "ijkl"] {
      client?.urlProtocol(self, didLoad: Data(chunk.utf8))
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class DeclaredLengthURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": "12"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

extension URLSessionConfiguration {
  fileprivate static var sessionWith304: URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NotModifiedURLProtocol.self]
    return configuration
  }
}

private struct NoRedirectHandler: HTTPRedirectHandling {
  func handleRedirect(original _: URL, proposed _: URLRequest, hopNumber _: Int) -> URLRequest? { nil }
}

private final class NotModifiedURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 304, httpVersion: nil, headerFields: ["ETag": "\"stub\""])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class RedirectURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 302, httpVersion: nil,
      headerFields: ["Location": "https://other.example.test/status"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class CookieRedirectURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
      headerFields: [
        "Location": "https://idp.example.test/authorize",
        "Set-Cookie":
          "connect.sid=s%3Asession.sig; Path=/; HttpOnly, "
          + "auth_method=openid-mobile; Max-Age=315360000; Path=/; Expires=Wed, 04 Nov 2036 11:00:00 GMT; HttpOnly, "
          + "tracker=x; Domain=elsewhere.example.test; Path=/",
      ])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
