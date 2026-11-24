import Foundation
import Testing

@testable import ABSApi

/// Filter-string encoding: `<group>.<base64(raw UTF-8 value)>`. The raw value is Base64-encoded
/// with no URL-encode step first (verified against a live server).
///
/// Every expected string was computed with the `base64` shell command or Python's `base64` module,
/// not by running `LibraryItemFilter`, so the assertions pin the encoding independently.
@Suite("Filter string encoding")
struct FilterStringTests {
  @Test("encodes a raw value containing a space")
  func encodesValueWithSpace() {
    // printf '%s' "Sci Fi" | base64  ->  U2NpIEZp (matches the research brief's own example:
    // "E.g. filter=genres.U2NpIEZp").
    #expect(LibraryItemFilter(group: "genres", value: "Sci Fi").queryValue == "genres.U2NpIEZp")
  }

  @Test("encodes a raw value containing an ampersand")
  func encodesValueWithAmpersand() {
    // printf '%s' "Rock & Roll" | base64  ->  Um9jayAmIFJvbGw=
    #expect(LibraryItemFilter(group: "genres", value: "Rock & Roll").queryValue == "genres.Um9jayAmIFJvbGw=")
  }

  @Test("encodes a non-ASCII raw value")
  func encodesNonASCIIValue() {
    // printf '%s' "Sigur Rós" | base64  ->  U2lndXIgUsOzcw== (base64 of the raw UTF-8 bytes)
    #expect(LibraryItemFilter(group: "authors", value: "Sigur Rós").queryValue == "authors.U2lndXIgUsOzcw==")
  }

  @Test("does not match what a URL-encode-then-base64 implementation would have produced")
  func rejectsURLEncodeFirstImplementation() {
    // A URL-encode-first implementation would base64 the *percent-encoded* string
    // "Sci%20Fi" (space -> %20 before base64), not the raw bytes:
    // printf '%s' "Sci%20Fi" | base64  ->  U2NpJTIwRmk=
    // The correct, live-verified encoding must differ from this.
    let urlEncodeFirstResult = "genres.U2NpJTIwRmk="
    #expect(LibraryItemFilter(group: "genres", value: "Sci Fi").queryValue != urlEncodeFirstResult)
    #expect(LibraryItemFilter(group: "genres", value: "Sci Fi").queryValue == "genres.U2NpIEZp")
  }
}
