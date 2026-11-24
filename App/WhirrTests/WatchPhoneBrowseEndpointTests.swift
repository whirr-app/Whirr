import Foundation
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch phone browse endpoint", .serialized)
struct WatchPhoneBrowseEndpointTests {
  private let account = try! WatchAccountStamp(
    accountIdentityHash: "account", serverIdentityHash: "server")

  @Test func malformedBytesReceiveEmptyReply() async throws {
    try await expectEmptyReply(data: Data([0xFF]), currentStamp: account)
  }

  @Test func differentAccountReceivesEmptyReply() async throws {
    let other = try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server")
    try await expectEmptyReply(data: requestBytes(), currentStamp: other)
  }

  @Test func missingAccountReceivesEmptyReply() async throws {
    try await expectEmptyReply(data: requestBytes(), currentStamp: nil)
  }

  @Test func unavailableEndpointReceivesEmptyReply() async throws {
    try await expectEmptyReply(data: requestBytes(), currentStamp: account, isAvailable: false)
  }

  @Test func loadErrorRoundTripsUnchanged() async throws {
    let request = try WatchBrowseRequest(accountStamp: account, scope: .shows, pageSize: 10)
    let error = try WatchBrowseError(
      code: .retryable, message: "Try again shortly", retryable: true, retryAfterSeconds: 12)
    let expected = try WatchBrowseReply(request: request, status: .retryableError, error: error)
    try await expectRoundTrip(request: request, expected: expected)
  }

  @Test func loadedPageRoundTripsUnchanged() async throws {
    let request = try WatchBrowseRequest(accountStamp: account, scope: .shows, pageSize: 10)
    let page = try WatchBrowsePage(
      page: 0, pageSize: 10, rows: [], nextPage: nil, isComplete: true, generation: 7)
    let expected = try WatchBrowseReply(request: request, status: .accepted, page: page)
    try await expectRoundTrip(request: request, expected: expected)
  }

  private func requestBytes() throws -> Data {
    try WatchWireCodec.encode(WatchBrowseRequest(accountStamp: account, scope: .shows, pageSize: 10))
  }

  private func expectEmptyReply(
    data: Data, currentStamp: WatchAccountStamp?, isAvailable: Bool = true
  ) async throws {
    var loadCalls = 0
    let endpoint = WatchPhoneBrowseEndpoint(
      currentStamp: { currentStamp }, isAvailable: { isAvailable },
      load: { request in
        loadCalls += 1
        let page = try! WatchBrowsePage(
          page: 0, pageSize: 10, rows: [], nextPage: nil, isComplete: true, generation: 1)
        return try! WatchBrowseReply(request: request, status: .accepted, page: page)
      })
    var reply: [String: Any]?
    await endpoint.receive(data) { reply = $0 }
    let received = try #require(reply)
    #expect(received.isEmpty)
    #expect(loadCalls == 0)
  }

  private func expectRoundTrip(request: WatchBrowseRequest, expected: WatchBrowseReply) async throws {
    var loadedRequests: [WatchBrowseRequest] = []
    let endpoint = WatchPhoneBrowseEndpoint(
      currentStamp: { account }, isAvailable: { true },
      load: { request in
        loadedRequests.append(request)
        return expected
      })
    var reply: [String: Any]?
    await endpoint.receive(try WatchWireCodec.encode(request)) { reply = $0 }
    let received = try #require(reply)
    #expect(Set(received.keys) == Set([WatchTransportKey.browseReply]))
    let data = try #require(received[WatchTransportKey.browseReply] as? Data)
    let decoded = try WatchWireCodec.decode(WatchBrowseReply.self, from: data)
    #expect(decoded == expected)
    #expect(loadedRequests == [request])
  }
}
