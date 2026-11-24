import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite("Watch copy state")
struct WatchCopyStateTests {
  @Test func everyStoreStateKeepsItsFacts() {
    #expect(WatchCopyState(state: .wanted, removedBy: nil, declineReason: nil) == .wanted)
    #expect(WatchCopyState(state: .waitingForWatch, removedBy: nil, declineReason: nil) == .waitingForWatch)
    #expect(WatchCopyState(state: .sending, removedBy: nil, declineReason: nil) == .sending)
    #expect(WatchCopyState(state: .delivered, removedBy: nil, declineReason: nil) == .delivered)
    #expect(WatchCopyState(state: .removed, removedBy: .watch, declineReason: nil) == .removed(.watch))
    #expect(WatchCopyState(state: .removed, removedBy: .phone, declineReason: nil) == .removed(.phone))
    #expect(
      WatchCopyState(state: .declined, removedBy: nil, declineReason: .storageFull)
        == .declined(.storageFull))
    #expect(
      WatchCopyState(state: .declined, removedBy: nil, declineReason: .signedOut) == .declined(.signedOut))
    #expect(WatchCopyState(state: .failed, removedBy: nil, declineReason: nil) == .failed(nil))
  }

  /// The schema pairs the reason columns with their states; a row read without one still maps.
  @Test func aMissingReasonFallsBackToTheNeutralOne() {
    #expect(WatchCopyState(state: .removed, removedBy: nil, declineReason: nil) == .removed(.phone))
    #expect(WatchCopyState(state: .declined, removedBy: nil, declineReason: nil) == .declined(.invalid))
  }

  /// Three listener-facing reasons beside the ones RSS already words.
  @Test func audiobookshelfFailuresMapToTheirWording() {
    let expected: [(ABSWatchFailureReason, WatchCopyState.FailureReason)] = [
      (.httpStatus, .server),
      (.network, .network),
      (.tooLarge, .tooLarge),
      (.itemMissing, .notOnServer),
      (.noAudio, .noAudio),
      (.insecureRedirect, .couldNotDownload),
      (.invalidResponse, .couldNotDownload),
      (.planInvalid, .couldNotDownload),
    ]
    for (reason, mapped) in expected {
      #expect(
        WatchCopyState(state: .failed, removedBy: nil, declineReason: nil, failureReason: reason)
          == .failed(mapped))
    }
  }

  @Test func theMenuOffersRemoveOnlyForACopyOwedOrHeld() {
    for state: WatchCopyState in [.wanted, .waitingForWatch, .sending, .delivered] {
      #expect(state.menuCopy == .onWatch)
    }
    for state: WatchCopyState in [.removed(.watch), .declined(.storageFull), .failed(.noAudio)] {
      #expect(state.menuCopy == .notOnWatch)
    }
  }

  @Test func bothStoresRecordsMapAlike() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let abs = ABSWatchCopy(
      accountId: 1, key: ABSWatchCopyKey(itemId: "book", episodeId: nil), title: "Book",
      state: .failed, failureReason: .itemMissing, requestedAt: date, updatedAt: date)

    #expect(WatchCopyState(abs) == .failed(.notOnServer))
  }
}
