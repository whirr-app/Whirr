import ABSApi
import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

@Suite struct WatchLibraryLoadFailureTests {
  @Test(arguments: [
    APIError.unauthorized as any Error,
    APIError.forbidden,
    WatchLibraryError.notAuthenticated,
    WatchLibraryError.accountMismatch,
    TokenStoreError.malformedStoredTokens,
  ])
  func rejectedSignInAsksForReconnection(_ error: any Error) {
    #expect(WatchLibraryLoadFailure(error) == .signInRejected)
  }

  @Test(arguments: [APIError.transport as any Error, URLError(.notConnectedToInternet), URLError(.timedOut)])
  func unreachableServerIsReportedAsSuch(_ error: any Error) {
    #expect(WatchLibraryLoadFailure(error) == .serverUnreachable)
  }

  @Test func cancellationIsNotAFailure() {
    #expect(WatchLibraryLoadFailure(APIError.cancelled) == nil)
    #expect(WatchLibraryLoadFailure(CancellationError()) == nil)
    #expect(WatchLibraryLoadFailure(WatchLibraryError.staleRequest) == nil)
    #expect(WatchLibraryLoadFailure(URLError(.cancelled)) == nil)
  }

  @Test(arguments: [
    APIError.serverFailure(statusCode: 502) as any Error,
    APIError.decoding,
    WatchLibraryError.storageFailure,
  ])
  func otherFailuresAreGeneric(_ error: any Error) {
    #expect(WatchLibraryLoadFailure(error) == .unavailable)
  }

  @Test func everyFailureExplainsWhatToDo() {
    for failure in [WatchLibraryLoadFailure.signInRejected, .serverUnreachable, .unavailable, .noAudiobookLibrary] {
      #expect(!failure.message.isEmpty)
    }
    #expect(WatchLibraryLoadFailure.signInRejected.message.contains("Disconnect"))
  }

  @Test func failuresMapToWhatTheyProveAboutTheLink() {
    #expect(WatchLibraryLoadFailure.signInRejected.linkHealth == .signInRejected)
    #expect(WatchLibraryLoadFailure.serverUnreachable.linkHealth == .serverUnreachable)
    // The library request succeeded; the server simply has nothing for the Audiobooks tab.
    #expect(WatchLibraryLoadFailure.noAudiobookLibrary.linkHealth == .healthy)
    // A server error or undecodable reply says nothing about the sign-in or the network.
    #expect(WatchLibraryLoadFailure.unavailable.linkHealth == nil)
  }
}
