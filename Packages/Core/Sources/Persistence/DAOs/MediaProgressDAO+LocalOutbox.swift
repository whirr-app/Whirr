import Foundation
import GRDB

extension MediaProgressDAO {
  /// Applies one explicitly-medium-tagged local position write. The write is
  /// `writeAsync`: readers and sync actors may call it from cooperative threads without entering
  /// GRDB's synchronous writer path.
  @discardableResult
  public func writeLocalAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    field: MediaProgressField,
    originKey: String,
    now: Date = Date()
  ) async throws -> MediaProgressRecord {
    try await database.writeAsync { db in
      var record =
        try Self.fetchProgress(db, accountId: accountId, identity: identity)
        ?? MediaProgressRecord(
          accountId: accountId,
          itemId: identity.itemId,
          podcastEpisodeId: identity.podcastEpisodeId,
          currentTime: 0,
          isFinished: false,
          localSequence: 0,
          origin: .local,
          originKey: originKey)

      switch field {
      case .audio(let currentTime, let isFinished):
        record.currentTime = currentTime
        record.isFinished = isFinished
        record.hideFromContinueListening = false
      case .ebook(let readingPositionJSON, let ebookProgress):
        try Self.validateEbookPositionJSON(readingPositionJSON)
        record.ebookProgress = try Self.validatedEbookProgress(ebookProgress)
        record.readingPositionJSON = readingPositionJSON
      // `ebookLocation` is server-pulled state. Local Locator JSON is not a CFI rewrite.
      }

      record.localSequence += 1
      record.lastActivityAt = now
      record.origin = .local
      record.originKey = originKey
      try record.save(db)
      return record
    }
  }

  /// Writes the local ebook position and enqueues its ebook-only PATCH in one transaction
  /// The local Locator JSON is retained only in `mediaProgress`; the outbox
  /// carries the fraction and optional server CFI. Ebook progress is item-scoped, so an episode
  /// identity is rejected rather than silently redirected to the show.
  @discardableResult
  public func writeEbookPositionAndEnqueueAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    entityKey: String,
    readingPositionJSON: String,
    ebookProgress: Double,
    ebookLocation: String?,
    originKey: String,
    now: Date = Date(),
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1
  ) async throws -> EbookProgressWriteResult {
    guard case .item = identity else {
      throw MediaProgressDAOError.ebookOperationRequiresItemIdentity
    }
    let newClientOperationId = clientOperationId()
    return try await database.writeAsync { db in
      try Self.validateEbookPositionJSON(readingPositionJSON)
      let validatedProgress = try Self.validatedEbookProgress(ebookProgress)
      if let ebookLocation {
        try Self.validateEbookLocation(ebookLocation)
      }
      let validatedLocation = Self.validatedEPUBCFI(ebookLocation)

      var record =
        try Self.fetchProgress(db, accountId: accountId, identity: identity)
        ?? MediaProgressRecord(
          accountId: accountId,
          itemId: identity.itemId,
          podcastEpisodeId: nil,
          currentTime: 0,
          isFinished: false,
          localSequence: 0,
          origin: .local,
          originKey: originKey)
      record.readingPositionJSON = readingPositionJSON
      record.ebookProgress = validatedProgress
      record.localSequence += 1
      record.lastActivityAt = now
      record.origin = .local
      record.originKey = originKey
      try record.save(db)

      let operation = try OutboxStore.enqueueEbookPosition(
        db,
        accountId: accountId,
        entityKey: entityKey,
        localSequence: record.localSequence,
        payload: OutboxEbookPositionPayload(
          ebookProgress: validatedProgress, ebookLocation: validatedLocation),
        clientOperationId: newClientOperationId,
        payloadVersion: payloadVersion)
      return EbookProgressWriteResult(progress: record, operation: operation)
    }
  }

  /// Ebook-only finish intent. It updates the shared item-wide flag and local ordering metadata,
  /// but never assigns `currentTime` (or any ebook position field).
  @discardableResult
  public func markEbookAsFinishedAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    originKey: String,
    now: Date = Date()
  ) async throws -> MediaProgressRecord {
    try await database.writeAsync { db in
      var record =
        try Self.fetchProgress(db, accountId: accountId, identity: identity)
        ?? MediaProgressRecord(
          accountId: accountId,
          itemId: identity.itemId,
          podcastEpisodeId: identity.podcastEpisodeId,
          currentTime: 0,
          isFinished: false,
          localSequence: 0,
          origin: .local,
          originKey: originKey)
      record.isFinished = true
      record.localSequence += 1
      record.lastActivityAt = now
      record.origin = .local
      record.originKey = originKey
      try record.save(db)
      return record
    }
  }

  /// Writes the ebook-safe item-wide finish and its dedicated outbox row in one transaction. It
  /// never assigns `currentTime`, ebook position, or an audio payload field. The server body is
  /// fixed by the operation kind and therefore can never send `{isFinished: false}`.
  @discardableResult
  public func markEbookAsFinishedAndEnqueueAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    entityKey: String,
    originKey: String,
    now: Date = Date(),
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1
  ) async throws -> EbookFinishWriteResult {
    guard case .item = identity else {
      throw MediaProgressDAOError.ebookOperationRequiresItemIdentity
    }
    let newClientOperationId = clientOperationId()
    return try await database.writeAsync { db in
      var record =
        try Self.fetchProgress(db, accountId: accountId, identity: identity)
        ?? MediaProgressRecord(
          accountId: accountId,
          itemId: identity.itemId,
          podcastEpisodeId: nil,
          currentTime: 0,
          isFinished: false,
          localSequence: 0,
          origin: .local,
          originKey: originKey)
      record.isFinished = true
      record.localSequence += 1
      record.lastActivityAt = now
      record.origin = .local
      record.originKey = originKey
      try record.save(db)

      let operation = try OutboxStore.enqueueSharedFinish(
        db,
        accountId: accountId,
        entityKey: entityKey,
        localSequence: record.localSequence,
        clientOperationId: newClientOperationId,
        payloadVersion: payloadVersion)
      return EbookFinishWriteResult(progress: record, operation: operation)
    }
  }

  /// Completes an acknowledged ebook operation in the same transaction as its outbox deletion.
  /// The local row already contains the local ebook value; acknowledgement stamps the server
  /// observation time and, when the wire body carried a CFI, mirrors that server field. The local
  /// Locator JSON is retained: it is app-owned state, not a server response.
  public func acknowledgeEbookOutboxOperationAsync(
    operationId: Int64,
    acknowledgedAt: Date
  ) async throws {
    try await database.writeAsync { db in
      guard let operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
        throw OutboxStoreError.operationNotFound(operationId)
      }
      guard
        operation.operationKind == OutboxOperationKind.ebookPosition.rawValue
          || operation.operationKind == OutboxOperationKind.ebookReset.rawValue
          || operation.operationKind == OutboxOperationKind.sharedFinish.rawValue
      else {
        throw MediaProgressDAOError.ebookOperationRequiresItemIdentity
      }

      if let item =
        try ItemRecord
        .filter(Column("accountId") == operation.accountId)
        .filter(Column("serverItemId") == operation.entityKey)
        .fetchOne(db),
        let itemID = item.id,
        var record = try Self.fetchProgress(
          db, accountId: operation.accountId, identity: .item(itemId: itemID))
      {
        // A local write may have landed while this operation was in flight. Its higher sequence
        // is authoritative for the row, so acknowledge/delete the older request without
        // rolling that newer local value back to the wire payload we just sent.
        guard record.localSequence <= operation.localSequence else {
          _ = try operation.delete(db)
          return
        }
        if operation.operationKind == OutboxOperationKind.ebookPosition.rawValue {
          if let ebookProgress = operation.payloadEbookProgress {
            record.ebookProgress = try Self.validatedEbookProgress(ebookProgress)
          }
          if let ebookLocation = Self.validatedEPUBCFI(operation.payloadEbookLocation) {
            record.ebookLocation = ebookLocation
          }
        } else if operation.operationKind == OutboxOperationKind.ebookReset.rawValue {
          record.ebookProgress = 0
          record.ebookLocation = nil
          record.readingPositionJSON = nil
          record.isFinished = false
        } else {
          // The dedicated finish kind has no payload flag to decode: its wire contract is always
          // exactly `{isFinished:true}`.
          record.isFinished = true
        }
        record.serverUpdatedAt = acknowledgedAt
        record.lastActivityAt = Self.laterActivity(record.lastActivityAt, acknowledgedAt)
        record.origin = .server
        record.originKey = ProgressOrigin.serverOriginKey
        try record.update(db)
      }

      _ = try operation.delete(db)
    }
  }
}
