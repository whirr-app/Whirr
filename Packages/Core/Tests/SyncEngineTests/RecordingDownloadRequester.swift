import Foundation

@testable import SyncEngine

/// Records every queue auto-download request the reconciler makes, and can fail them on demand so
/// a test can assert the reconciler's error path without a real requester.
actor RecordingDownloadRequester: QueueAutoDownloadRequesting {
  enum Request: Equatable, Sendable {
    case item(itemID: String)
    case episode(itemID: String, episodeID: String)
  }

  struct RequestFailure: Error {}

  private(set) var requests: [Request] = []
  private let shouldFail: Bool

  init(shouldFail: Bool = false) {
    self.shouldFail = shouldFail
  }

  func requestDownload(itemID: String) async throws {
    requests.append(.item(itemID: itemID))
    if shouldFail { throw RequestFailure() }
  }

  func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    requests.append(.episode(itemID: itemID, episodeID: episodeID))
    if shouldFail { throw RequestFailure() }
  }
}
