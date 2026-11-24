import Foundation
import GRDB

/// One listener intent against one Audiobookshelf bookmark.
public enum AudioBookmarkIntent: Sendable, Equatable {
  case create(title: String)
  case rename(title: String)
  case delete
}

extension OutboxStore {
  static let audioBookmarkKinds: [String] = [
    OutboxOperationKind.bookmarkCreate.rawValue,
    OutboxOperationKind.bookmarkRename.rawValue,
    OutboxOperationKind.bookmarkDelete.rawValue,
  ]

  /// The states in which a bookmark operation still stands for the listener's intent rather than
  /// the server's: it has not been acknowledged and has not been given up on.
  static let unacknowledgedAudioBookmarkStates: [OutboxOperationState] = [
    .pending, .sending, .retryWaiting, .needsResolution,
  ]

  /// One bookmark's coalescing key. `time` enters by its bit pattern, so two bookmarks whose times
  /// differ in the last bit never merge.
  public static func audioBookmarkCoalescingKey(
    accountId: Int64, serverItemId: String, time: Double
  ) -> String {
    let bits = String(AudioBookmark.normalizedTime(time).bitPattern, radix: 16)
    return "bookmark:\(accountId):\(serverItemId):\(bits)"
  }

  /// Records one bookmark intent inside the caller's transaction, which must also hold the
  /// `audioBookmark` change.
  ///
  /// The newest unacknowledged row for the same bookmark absorbs the intent when it is still
  /// mergeable (`pending` or `retryWaiting`):
  ///
  /// | Queued | New | Result |
  /// |---|---|---|
  /// | create | rename | create with the new title |
  /// | create, never attempted | delete | the create is removed and nothing is sent |
  /// | create, attempted | delete | delete: the create may have landed |
  /// | rename | rename | the later title |
  /// | rename | delete | delete |
  /// | delete | create | create; the server's POST upserts the title if it still has it |
  ///
  /// Once that row is `sending` or `needsResolution`, the intent queues behind it as its own row.
  /// Bookmark rows share one `localSequence`, so rows on one item drain in insertion order.
  static func enqueueAudioBookmarkIntent(
    _ db: Database,
    accountId: Int64,
    serverItemId: String,
    time: Double,
    intent: AudioBookmarkIntent,
    clientOperationId: String,
    payloadVersion: Int = 1
  ) throws {
    let time = AudioBookmark.normalizedTime(time)
    let coalescingKey = Self.audioBookmarkCoalescingKey(
      accountId: accountId, serverItemId: serverItemId, time: time)
    let newest =
      try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("entityKey") == serverItemId)
      .filter(Column("coalescingKey") == coalescingKey)
      .filter(Self.audioBookmarkKinds.contains(Column("operationKind")))
      .filter(Self.unacknowledgedAudioBookmarkStates.map(\.rawValue).contains(Column("state")))
      .order(Column("id").desc)
      .fetchOne(db)

    if var existing = newest, Self.mergeableStates.contains(existing.state) {
      switch (OutboxOperationKind(rawValue: existing.operationKind), intent) {
      case (.bookmarkCreate, .delete) where existing.attempts == 0:
        // `attempts` counts every move to `sending` and is never reduced, so zero means no
        // request for this create ever left the device.
        _ = try existing.delete(db)
        return
      case (_, .delete):
        existing.operationKind = OutboxOperationKind.bookmarkDelete.rawValue
        existing.payloadBookmarkTitle = nil
      case (_, .create(let title)):
        existing.operationKind = OutboxOperationKind.bookmarkCreate.rawValue
        existing.payloadBookmarkTitle = title
      case (.bookmarkDelete, .rename):
        // The local row is gone, so the store never asks for this; a rename cannot undo a delete.
        return
      case (_, .rename(let title)):
        existing.payloadBookmarkTitle = title
      }
      try existing.update(db)
      return
    }

    let kind: OutboxOperationKind
    let title: String?
    switch intent {
    case .create(let newTitle):
      kind = .bookmarkCreate
      title = newTitle
    case .rename(let newTitle):
      kind = .bookmarkRename
      title = newTitle
    case .delete:
      kind = .bookmarkDelete
      title = nil
    }
    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId,
      entityKey: serverItemId,
      podcastEpisodeId: nil,
      operationKind: kind.rawValue,
      coalescingKey: coalescingKey,
      payloadVersion: payloadVersion,
      localSequence: 0,
      payloadBookmarkTime: time,
      payloadBookmarkTitle: title)
    try record.insert(db)
  }

  /// Every bookmark whose listener intent has not yet been acknowledged. A pull must leave each
  /// of these as the listener last set it: a pending create is not removed, a pending delete is not
  /// brought back, and a pending rename keeps its title.
  static func unacknowledgedAudioBookmarkKeys(
    _ db: Database, accountId: Int64
  ) throws -> Set<AudioBookmarkKey> {
    let rows =
      try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Self.audioBookmarkKinds.contains(Column("operationKind")))
      .filter(Self.unacknowledgedAudioBookmarkStates.map(\.rawValue).contains(Column("state")))
      .fetchAll(db)
    return Set(
      rows.compactMap { row in
        row.payloadBookmarkTime.map { AudioBookmarkKey(serverItemID: row.entityKey, time: $0) }
      })
  }
}
