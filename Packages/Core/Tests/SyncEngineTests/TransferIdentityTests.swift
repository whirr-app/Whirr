import Foundation
import Testing

@testable import SyncEngine

@Suite("Transfer identity")
struct TransferIdentityTests {

  @Test("ABS and RSS identities with the same row id do not collide")
  func sourceQualifiedIdentityIsNoncolliding() {
    let abs = TransferIdentity.abs(rowID: 42)
    let rss = TransferIdentity.rss(rowID: 42)

    #expect(abs != rss)
    #expect(Set([abs, rss]).count == 2)
  }

  @Test("identity encoding is stable and round trips")
  func stableEncodingRoundTrips() throws {
    for identity in [TransferIdentity.abs(rowID: 42), .rss(rowID: 42)] {
      #expect(identity.encoded == (identity == .abs(rowID: 42) ? "abs:42" : "rss:42"))
      #expect(TransferIdentity(encoded: identity.encoded) == identity)

      let data = try JSONEncoder().encode(identity)
      #expect(String(data: data, encoding: .utf8) == "\"\(identity.encoded)\"")
      #expect(try JSONDecoder().decode(TransferIdentity.self, from: data) == identity)
    }
  }

  @Test("invalid, zero, negative, and noncanonical encodings are rejected")
  func invalidEncodingsAreRejected() {
    let invalid = [
      "", " ", "abs:0", "rss:0", "abs:-1", "rss:-1", "0", "-1", "+1", "01",
      " abs:1", "abs:1 ", "podcast:1", "abs:", "rss:", "abs:1:extra",
    ]
    for value in invalid {
      #expect(TransferIdentity(encoded: value) == nil, "unexpectedly accepted \(value)")
    }
  }

  @Test("legacy bare integer JSON decodes as an ABS identity")
  func legacyBareIntegerDecodesAsABS() throws {
    #expect(try JSONDecoder().decode(TransferIdentity.self, from: Data("42".utf8)) == .abs(rowID: 42))
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TransferIdentity.self, from: Data("0".utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TransferIdentity.self, from: Data("-1".utf8))
    }
  }
}
