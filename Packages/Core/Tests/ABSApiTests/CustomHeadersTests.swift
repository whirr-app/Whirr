import Testing

@testable import ABSApi

@Suite("Custom headers")
struct CustomHeadersTests {
  @Test("accepts RFC 7230 token names and visible ASCII values")
  func acceptsValidHeaders() throws {
    let headers = try CustomHeaders([
      "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz":
        " value\twith-visible-ASCII!"
    ])

    #expect(headers.headers.count == 1)
    #expect(headers.cookieHeaderIsPresent == false)
  }

  @Test("rejects empty, non-token, and non-ASCII names")
  func rejectsInvalidNames() {
    for name in ["", "X Header", "X:Header", "X\nHeader", "é"] {
      #expect(throws: CustomHeadersError.self) {
        try CustomHeaders([name: "value"])
      }
    }
  }

  @Test("rejects empty and unsafe values, including a header-injection attempt")
  func rejectsInvalidValues() {
    for value in ["", "value\r", "value\n", "value\0", "a\r\nX-Evil: 1", "café"] {
      #expect(throws: CustomHeadersError.self) {
        try CustomHeaders(["X-Proxy": value])
      }
    }
  }

  @Test("rejects duplicate names case-insensitively")
  func rejectsCaseInsensitiveDuplicates() {
    #expect(throws: CustomHeadersError.duplicateName) {
      try CustomHeaders(["X-Api-Key": "first", "x-api-key": "second"])
    }
  }

  @Test("keeps Authorization distinct from the other reserved names")
  func rejectsReservedNames() {
    #expect(throws: CustomHeadersError.authorizationNotAllowed) {
      try CustomHeaders(["authorization": "Bearer user-value"])
    }

    for name in [
      "Host", "Content-Length", "Connection", "Transfer-Encoding", "Proxy-Connection",
      "Upgrade", "Keep-Alive", "WWW-Authenticate", "x-return-tokens", "X-Return-Tokens",
      "x-refresh-token", "X-REFRESH-TOKEN",
    ] {
      #expect(throws: CustomHeadersError.reservedName) {
        try CustomHeaders([name: "value"])
      }
    }
  }

  @Test("fingerprints equal contents stably and change with any name or value change")
  func fingerprintsAreStableAndNonSecret() throws {
    let first = try CustomHeaders(["X-Second": "two", "X-First": "one"])
    let same = try CustomHeaders(["X-First": "one", "X-Second": "two"])
    let changedName = try CustomHeaders(["X-Changed": "two", "X-First": "one"])
    let changedValue = try CustomHeaders(["X-Second": "changed", "X-First": "one"])

    #expect(first == same)
    #expect(first.fingerprint == same.fingerprint)
    #expect(first.fingerprint.count == 64)
    #expect(first.fingerprint != changedName.fingerprint)
    #expect(first.fingerprint != changedValue.fingerprint)
    #expect(first.fingerprint.contains("one") == false)
    #expect(first.fingerprint.contains("two") == false)
  }

  @Test("detects Cookie case-insensitively and provides an empty singleton")
  func detectsCookieAndEmpty() throws {
    let withCookie = try CustomHeaders(["cOoKiE": "session=abc"])

    #expect(withCookie.cookieHeaderIsPresent)
    #expect(CustomHeaders.none == CustomHeaders.empty)
    #expect(CustomHeaders.none.headers.isEmpty)
    #expect(CustomHeaders().headers.isEmpty)
  }

  @Test("descriptions retain names but never values or fingerprints")
  func descriptionsRedactValues() throws {
    let headers = try CustomHeaders(["X-Secret": "header-secret", "Cookie": "session-secret"])

    for rendered in ["\(headers)", String(describing: headers), String(reflecting: headers)] {
      #expect(rendered.contains("X-Secret"))
      #expect(rendered.contains("Cookie"))
      #expect(rendered.contains("header-secret") == false)
      #expect(rendered.contains("session-secret") == false)
      #expect(rendered.contains(headers.fingerprint) == false)
    }
  }
}
