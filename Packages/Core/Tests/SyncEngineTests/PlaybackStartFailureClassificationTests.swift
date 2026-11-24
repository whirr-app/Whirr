import ABSApi
import Foundation
import Testing

@testable import SyncEngine

struct PlaybackStartFailureClassificationTests {
  @Test(
    "the transport failures a stopped server actually produces are read as unreachable",
    arguments: [
      URLError.Code.cannotConnectToHost,
      .cannotFindHost,
      .networkConnectionLost,
      .notConnectedToInternet,
      .timedOut,
      .dnsLookupFailed,
      .secureConnectionFailed,
    ])
  func transportFailuresAreUnreachable(code: URLError.Code) {
    #expect(PlaybackStartFailureClassification.isServerUnreachable(URLError(code)))
  }

  @Test("APIError's own transport case is read as unreachable")
  func apiTransportIsUnreachable() {
    #expect(PlaybackStartFailureClassification.isServerUnreachable(APIError.transport))
  }

  /// A server that answers, even with a failure, is reachable. The user gets that failure's own
  /// wording rather than being told to check a server that is running.
  @Test(
    "an answered request is never an outage, whatever it answered",
    arguments: [
      APIError.unauthorized,
      .forbidden,
      .notFound,
      .rateLimited,
      .serverFailure(statusCode: 500),
      .unexpectedStatus(statusCode: 418),
      .decoding,
    ])
  func answeredRequestsAreNotOutages(error: APIError) {
    #expect(PlaybackStartFailureClassification.isServerUnreachable(error) == false)
  }

  /// Cancellation is the app's own doing. Blaming the server would show an outage glyph and message
  /// to a user who simply left the screen.
  @Test("cancellation is not an outage")
  func cancellationIsNotAnOutage() {
    #expect(PlaybackStartFailureClassification.isServerUnreachable(URLError(.cancelled)) == false)
    #expect(PlaybackStartFailureClassification.isServerUnreachable(APIError.cancelled) == false)
  }

  @Test("an unrelated error keeps its own meaning")
  func unrelatedErrorsAreNotOutages() {
    struct Unrelated: Error {}
    #expect(PlaybackStartFailureClassification.isServerUnreachable(Unrelated()) == false)
  }
}
