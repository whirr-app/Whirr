import ABSApi
import Foundation
import Persistence

/// The bookmark drain legs. `entityKey` is the server item id and `payloadBookmarkTime` the exact
/// double the server matches on.
///
/// A rename's or delete's 404 is mapped to success here, not in `OutboxAcknowledgementPolicy`:
/// the bookmark is already gone, and a dead letter would ask the listener about a bookmark another
/// device deleted. The next complete pull removes the local row. A create's 404 means the item is
/// gone and takes the policy's dead-letter path, so the bookmark is not dropped without a trace.
extension OutboxDrainer {
  func sendAudioBookmark(
    _ operation: OutboxOperationRecord
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    guard let time = operation.payloadBookmarkTime else {
      return .localReferenceGone(reason: "bookmarkPayloadMissing")
    }
    do {
      switch OutboxOperationKind(rawValue: operation.operationKind) {
      case .bookmarkCreate:
        guard let title = operation.payloadBookmarkTitle else {
          return .localReferenceGone(reason: "bookmarkPayloadMissing")
        }
        try await absClient.createAudioBookmark(
          account: account, libraryItemID: operation.entityKey, time: time, title: title)
      case .bookmarkRename:
        guard let title = operation.payloadBookmarkTitle else {
          return .localReferenceGone(reason: "bookmarkPayloadMissing")
        }
        _ = try await absClient.renameAudioBookmark(
          account: account, libraryItemID: operation.entityKey, time: time, title: title)
      case .bookmarkDelete:
        _ = try await absClient.deleteAudioBookmark(
          account: account, libraryItemID: operation.entityKey, time: time)
      default:
        return .localReferenceGone(reason: "bookmarkPayloadMissing")
      }
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch is RequestBuilderError {
      // The stored item id or time cannot form a request. Resending cannot fix that, and leaving
      // the row queued would block the item's progress behind it.
      return .apiFailure(.badRequest)
    } catch {
      return .apiFailure(.transport)
    }
  }
}
