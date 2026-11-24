import Foundation
import WatchPlayback
import WatchProtocol

/// What one Audiobookshelf download needs from the session, read once when the request starts.
@MainActor
struct WatchABSEnqueueContext {
  let service: ABSWatchLibraryService
  let account: WatchAccountRecord
  let store: WatchDownloadStore
  let manager: WatchDownloadManager
  /// The ceiling the Audiobookshelf and received-episode stores share; `nil` admits on the store's
  /// own quota alone.
  let budget: WatchStorageBudget?
}

/// One download to enqueue: the wrist's Download, or a phone request.
struct WatchABSEnqueueRequest {
  let selection: WatchSelection
  let title: String
  let origin: WatchABSOrigin
  /// The phone's revision for a phone request; `nil` for the wrist's own.
  let phoneRevision: UInt64?
}

/// The one path from a selection to enqueued files, for the wrist's Download and the phone's
/// requests alike: the item's detail, the selection's plan, whole-plan admission, then
/// one enqueue per file the store does not hold, each titled before its transfer starts.
///
/// Calls run one at a time. The phone's driver ignores the controller's `busy`, so without this a
/// wrist tap and a phone request for the same book could both read the store before either
/// enqueued, and the second would be refused as a duplicate.
@MainActor
final class WatchABSEnqueuer {
  private var tail: Task<Void, Never>?

  /// The IDs of the files this call enqueued; none when the store already held every file.
  /// `isCurrent` is the caller's session-epoch check, read after every suspension. `label` writes
  /// a file's title, or removes it when given `nil`.
  func enqueue(
    _ request: WatchABSEnqueueRequest, in context: WatchABSEnqueueContext,
    isCurrent: @escaping @MainActor () -> Bool, label: @escaping @MainActor (UUID, String?) -> Void
  ) async throws -> [UUID] {
    let previous = tail
    let task = Task { @MainActor in
      await previous?.value
      return try await Self.run(request, in: context, isCurrent: isCurrent, label: label)
    }
    tail = Task { _ = await task.result }
    return try await task.value
  }

  private static func run(
    _ request: WatchABSEnqueueRequest, in context: WatchABSEnqueueContext,
    isCurrent: @MainActor () -> Bool, label: @MainActor (UUID, String?) -> Void
  ) async throws -> [UUID] {
    guard case .audiobookshelf(let itemID, let episodeID) = request.selection else {
      throw WatchDownloadPlanningError.unsupportedMedia
    }
    guard isCurrent() else { throw WatchLibraryError.staleRequest }
    let detail = try await context.service.detail(account: context.account.tokenAccount(), itemID: itemID)
    guard isCurrent() else { throw WatchLibraryError.staleRequest }
    let plan = try WatchDownloadPlanner.plan(for: detail, episodeID: episodeID)
    let held = await context.store.manifests(for: request.selection)
    guard isCurrent() else { throw WatchLibraryError.staleRequest }
    // A book too big for the Watch is declined once, before its first file, rather than enqueued
    // in part and then refused file by file.
    if let budget = context.budget {
      let additional = WatchABSAdmission.additionalBytes(for: plan, held: held)
      guard WatchABSAdmission.admits(additionalBytes: additional, budget: budget) else {
        throw WatchABSAdmissionError.insufficientSpace
      }
    }
    var enqueued: [UUID] = []
    for track in plan where !holds(held, track) {
      guard isCurrent() else { throw WatchLibraryError.staleRequest }
      let id = UUID()
      // Titled before the manager starts the transfer, so no row is ever untitled.
      label(id, request.title)
      let result = await context.manager.enqueue(
        selection: track.selection, downloadGroupID: track.downloadGroupID,
        expectedTrackCount: track.expectedTrackCount, fileID: track.fileID, fileIndex: track.fileIndex,
        startOffset: track.startOffset, duration: track.duration, expectedBytes: track.expectedBytes,
        expectedMIMEType: track.expectedMIMEType, id: id, chapters: track.chapters,
        origin: request.origin, phoneRevision: request.phoneRevision)
      guard result == nil else {
        enqueued.append(id)
        continue
      }
      label(id, nil)
      // Held already is not a failure: the file is the one this request wanted.
      if holds(await context.store.manifests(for: request.selection), track) { continue }
      if context.manager.lastError == .store(.quotaExceeded) { throw WatchDownloadStoreError.quotaExceeded }
      throw WatchLibraryError.storageFailure
    }
    return enqueued
  }

  private static func holds(_ manifests: [WatchDownloadManifest], _ track: WatchDownloadDescriptor) -> Bool {
    manifests.contains { $0.fileID == track.fileID && $0.fileIndex == track.fileIndex }
  }
}
