import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

/// A cancelled operation shows no message; only a failure does.
@Suite struct WatchPlaybackFailureTests {
  @Test func everySupersededOperationIsACancellation() {
    let superseded: [any Error] = [
      CancellationError(), WatchPlaybackCoordinatorError.cancelled, APIError.cancelled,
      URLError(.cancelled), WatchLibraryError.staleRequest,
    ]
    for error in superseded {
      #expect(WatchPlaybackFailure(error) == .cancelled, "\(error)")
      #expect(!WatchPlaybackFailure(error).showsMessage)
    }
  }

  @Test func everythingElseIsAFailureWithAMessage() {
    struct Unknown: Error {}
    let failures: [any Error] = [
      WatchAudioEngineError.seekUnfinished, WatchAudioEngineError.noOutput, WatchAudioEngineError.unplayable,
      WatchPlaybackCoordinatorError.mismatchedSession, WatchLibraryError.notAuthenticated,
      WatchLibraryError.storageFailure, APIError.unauthorized, APIError.transport, APIError.decoding,
      URLError(.notConnectedToInternet), Unknown(),
    ]
    for error in failures {
      #expect(WatchPlaybackFailure(error) == .failed, "\(error)")
      #expect(WatchPlaybackFailure(error).showsMessage)
    }
  }
}
