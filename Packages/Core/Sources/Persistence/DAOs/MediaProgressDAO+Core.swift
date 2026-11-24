import Foundation
import GRDB

extension MediaProgressDAO {
  public func fetchCurrent(
    accountId: Int64, identity: MediaProgressIdentity
  ) throws -> MediaProgressRecord? {
    try database.read { db in
      try Self.fetchProgress(db, accountId: accountId, identity: identity)
    }
  }

  public func fetchCurrentAsync(
    accountId: Int64, identity: MediaProgressIdentity
  ) async throws -> MediaProgressRecord? {
    try await database.readAsync { db in
      try Self.fetchProgress(db, accountId: accountId, identity: identity)
    }
  }

  /// Resolves an item's local row and its current item-scoped progress from one database
  /// snapshot. The item lookup mirrors `ItemDAO.fetchOne(accountId:serverItemId:)`:
  /// soft-deleted item rows remain eligible for reader restore.
  public func fetchCurrentForServerItemAsync(
    accountId: Int64, serverItemId: String
  ) async throws -> MediaProgressRecord? {
    try await database.readAsync { db in
      guard
        let item =
          try ItemRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("serverItemId") == serverItemId)
          .fetchOne(db),
        let itemId = item.id
      else {
        return nil
      }

      return try Self.fetchProgress(
        db, accountId: accountId, identity: .item(itemId: itemId))
    }
  }

  /// True while an outbox operation for this item is unacknowledged: an unacknowledged local write
  /// outranks any pull until the server has seen it. `deadLetter` is terminal, not in flight, so
  /// it is excluded.
  ///
  /// `progress`-kind rows carry the real server item id as `entityKey` (`OutboxDrainer` sends it
  /// as the wire `libraryItemID`, API-CONVENTIONS rule 11; `PlaybackSessionStore.markSessionGone`'s
  /// preserved-position row too), so this resolves `itemId`'s own `serverItemId` before matching.
  public func hasUnacknowledgedLocalOperation(
    accountId: Int64,
    identity: MediaProgressIdentity,
    field: MediaProgressPendingField = .audioPosition
  ) throws -> Bool {
    try database.read { db in
      try Self.hasUnacknowledgedLocalOperation(
        db, accountId: accountId, identity: identity, field: field)
    }
  }

  public func hasUnacknowledgedLocalOperationAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    field: MediaProgressPendingField = .audioPosition
  ) async throws -> Bool {
    try await database.readAsync { db in
      try Self.hasUnacknowledgedLocalOperation(
        db, accountId: accountId, identity: identity, field: field)
    }
  }

  static func applyServerCompositeResolution(
    _ db: Database,
    accountId: Int64,
    identity: MediaProgressIdentity,
    currentTime: Double?,
    isFinished: Bool,
    ebookProgress: Double?,
    ebookLocation: String?,
    hideFromContinueListening: Bool,
    serverUpdatedAt: Date?,
    serverProgressId: ServerProgressIdUpdate = .unchanged,
    resolution: MediaProgressCompositeResolution
  ) throws -> MediaProgressRecord {
    let appliesAudio = resolution.audioPosition == .applyServer && currentTime != nil
    let appliesEbook = resolution.ebookPosition == .applyServer
    let appliesFinish = resolution.sharedFinish == .applyServer
    let appliesVisibility = resolution.continueListeningVisibility == .applyServer
    let appliesAnyField = appliesAudio || appliesEbook || appliesFinish || appliesVisibility

    if appliesEbook, let ebookLocation {
      try Self.validateEbookLocation(ebookLocation)
    }

    var record =
      try Self.fetchProgress(db, accountId: accountId, identity: identity)
      ?? MediaProgressRecord(
        accountId: accountId,
        itemId: identity.itemId,
        podcastEpisodeId: identity.podcastEpisodeId,
        currentTime: currentTime ?? 0,
        isFinished: appliesFinish ? isFinished : false,
        hideFromContinueListening: appliesVisibility ? hideFromContinueListening : false,
        serverUpdatedAt: appliesAnyField ? serverUpdatedAt : nil,
        localSequence: 0,
        origin: .server,
        originKey: ProgressOrigin.serverOriginKey
      )

    if appliesAudio, let currentTime {
      record.currentTime = currentTime
    }
    if appliesEbook {
      if let ebookProgress {
        record.ebookProgress = try Self.validatedEbookProgress(ebookProgress)
      } else {
        record.ebookProgress = nil
      }
      record.ebookLocation = ebookLocation
      // The server supplies a fraction and an optional CFI, never our local Locator envelope.
      record.readingPositionJSON = nil
    }
    if appliesFinish {
      record.isFinished = isFinished
    }
    if appliesVisibility {
      record.hideFromContinueListening = hideFromContinueListening
    }

    if appliesAnyField {
      record.serverUpdatedAt = serverUpdatedAt
      record.lastActivityAt = Self.laterActivity(record.lastActivityAt, serverUpdatedAt)
      record.origin = .server
      record.originKey = ProgressOrigin.serverOriginKey
    }
    if case .observed(let id, let updatedAt) = serverProgressId {
      record.serverProgressId = id
      record.serverProgressUpdatedAt = id == nil ? nil : updatedAt
    }
    try record.save(db)

    // An open conflict describes a server state this pull has just superseded. Visibility alone
    // is not enough: it applies on nearly every pull, including one that still conflicts.
    if appliesAudio || appliesEbook || appliesFinish {
      try Self.deleteConflict(db, accountId: accountId, identity: identity)
    }
    return record
  }

  static func deleteConflict(
    _ db: Database, accountId: Int64, identity: MediaProgressIdentity
  ) throws {
    _ =
      try ProgressConflictRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == identity.itemId)
      .filter(Column("podcastEpisodeId") == identity.podcastEpisodeId)
      .deleteAll(db)
  }

  /// Recency is display state, and a server observation can legitimately carry a timestamp older
  /// than this device's last tick (another device's stale row, a clock skew). Keeping the later of
  /// the two stops an ordinary pull from pushing the item the reader is playing down the carousel.
  static func laterActivity(_ current: Date?, _ incoming: Date?) -> Date? {
    switch (current, incoming) {
    case (let current?, let incoming?): return max(current, incoming)
    case (let current?, nil): return current
    case (nil, let incoming?): return incoming
    case (nil, nil): return nil
    }
  }

  @discardableResult
  static func upsertServerProgress(
    _ db: Database,
    accountId: Int64,
    identity: MediaProgressIdentity,
    currentTime: Double,
    isFinished: Bool,
    serverUpdatedAt: Date?
  ) throws -> MediaProgressRecord {
    var record =
      try Self.fetchProgress(db, accountId: accountId, identity: identity)
      ?? MediaProgressRecord(
        accountId: accountId,
        itemId: identity.itemId,
        podcastEpisodeId: identity.podcastEpisodeId,
        currentTime: currentTime,
        isFinished: isFinished,
        serverUpdatedAt: serverUpdatedAt,
        localSequence: 0,
        origin: .server,
        originKey: ProgressOrigin.serverOriginKey
      )
    record.currentTime = currentTime
    record.isFinished = isFinished
    // Visibility is absent here: it is a separately-decided field
    // (`applyServerVisibility`), because letting it ride on the position decision applies the
    // server's stale value whenever a local hide is still queued.
    record.serverUpdatedAt = serverUpdatedAt
    record.lastActivityAt = Self.laterActivity(record.lastActivityAt, serverUpdatedAt)
    record.origin = .server
    record.originKey = ProgressOrigin.serverOriginKey
    try record.save(db)
    return record
  }

  /// Applies only the server's Continue Listening visibility value. Keeping this separate from
  /// the position upsert lets a podcast pull win on visibility even when its audio position loses.
  static func applyServerVisibility(
    _ db: Database,
    accountId: Int64,
    identity: MediaProgressIdentity,
    hideFromContinueListening: Bool
  ) throws {
    var record =
      try Self.fetchProgress(db, accountId: accountId, identity: identity)
      ?? MediaProgressRecord(
        accountId: accountId,
        itemId: identity.itemId,
        podcastEpisodeId: identity.podcastEpisodeId,
        currentTime: 0,
        isFinished: false,
        localSequence: 0,
        origin: .server,
        originKey: ProgressOrigin.serverOriginKey)
    record.hideFromContinueListening = hideFromContinueListening
    try record.save(db)
  }

  @discardableResult
  static func upsertConflict(
    _ db: Database,
    accountId: Int64,
    identity: MediaProgressIdentity,
    serverCurrentTime: Double,
    serverIsFinished: Bool,
    serverUpdatedAt: Date?,
    detectedAt: Date,
    serverEbookProgress: Double? = nil,
    serverEbookLocation: String? = nil
  ) throws -> ProgressConflictRecord {
    var record =
      try ProgressConflictRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == identity.itemId)
      .filter(Column("podcastEpisodeId") == identity.podcastEpisodeId)
      .fetchOne(db)
      ?? ProgressConflictRecord(
        accountId: accountId, itemId: identity.itemId,
        podcastEpisodeId: identity.podcastEpisodeId, serverCurrentTime: serverCurrentTime,
        serverIsFinished: serverIsFinished, serverUpdatedAt: serverUpdatedAt,
        detectedAt: detectedAt)
    record.serverCurrentTime = serverCurrentTime
    record.serverIsFinished = serverIsFinished
    record.serverUpdatedAt = serverUpdatedAt
    record.detectedAt = detectedAt
    record.serverEbookProgress = serverEbookProgress
    record.serverEbookLocation = serverEbookProgress == nil ? nil : serverEbookLocation
    try record.save(db)
    return record
  }

  static func fetchProgress(
    _ db: Database, accountId: Int64, identity: MediaProgressIdentity
  ) throws -> MediaProgressRecord? {
    try MediaProgressRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == identity.itemId)
      .filter(Column("podcastEpisodeId") == identity.podcastEpisodeId)
      .fetchOne(db)
  }

  static func hasUnacknowledgedLocalOperation(
    _ db: Database,
    accountId: Int64,
    identity: MediaProgressIdentity,
    field: MediaProgressPendingField = .audioPosition
  ) throws -> Bool {
    guard let item = try ItemRecord.fetchOne(db, key: identity.itemId) else { return false }
    let states: [String] = [
      OutboxOperationState.pending.rawValue,
      OutboxOperationState.sending.rawValue,
      OutboxOperationState.retryWaiting.rawValue,
      OutboxOperationState.needsResolution.rawValue,
    ]
    let operationKinds: [String]
    // A reset protects its own medium's position and the shared finish, which it also clears.
    let resetMedia: [String]
    switch field {
    case .audioPosition:
      operationKinds = [OutboxOperationKind.progress.rawValue]
      resetMedia = [ProgressResetMedium.audio.rawValue]
    case .ebookPosition:
      operationKinds = [
        OutboxOperationKind.ebookPosition.rawValue,
        OutboxOperationKind.ebookReset.rawValue,
      ]
      resetMedia = [ProgressResetMedium.ebook.rawValue]
    case .sharedFinish:
      // Legacy audio one-shot progress rows carry their finish flag in the generic operation;
      // the dedicated ebook finish uses its own kind. Both protect only the shared flag.
      operationKinds = [
        OutboxOperationKind.progress.rawValue,
        OutboxOperationKind.ebookReset.rawValue,
        OutboxOperationKind.sharedFinish.rawValue,
      ]
      resetMedia = [ProgressResetMedium.audio.rawValue, ProgressResetMedium.ebook.rawValue]
    case .continueListeningVisibility:
      operationKinds = [OutboxOperationKind.continueListeningVisibility.rawValue]
      resetMedia = []
    }
    return try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("entityKey") == item.serverItemId)
      .filter(Column("podcastEpisodeId") == identity.podcastEpisodeId)
      .filter(
        operationKinds.contains(Column("operationKind"))
          || (Column("operationKind") == OutboxOperationKind.progressReset.rawValue
            && resetMedia.contains(Column("payloadResetMedium")))
      )
      .filter(states.contains(Column("state")))
      .fetchCount(db) > 0
  }

  static func validateEbookPositionJSON(_ value: String) throws {
    guard value.utf8.count <= maximumEbookJSONBytes else {
      throw MediaProgressDAOError.ebookPositionJSONTooLarge
    }
  }

  static func validateEbookLocation(_ value: String) throws {
    guard value.utf8.count <= maximumEbookStringBytes else {
      throw MediaProgressDAOError.ebookLocationTooLarge
    }
  }

  /// Mirrors ReaderCore's outbound CFI gate without importing the reader layer into Persistence.
  /// An invalid optional location may be present in a durable intent, but the drain omits it; an
  /// acknowledgement must therefore not promote that omitted value into server-authoritative
  /// progress or erase an existing CFI.
  static func validatedEPUBCFI(_ value: String?) -> String? {
    guard let value,
      value.utf8.isEmpty == false,
      value.utf8.count <= maximumEbookStringBytes,
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

  static func validatedEbookProgress(_ value: Double) throws -> Double {
    guard value.isFinite else { throw MediaProgressDAOError.invalidEbookProgress }
    return min(max(value, 0), 1)
  }
}
