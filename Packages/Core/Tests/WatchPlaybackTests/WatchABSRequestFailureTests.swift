import ABSApi
import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// What a failure before any file is enqueued records, and whether the plan's bytes fit the
/// Watch's shared budget before the first track is enqueued.
@Suite("Watch ABS request failure")
struct WatchABSRequestFailureTests {
  @Test func serverAndPlanningErrorsMapToTheAgreedReasons() {
    let cases: [(any Error, WatchABSRequestOutcome)] = [
      (APIError.notFound, .failed(.itemMissing)),
      (WatchDownloadPlanningError.episodeNotFound, .failed(.itemMissing)),
      (APIError.unauthorized, .failed(.httpStatus)),
      (APIError.forbidden, .failed(.httpStatus)),
      (WatchLibraryError.notAuthenticated, .failed(.httpStatus)),
      (APIError.transport, .failed(.network)),
      (URLError(.notConnectedToInternet), .failed(.network)),
      (APIError.serverFailure(statusCode: 503), .failed(.invalidResponse)),
      (APIError.decoding, .failed(.invalidResponse)),
      (WatchDownloadPlanningError.noAudioFiles, .failed(.noAudio)),
      (WatchDownloadPlanningError.unsupportedMedia, .failed(.noAudio)),
      (WatchDownloadPlanningError.missingSize, .failed(.planInvalid)),
      (WatchDownloadPlanningError.duplicateFileIndex, .failed(.planInvalid)),
      (WatchDownloadStoreError.quotaExceeded, .declined(.storageFull)),
      (WatchABSAdmissionError.insufficientSpace, .declined(.storageFull)),
      (WatchDownloadStoreError.storageFailure, .failed(.planInvalid)),
    ]
    for (error, expected) in cases {
      #expect(WatchABSRequestOutcome(error) == expected, "\(error)")
    }
  }

  /// A cancelled or superseded request is not a failure to remember: the next reconcile retries it.
  @Test func cancellationRecordsNothing() {
    let cancellations: [any Error] = [
      CancellationError(), APIError.cancelled, URLError(.cancelled), WatchLibraryError.staleRequest,
    ]
    for error in cancellations { #expect(WatchABSRequestOutcome(error) == nil, "\(error)") }
  }

  @Test func onlyANetworkFailureWaitsForTheNetwork() {
    #expect(WatchABSRequestOutcome.failed(.network).retriesWhenTheNetworkReturns)
    #expect(!WatchABSRequestOutcome.failed(.itemMissing).retriesWhenTheNetworkReturns)
    #expect(!WatchABSRequestOutcome.declined(.storageFull).retriesWhenTheNetworkReturns)
  }

  // MARK: Admission

  @Test func aWholePlanIsAdmittedOnlyWhenItFitsTheSharedBudget() throws {
    let budget = WatchStorageBudget(totalBytes: 1_000)
    budget.record(300, for: .receivedEpisodes)
    budget.record(200, for: .audiobookshelf)
    #expect(WatchABSAdmission.admits(additionalBytes: 500, budget: budget))
    #expect(!WatchABSAdmission.admits(additionalBytes: 501, budget: budget))
    // Admission only checks; the store claims each file as it enqueues it.
    #expect(budget.usedBytes == 500)
  }

  @Test func filesTheStoreAlreadyHoldsCostNothing() throws {
    let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    let plan = [descriptor(selection, index: 1, bytes: 400), descriptor(selection, index: 2, bytes: 600)]
    let held = [try manifest(selection, index: 1, bytes: 400)]
    #expect(WatchABSAdmission.additionalBytes(for: plan, held: held) == 600)
    #expect(WatchABSAdmission.additionalBytes(for: plan, held: []) == 1_000)
  }

  // MARK: Fixtures

  private func descriptor(_ selection: WatchSelection, index: Int, bytes: Int64) -> WatchDownloadDescriptor {
    WatchDownloadDescriptor(
      id: "book:\(index)", selection: selection, title: "Book", downloadGroupID: "book", expectedTrackCount: 2,
      fileID: "file-\(index)", fileIndex: index, startOffset: 0, duration: 60, expectedBytes: bytes,
      expectedMIMEType: "audio/mpeg")
  }

  private func manifest(_ selection: WatchSelection, index: Int, bytes: Int64) throws -> WatchDownloadManifest {
    let date = Date(timeIntervalSinceReferenceDate: 0)
    return WatchDownloadManifest(
      id: UUID(), accountStamp: try accountStamp(account: "a", server: "s"), selection: selection,
      downloadGroupID: "book", expectedTrackCount: 2, fileID: "file-\(index)", fileIndex: index, startOffset: 0,
      duration: 60, expectedBytes: bytes, expectedMIMEType: "audio/mpeg", destinationRelativePath: "f.mp3",
      createdAt: date, updatedAt: date)
  }
}
