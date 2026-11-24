import Foundation
import TestSupport
import Testing

@testable import ABSApi

private struct OptionalValues: Decodable {
  @LossyOptional var count: Int?
  @LossyOptional var title: String?
}

private struct ListItem: Decodable, Equatable {
  let id: String?
  let title: String?
}

private struct BoundedStrings: Decodable {
  let truncated: String?
  let rejected: String?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    truncated = try container.decodeBoundedString(forKey: .truncated, policy: .truncate)
    rejected = try container.decodeBoundedString(forKey: .rejected, policy: .reject)
  }

  private enum CodingKeys: String, CodingKey {
    case truncated
    case rejected
  }
}

@Suite("Bounded and lossy decoding")
struct BoundedDecoderTests {
  @Test("rejects a body over 25 MiB before attempting JSON decoding")
  func rejectsOversizedBodyBeforeDecode() {
    struct Exploding: Decodable {
      init(from _: Decoder) throws {
        Issue.record("The decoder was invoked for an oversized body")
      }
    }

    let data = Data(repeating: 0x7B, count: 25 * 1024 * 1024 + 1)
    do {
      _ = try BoundedDecoder().decode(Exploding.self, from: data, endpoint: "/status")
      Issue.record("Expected oversized payload to fail")
    } catch let error as APIError {
      #expect(error == .payloadTooLarge)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("enforces an endpoint-specific body cap as defense in depth")
  func rejectsBodyOverEndpointSpecificCap() {
    let decoder = BoundedDecoder(limits: EndpointDecodeLimits(maximumBodyBytes: 2))

    #expect(throws: APIError.payloadTooLarge) {
      try decoder.decode([Int].self, from: Data("[1,2]".utf8), endpoint: "/items")
    }
  }

  @Test("treats null and wrong scalar types as absent through an explicit wrapper")
  func decodesOptionalScalarsLossily() throws {
    let data = Data(#"{"count":"wrong-type","title":null}"#.utf8)
    let values = try BoundedDecoder().decode(OptionalValues.self, from: data, endpoint: "/values")

    #expect(values.count == nil)
    #expect(values.title == nil)
  }

  @Test("truncates list strings at 16 KiB or rejects them by explicit field policy")
  func boundsListStrings() throws {
    let longValue = String(repeating: "a", count: 16 * 1024 + 12)
    let truncatedData = try JSONEncoder().encode(["truncated": longValue])
    let truncated = try BoundedDecoder().decode(
      BoundedStrings.self,
      from: truncatedData,
      endpoint: "/values"
    )
    #expect(truncated.truncated?.utf8.count == 16 * 1024)

    let rejectedData = try JSONEncoder().encode(["rejected": longValue])
    do {
      _ = try BoundedDecoder().decode(BoundedStrings.self, from: rejectedData, endpoint: "/values")
      Issue.record("Expected a rejected overlong string")
    } catch let error as APIError {
      #expect(error == .decoding)
    }
  }

  @Test("applies an endpoint-specific string limit")
  func appliesEndpointSpecificStringLimit() throws {
    let data = try JSONEncoder().encode(["truncated": "0123456789"])
    let decoder = BoundedDecoder(
      limits: EndpointDecodeLimits(maximumListStringBytes: 4)
    )
    let values = try decoder.decode(BoundedStrings.self, from: data, endpoint: "/values")

    #expect(values.truncated == "0123")
  }

  @Test("skips malformed elements and records only endpoint, index, and key path")
  func skipsMalformedArrayElements() throws {
    let data = try Fixtures.data(named: "malformed-library-items")
    let diagnostics = DecodeDiagnostics()
    let items = try BoundedDecoder().decodeLossyArray(
      ListItem.self,
      from: data,
      endpoint: "/api/libraries/library/items",
      diagnostics: diagnostics,
      validating: { $0.id != nil },
      requiredKey: "id"
    )

    #expect(items == [ListItem(id: "valid-id", title: "valid")])
    let entries = diagnostics.entries
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.endpoint == "/api/libraries/library/items" })
    #expect(entries.map(\.elementIndex) == [1, 2, 3])
    #expect(entries.map(\.codingPath) == [["id"], [], ["id"]])
    let formatted = entries.map(\.description).joined(separator: "\n")
    for secret in ["wrong-type", "not-an-object", "private-title"] {
      #expect(formatted.contains(secret) == false)
    }
  }

  @Test("rejects arrays over 20,000 elements")
  func capsArrayElements() throws {
    let data = Data(("[" + String(repeating: "0,", count: 20_000) + "0]").utf8)
    do {
      _ = try BoundedDecoder().decodeLossyArray(
        Int.self,
        from: data,
        endpoint: "/api/items"
      )
      Issue.record("Expected the array cap to fail")
    } catch let error as APIError {
      #expect(error == .decoding)
    }
  }

  @Test("maps top-level shape failures to decoding and safe diagnostics")
  func rejectsTopLevelShape() {
    let diagnostics = DecodeDiagnostics()
    do {
      _ = try BoundedDecoder().decodeLossyArray(
        ListItem.self,
        from: Data(#"{"items":[]}"#.utf8),
        endpoint: "/api/items",
        diagnostics: diagnostics
      )
      Issue.record("Expected a top-level shape failure")
    } catch let error as APIError {
      #expect(error == .decoding)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(diagnostics.entries.count == 1)
    #expect(diagnostics.entries[0].elementIndex == nil)
    #expect(diagnostics.entries[0].codingPath.isEmpty)
    #expect(diagnostics.entries[0].description == "endpoint=/api/items index=- path=$")
  }
}
