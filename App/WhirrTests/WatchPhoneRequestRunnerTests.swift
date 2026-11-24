import Foundation
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch phone request envelopes")
struct WatchPhoneRequestRunnerTests {
  @Test("malformed, oversized and mismatched envelopes never enter the action")
  func rejectsBeforeAction() async throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    let other = try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server")
    let wrongAccount = try Self.request(other)
    for data in [
      Data(), Data(repeating: 0, count: WatchHandoffRequest.maxWireBytes + 1),
      try WatchWireCodec.encode(wrongAccount),
    ] {
      var called = false
      var rejected = false
      let reply = await WatchPhoneRequestRunner.run(
        WatchHandoffRequest.self, data: data, replyKey: WatchHandoffRequest.transportKey,
        currentStamp: { stamp }, requestStamp: { $0.accountStamp },
        rejection: { _, _ -> WatchHandoffReply? in
          rejected = true
          return nil
        },
        action: { _ in
          called = true
          return try WatchHandoffReply(handoffID: UUID(), status: .idle)
        })
      #expect(reply.isEmpty)
      #expect(rejected)
      #expect(!called)
    }
  }

  @Test("successful actions return a bounded typed reply under the endpoint key")
  func encodesReply() async throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    let request = try Self.request(stamp)
    let expected = WatchHandoffReply.idle(request)
    var received: WatchHandoffRequest?
    let reply = await WatchPhoneRequestRunner.run(
      WatchHandoffRequest.self, data: try WatchWireCodec.encode(request), replyKey: WatchHandoffRequest.transportKey,
      currentStamp: { stamp }, requestStamp: { $0.accountStamp },
      rejection: { _, _ -> WatchHandoffReply? in nil },
      action: { request in
        received = request
        return expected
      })
    #expect(received == request)
    #expect(reply.count == 1)
    let data = try #require(reply[WatchHandoffRequest.transportKey] as? Data)
    #expect(data.count <= WatchHandoffReply.maxWireBytes)
    #expect(try WatchWireCodec.decode(WatchHandoffReply.self, from: data) == expected)
  }

  @Test("action and encoding failures use the endpoint rejection builder")
  func rejectsActionAndEncodingFailures() async throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    let request = try Self.request(stamp)
    for failsAction in [true, false] {
      var failure: WatchPhoneRequestRunner.Failure?
      let reply = await WatchPhoneRequestRunner.run(
        WatchHandoffRequest.self, data: try WatchWireCodec.encode(request), replyKey: WatchHandoffRequest.transportKey,
        currentStamp: { stamp }, requestStamp: { $0.accountStamp },
        rejection: { _, reason -> OversizedReply? in
          failure = reason
          return nil
        },
        action: { _ in
          if failsAction { throw WatchProtocolCodingError.invalidValue }
          return OversizedReply(value: "exceeds the byte budget")
        })
      #expect(reply.isEmpty)
      if failsAction {
        if case .action? = failure {} else { Issue.record("Expected action rejection") }
      } else {
        if case .encode? = failure {} else { Issue.record("Expected encoding rejection") }
      }
    }
  }

  private static func request(_ stamp: WatchAccountStamp) throws -> WatchHandoffRequest {
    try WatchHandoffRequest(
      accountStamp: stamp, selection: nil, issuedAt: Date(timeIntervalSinceReferenceDate: 100))
  }
}

private nonisolated struct OversizedReply: WatchWireValue {
  nonisolated static let maxWireBytes = 1
  let value: String
  nonisolated func validate() {}
}
