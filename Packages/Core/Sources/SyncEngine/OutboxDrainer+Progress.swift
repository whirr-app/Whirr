import ABSApi
import Foundation
import Persistence

extension OutboxDrainer {
  enum ProgressScopeResolution {
    case resolved(episodeServerID: String?, durationSeconds: Double?)
    case decodeAmbiguous
    case localReferenceGone
  }

  /// Resolves the item/episode scope shared by all progress PATCHes. An episode operation's
  /// `entityKey` is the show's server id, so the local episode row must be resolved at send time.
  /// Not `private`: `OutboxDrainer+ProgressReset.swift` shares this scoping rule for its own
  /// GET/DELETE/PATCH legs.
  func resolveProgressScope(
    _ operation: OutboxOperationRecord
  ) -> ProgressScopeResolution {
    if let episodeRowID = operation.podcastEpisodeId {
      let episode: PodcastEpisodeRecord?
      do {
        episode = try podcastEpisodes.fetchOne(id: episodeRowID)
      } catch {
        // The store could not answer (`SQLITE_BUSY`, a read error). That says nothing about
        // whether the episode exists, and a later attempt may answer. Decode/protocol ambiguity
        // retains the row and stops the drain: never a dead-letter, never a mis-scoped send.
        return .decodeAmbiguous
      }
      // Read succeeded and the episode row is gone. Every production route that removes one
      // cascades this operation away with it (`podcastEpisodeId ... ON DELETE CASCADE`), so the
      // store is already inconsistent. Unlike the read failure above, a later pass cannot change
      // this, and retaining would halt this show's queue on the row forever. A soft-deleted
      // episode is unaffected: `fetchOne(id:)` resolves it by primary key with no such filter.
      guard let episode else { return .localReferenceGone }
      return .resolved(
        episodeServerID: episode.serverEpisodeId, durationSeconds: episode.durationSeconds)
    }
    return .resolved(
      episodeServerID: nil,
      durationSeconds: try? items.fetchOne(
        accountId: accountId, serverItemId: operation.entityKey)?.durationSeconds)
  }

  /// API-CONVENTIONS rule 11: ebook position is a field-scoped PATCH. The no-CFI case produces
  /// only `ebookProgress`; a CFI crosses the boundary only after the same structural gate
  /// ReaderCore uses for an EPUB CFI. No `currentTime`, `id`, or shared finish flag can enter this
  /// body because the operation has its own payload columns.
  func sendEbookPosition(
    _ operation: OutboxOperationRecord
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    guard let ebookProgress = operation.payloadEbookProgress, ebookProgress.isFinite else {
      return .decodeAmbiguous
    }
    let update = ProgressUpdate(
      ebookProgress: ebookProgress,
      ebookLocation: Self.genuineEPUBCFI(operation.payloadEbookLocation))
    do {
      try await absClient.updateProgress(
        account: account,
        libraryItemID: operation.entityKey,
        episodeID: nil,
        update: update)
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch {
      return .apiFailure(.transport)
    }
  }

  /// API-CONVENTIONS rule 11: resetting an ebook clears its ebook fraction and shared finished
  /// flag without writing `currentTime`, which may belong to the audio side of a mixed-format book.
  func sendEbookReset(
    _ operation: OutboxOperationRecord
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    let update = ProgressUpdate(isFinished: false, ebookProgress: 0)
    do {
      try await absClient.updateProgress(
        account: account,
        libraryItemID: operation.entityKey,
        episodeID: nil,
        update: update)
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch {
      return .apiFailure(.transport)
    }
  }

  /// Shared finish is its own one-shot PATCH. The payload is fixed to `{isFinished:true}`, with no
  /// reset branch and no position/audio field to serialise by accident.
  func sendSharedFinish(
    _ operation: OutboxOperationRecord
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    let update = ProgressUpdate(isFinished: true)
    do {
      try await absClient.updateProgress(
        account: account,
        libraryItemID: operation.entityKey,
        episodeID: nil,
        update: update)
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch {
      return .apiFailure(.transport)
    }
  }

  /// Sends the visibility field alone. In particular, do not include `currentTime`: the server
  /// clears this flag when a progress position is included in the same PATCH.
  func sendContinueListeningVisibility(
    _ operation: OutboxOperationRecord
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    guard let hideFromContinueListening = operation.payloadHideFromContinueListening else {
      return .decodeAmbiguous
    }
    let episodeServerID: String?
    switch resolveProgressScope(operation) {
    case .resolved(let resolvedEpisodeServerID, _):
      episodeServerID = resolvedEpisodeServerID
    case .decodeAmbiguous:
      return .decodeAmbiguous
    case .localReferenceGone:
      return .localReferenceGone(reason: "episodeRowMissing")
    }

    do {
      try await absClient.updateProgress(
        account: account,
        libraryItemID: operation.entityKey,
        episodeID: episodeServerID,
        update: ProgressUpdate(hideFromContinueListening: hideFromContinueListening))
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch {
      return .apiFailure(.transport)
    }
  }

  private static func genuineEPUBCFI(_ value: String?) -> String? {
    guard let value,
      value.utf8.isEmpty == false,
      value.utf8.count <= 16 * 1024,
      value.hasPrefix("epubcfi("),
      value.hasSuffix(")")
    else { return nil }
    let bodyStart = value.index(value.startIndex, offsetBy: "epubcfi(".count)
    let bodyEnd = value.index(before: value.endIndex)
    let body = value[bodyStart..<bodyEnd]
    guard body.isEmpty == false,
      body.first == "/",
      body.unicodeScalars.contains(where: { (48...57).contains($0.value) }),
      body.unicodeScalars.allSatisfy({ $0.properties.isWhitespace == false && $0.value >= 0x20 })
    else { return nil }
    return value
  }

  /// An episode-scoped row must reach `/api/me/progress/{itemId}/{episodeId}`: `entityKey` is the
  /// show's server item id, so the item-level route would lose the episode's position and write a
  /// bogus show-level row the next `/api/me` pull would ingest.
  ///
  /// `podcastEpisodeId` is a local row id, resolved to the server id at send time, not enqueue: a
  /// queued row can outlive several library pulls.
  func sendProgress(_ operation: OutboxOperationRecord) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    let episodeServerID: String?
    let durationSeconds: Double?
    switch resolveProgressScope(operation) {
    case .resolved(let resolvedEpisodeServerID, let resolvedDurationSeconds):
      episodeServerID = resolvedEpisodeServerID
      durationSeconds = resolvedDurationSeconds
    case .decodeAmbiguous:
      return .decodeAmbiguous
    case .localReferenceGone:
      return .localReferenceGone(reason: "episodeRowMissing")
    }

    let update = ProgressUpdate(
      currentTime: operation.payloadCurrentTime,
      progress: Self.progressFraction(
        currentTime: operation.payloadCurrentTime, duration: durationSeconds),
      isFinished: operation.payloadIsFinished
    )
    do {
      try await absClient.updateProgress(
        account: account,
        libraryItemID: operation.entityKey,
        episodeID: episodeServerID,
        update: update
      )
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch {
      return .apiFailure(.transport)
    }
  }

  /// Audiobookshelf stores `currentTime` and `progress` independently. Its web UI reads the
  /// fraction for percentage/chapter projections, so both values must move together.
  private static func progressFraction(currentTime: Double?, duration: Double?) -> Double? {
    guard let currentTime, currentTime.isFinite, let duration, duration.isFinite, duration > 0 else {
      return nil
    }
    return min(max(currentTime / duration, 0), 1)
  }
}
