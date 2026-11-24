import Foundation
import GRDB

extension NativeEpisodeServerSaveAttemptStore {
  // MARK: - Database implementation

  static func fetchAttempt(
    id: Int64,
    in db: Database
  ) throws -> NativeEpisodeServerSaveAttemptRecord? {
    guard let record = try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: id) else {
      return nil
    }
    try validateAccountFence(record, in: db)
    return record
  }

  static func fetchAttempts(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String?,
    in db: Database
  ) throws -> [NativeEpisodeServerSaveAttemptRecord] {
    var request =
      NativeEpisodeServerSaveAttemptRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("feedId") == feedId)
      .filter(Column("episodeId") == episodeId)
    if let episodeIdentityKey {
      request = request.filter(Column("episodeIdentityKey") == episodeIdentityKey)
    }
    let records = try request.order(Column("updatedAt").desc, Column("id").desc).fetchAll(db)
    let account = try accountRecord(accountId: accountId, in: db)
    for record in records {
      try validateAccountFence(record, account: account)
    }
    return records
  }

  static func create(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    preflightPresence: NativeEpisodeServerSavePreflightPresence?,
    now: Date,
    in db: Database
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try validateIdentity(feedId: feedId, episodeId: episodeId, episodeIdentityKey: episodeIdentityKey)
    let account = try accountRecord(accountId: accountId, in: db)
    try validateAccountFenceValues(account)

    var record = NativeEpisodeServerSaveAttemptRecord(
      accountId: accountId,
      accountClientUUID: account.clientUUID,
      accountServerIdentityFingerprint: account.serverIdentityFingerprint,
      feedId: feedId,
      episodeId: episodeId,
      episodeIdentityKey: episodeIdentityKey,
      preflightPresence: preflightPresence,
      createdAt: now)
    try record.insert(db)
    return record
  }

  static func begin(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    alternateEpisodeIdentityKeys: [String],
    preflightPresence: NativeEpisodeServerSavePreflightPresence?,
    now: Date,
    in db: Database
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    try validateIdentity(feedId: feedId, episodeId: episodeId, episodeIdentityKey: episodeIdentityKey)
    let identityKeys = try validatedEpisodeIdentityKeys(
      primary: episodeIdentityKey, alternates: alternateEpisodeIdentityKeys)
    let account = try accountRecord(accountId: accountId, in: db)
    try validateAccountFenceValues(account)

    let candidates = try NativeEpisodeServerSaveAttemptRecord.fetchAll(
      db,
      sql: """
        SELECT * FROM nativeEpisodeServerSaveAttempt
        WHERE accountId = ? AND feedId = ? AND episodeId = ?
          AND episodeIdentityKey IN (\(identityKeys.map { _ in "?" }.joined(separator: ", ")))
        ORDER BY updatedAt DESC, id DESC
        """,
      arguments: StatementArguments([accountId, feedId, episodeId] as [any DatabaseValueConvertible])
        + StatementArguments(identityKeys))
    if let existing = candidates.first(where: { Self.activeStates.contains($0.state) }) {
      try validateAccountFence(existing, account: account)
      return existing
    }
    return try create(
      accountId: accountId,
      feedId: feedId,
      episodeId: episodeId,
      episodeIdentityKey: episodeIdentityKey,
      preflightPresence: preflightPresence,
      now: now,
      in: db)
  }

  static func transition(
    attemptId: Int64,
    to newState: NativeEpisodeServerSaveAttemptState,
    serverItemId: String?,
    serverEpisodeId: String?,
    alternateEpisodeIdentityKeys: [String],
    preflightPresence: NativeEpisodeServerSavePreflightPresence?,
    errorCategory: NativeEpisodeServerSaveErrorCategory?,
    now: Date,
    updatingLocalState: @Sendable (Database) throws -> Void,
    in db: Database
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    guard var record = try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: attemptId) else {
      throw NativeEpisodeServerSaveAttemptStoreError.attemptNotFound(attemptId)
    }
    try validateAccountFence(record, in: db)
    guard Self.legalTransitions[record.state]?.contains(newState) == true else {
      throw NativeEpisodeServerSaveAttemptStoreError.illegalTransition(
        from: record.state, to: newState)
    }

    let identityKeys = try validatedEpisodeIdentityKeys(
      primary: record.episodeIdentityKey, alternates: alternateEpisodeIdentityKeys)
    if newState == .preparing {
      let stateList = Self.activeStates.map { "'\($0.rawValue)'" }.joined(separator: ", ")
      let hasNewerActiveAttempt =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM nativeEpisodeServerSaveAttempt
              WHERE accountId = ? AND feedId = ? AND episodeId = ? AND id <> ?
                AND episodeIdentityKey IN (\(identityKeys.map { _ in "?" }.joined(separator: ", ")))
                AND state IN (\(stateList))
            )
            """,
          arguments: StatementArguments(
            [record.accountId, record.feedId, record.episodeId, attemptId]
              as [any DatabaseValueConvertible]) + StatementArguments(identityKeys)) ?? false
      if hasNewerActiveAttempt {
        throw NativeEpisodeServerSaveAttemptStoreError.supersededByNewerAttempt
      }
    }

    if let serverItemId {
      try validateServerIdentity(serverItemId)
      if let existing = record.serverItemId, existing != serverItemId {
        throw NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
      }
      record.serverItemId = serverItemId
    }
    if let serverEpisodeId {
      try validateServerIdentity(serverEpisodeId)
      if let existing = record.serverEpisodeId, existing != serverEpisodeId {
        throw NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
      }
      record.serverEpisodeId = serverEpisodeId
    }
    if let preflightPresence {
      if let existing = record.preflightPresence, existing != preflightPresence {
        throw NativeEpisodeServerSaveAttemptStoreError.preflightAlreadyRecorded
      }
      if record.preflightPresence == nil, record.state != .preparing {
        throw NativeEpisodeServerSaveAttemptStoreError.preflightMustPrecedeRequest
      }
      record.preflightPresence = preflightPresence
    }

    switch newState {
    case .requestingDownload, .accepted:
      guard record.serverItemId != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
      }
      guard record.preflightPresence != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.preflightRequired
      }
    case .confirmed:
      guard record.serverItemId != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
      }
      guard record.serverEpisodeId != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverEpisodeIdentityRequired
      }
    case .deleting:
      guard record.serverItemId != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
      }
      guard record.serverEpisodeId != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverEpisodeIdentityRequired
      }
      guard record.preflightPresence != .preExisting else {
        throw NativeEpisodeServerSaveAttemptStoreError.preExistingEpisodeCannotBeRemoved
      }
      guard record.preflightPresence == .absentBeforeRequest else {
        throw NativeEpisodeServerSaveAttemptStoreError.preflightRequired
      }
    case .removed:
      guard record.serverItemId != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
      }
      guard record.serverEpisodeId != nil else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverEpisodeIdentityRequired
      }
    default:
      break
    }

    let isErrorState: Bool =
      switch newState {
      case .createUncertain, .uncertain, .failed, .deleteUncertain, .deleteFailed: true
      default: false
      }
    if isErrorState {
      // Every uncertain/failed row stays explainable after relaunch. Callers without a more
      // specific sanitised category get the closed `.unknown` value; categories are never
      // inferred from a raw network error in this layer.
      record.errorCategory = errorCategory ?? record.errorCategory ?? .unknown
    } else {
      record.errorCategory = nil
    }
    record.state = newState
    record.updatedAt = now
    try updatingLocalState(db)
    try record.update(db)
    return record
  }

  static func updateIdentity(
    attemptId: Int64,
    serverItemId: String?,
    serverEpisodeId: String?,
    now: Date,
    updatingLocalState: @Sendable (Database) throws -> Void,
    in db: Database
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    guard var record = try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: attemptId) else {
      throw NativeEpisodeServerSaveAttemptStoreError.attemptNotFound(attemptId)
    }
    try validateAccountFence(record, in: db)
    if let serverItemId {
      try validateServerIdentity(serverItemId)
      if let existing = record.serverItemId, existing != serverItemId {
        throw NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
      }
      record.serverItemId = serverItemId
    }
    if let serverEpisodeId {
      try validateServerIdentity(serverEpisodeId)
      if let existing = record.serverEpisodeId, existing != serverEpisodeId {
        throw NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded
      }
      record.serverEpisodeId = serverEpisodeId
    }
    guard record.state != .removed else {
      throw NativeEpisodeServerSaveAttemptStoreError.illegalTransition(
        from: record.state, to: record.state)
    }
    record.updatedAt = now
    try updatingLocalState(db)
    try record.update(db)
    return record
  }

  static func updatePreflight(
    attemptId: Int64,
    presence: NativeEpisodeServerSavePreflightPresence,
    now: Date,
    updatingLocalState: @Sendable (Database) throws -> Void,
    in db: Database
  ) throws -> NativeEpisodeServerSaveAttemptRecord {
    guard var record = try NativeEpisodeServerSaveAttemptRecord.fetchOne(db, key: attemptId) else {
      throw NativeEpisodeServerSaveAttemptStoreError.attemptNotFound(attemptId)
    }
    try validateAccountFence(record, in: db)
    guard record.state != .removed else {
      throw NativeEpisodeServerSaveAttemptStoreError.illegalTransition(
        from: record.state, to: record.state)
    }
    guard record.state == .preparing else {
      throw NativeEpisodeServerSaveAttemptStoreError.preflightMustPrecedeRequest
    }
    if let existing = record.preflightPresence, existing != presence {
      throw NativeEpisodeServerSaveAttemptStoreError.preflightAlreadyRecorded
    }
    record.preflightPresence = presence
    record.updatedAt = now
    try updatingLocalState(db)
    try record.update(db)
    return record
  }

  private static func validateIdentity(
    feedId: Int64, episodeId: Int64, episodeIdentityKey: String
  ) throws {
    guard feedId > 0, episodeId > 0 else {
      throw NativeEpisodeServerSaveAttemptStoreError.invalidIdentity
    }
    try validateEpisodeIdentityKey(episodeIdentityKey)
  }

  private static func validatedEpisodeIdentityKeys(
    primary: String,
    alternates: [String]
  ) throws -> [String] {
    guard alternates.count <= 8 else {
      throw NativeEpisodeServerSaveAttemptStoreError.invalidEpisodeIdentity
    }
    try validateEpisodeIdentityKey(primary)
    var keys = [primary]
    for alternate in alternates {
      try validateEpisodeIdentityKey(alternate)
      if keys.contains(alternate) == false {
        keys.append(alternate)
      }
    }
    return keys
  }

  private static func validateEpisodeIdentityKey(_ identity: String) throws {
    guard identity.isEmpty == false, identity.utf8.count <= 512,
      identity.utf8.allSatisfy({ $0 != 0 })
    else {
      throw NativeEpisodeServerSaveAttemptStoreError.invalidEpisodeIdentity
    }
  }

  static func validateServerIdentity(_ identity: String) throws {
    guard identity.isEmpty == false, identity.utf8.count <= 512,
      identity.utf8.allSatisfy({ $0 != 0 })
    else { throw NativeEpisodeServerSaveAttemptStoreError.invalidServerIdentity }
  }

  static func accountRecord(accountId: Int64, in db: Database) throws -> AccountRecord {
    guard let account = try AccountRecord.fetchOne(db, key: accountId) else {
      throw NativeEpisodeServerSaveAttemptStoreError.accountNotFound(accountId)
    }
    return account
  }

  private static func validateAccountFenceValues(_ account: AccountRecord) throws {
    guard account.clientUUID.isEmpty == false, account.clientUUID.utf8.count <= 512,
      account.serverBaseURL.isEmpty == false, account.serverBaseURL.utf8.count <= 16 * 1024,
      account.serverUserId.isEmpty == false, account.serverUserId.utf8.count <= 512,
      account.clientUUID.utf8.allSatisfy({ $0 != 0 }),
      account.serverBaseURL.utf8.allSatisfy({ $0 != 0 }),
      account.serverUserId.utf8.allSatisfy({ $0 != 0 })
    else { throw NativeEpisodeServerSaveAttemptStoreError.invalidAccountFence }
  }

  static func validateAccountFence(
    _ record: NativeEpisodeServerSaveAttemptRecord,
    in db: Database
  ) throws {
    let account = try accountRecord(accountId: record.accountId, in: db)
    try validateAccountFence(record, account: account)
  }

  static func validateAccountFence(
    _ record: NativeEpisodeServerSaveAttemptRecord,
    account: AccountRecord
  ) throws {
    guard record.accountClientUUID == account.clientUUID,
      record.accountServerIdentityFingerprint == account.serverIdentityFingerprint
    else { throw NativeEpisodeServerSaveAttemptStoreError.accountFenceMismatch }
  }
}
