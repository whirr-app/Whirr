import Testing

@testable import ABSApi

@Suite("API errors")
struct APIErrorTests {
  @Test("classifies transport and HTTP failures without retaining a response body")
  func classifiesFailuresWithoutExposingBody() {
    let bodyCanary = "do-not-leak-this-response-body"

    #expect(APIError.transport.description.contains(bodyCanary) == false)
    #expect(APIError.cancelled.description.contains(bodyCanary) == false)
    #expect(APIError.decoding.description.contains(bodyCanary) == false)
    #expect(APIError.fromHTTPStatus(401).isUnauthorized)
    #expect(
      {
        if case .forbidden = APIError.fromHTTPStatus(403) { return true }
        return false
      }())
    #expect(
      {
        if case .notFound = APIError.fromHTTPStatus(404) { return true }
        return false
      }())
    #expect(
      {
        if case .payloadTooLarge = APIError.fromHTTPStatus(413) { return true }
        return false
      }())
    #expect(
      {
        if case .rateLimited = APIError.fromHTTPStatus(429) { return true }
        return false
      }())
    #expect(
      {
        if case .serverFailure(statusCode: 500) = APIError.fromHTTPStatus(500) { return true }
        return false
      }())
    #expect(
      {
        if case .serverFailure(statusCode: 503) = APIError.fromHTTPStatus(503) { return true }
        return false
      }())
    #expect(
      {
        if case .unexpectedStatus(statusCode: 418) = APIError.fromHTTPStatus(418) { return true }
        return false
      }())
  }

  @Test("oversized payloads use the same safe taxonomy")
  func classifiesOversizedPayloads() {
    let error = APIError.payloadTooLarge
    #expect(
      {
        if case .payloadTooLarge = error { return true }
        return false
      }())
    #expect(error.description.contains("oversized"))
  }
}
