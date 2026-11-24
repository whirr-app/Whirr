import Foundation
import WatchProtocol

/// What the Watch last knew about one received RSS episode. Unlike an ABS progress row it carries
/// no listening total: the phone's writer takes a position and the time it was listened to.
public struct WatchNativeListen: Sendable, Equatable {
  public let position: Double
  /// When the listener last played or sought the episode; `nil` until the first listen.
  public let lastListenedAt: Date?
  public let isFinished: Bool
  public let duration: Double?

  public init(position: Double, lastListenedAt: Date?, isFinished: Bool, duration: Double?) {
    self.position = position
    self.lastListenedAt = lastListenedAt
    self.isFinished = isFinished
    self.duration = duration
  }
}

public enum WatchNativeProgressJournalError: Error, Sendable, Equatable {
  /// The journal keeps native-feed rows only; an Audiobookshelf title has its own store.
  case absSelection
  case invalidSelection
  case invalidPosition
  case invalidDelta
  case invalidDuration
  case notFound(UUID)
  case storageFailure
}

/// Progress for received RSS episodes on the Watch. Native RSS state is device-owned, but a copy's
/// lifetime is fenced by the Watch's own account stamp, so the journal lives beside the
/// received copies and reads as empty under another account.
///
/// The journal does not own a copy: opening a row does not make an episode playable, and removing
/// one is `retainOnly`'s job. It holds no listening total, so the only thing it can hand the phone
/// is the last position, listen time and finish.
public actor WatchNativeProgressJournal: WatchProgressJournaling {
  /// Two rows per episode (the one in use and the newest one it replaced) for at most the offer's
  /// worth of episodes. Beyond this the least recently touched episodes go first, because their
  /// rows can no longer be reported once the copy is gone.
  public static let maximumRows = 2 * WatchEpisodeSendLimits.maxOfferEntries

  /// The row the lifecycle is using plus the newest row before it. Older rows are superseded: a
  /// later listen for the same episode already says a newer position and listen time.
  static let rowsPerSelection = 2

  public let fileURL: URL
  public let accountStamp: WatchAccountStamp

  private let persistence: WatchAccountFencedJSONStore<Payload>
  private let now: @Sendable () -> Date
  /// In open order. The lifecycle opens a new row only after it has stopped using the previous
  /// one, so the last row for a selection is the open or most recently used one.
  private var rows: [Row]

  struct Row: Codable, Sendable, Equatable {
    let id: UUID
    let selection: WatchNativeSelection
    let startedAt: Date
    var updatedAt: Date
    let startPosition: Double?
    var currentPosition: Double
    var duration: Double?
    var isFinished: Bool
    /// Set only by listening or a user seek, never by a rewrite, so it says which device was used
    /// last rather than which one saved last.
    var lastListenedAt: Date?
    /// Bumped on every write that changes what the phone should hear; persisted so a report sent
    /// before a relaunch is not sent again.
    var revision: Int
    var reportedRevision: Int

    var hasProgressToSend: Bool { isFinished || lastListenedAt != nil }
  }

  struct Payload: Codable, Sendable {
    var rows: [Row]
  }

  public init(
    fileURL: URL, accountStamp: WatchAccountStamp, now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    self.fileURL = fileURL
    self.accountStamp = accountStamp
    let persistence = WatchAccountFencedJSONStore<Payload>(
      location: .file(fileURL), accountStamp: accountStamp)
    self.persistence = persistence
    self.now = now

    do {
      if let payload = try persistence.load() {
        // A row that cannot be trusted is dropped alone: refusing the file would fail every later
        // launch for this account.
        let restored = Self.validRows(payload.rows)
        self.rows = restored
        if restored.count != payload.rows.count { try persistence.save(Payload(rows: restored)) }
      } else {
        self.rows = []
        do {
          try persistence.save(Payload(rows: []))
        } catch WatchFencedStoreError.io(let error) {
          throw error
        }
      }
    } catch let error as WatchFencedStoreError {
      switch error {
      case .corrupt, .versionMismatch:
        // This build cannot read the file, but another may: it is set aside, not overwritten.
        let aside = fileURL.deletingLastPathComponent()
          .appendingPathComponent("native-progress.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: fileURL, to: aside)
        self.rows = []
        do {
          try persistence.save(Payload(rows: []))
        } catch { throw WatchNativeProgressJournalError.storageFailure }
      case .foreignAccount:
        // Another account's file is left untouched so signing back in restores it; this account
        // simply has no progress.
        self.rows = []
      case .io:
        throw WatchNativeProgressJournalError.storageFailure
      }
    }
  }

  /// The row with the newest listen, open or closed, or with the newest write when none has been
  /// listened to. `nil` once the selection has been dropped.
  public func latest(for selection: WatchNativeSelection) -> WatchNativeListen? {
    guard let row = Self.mostRecent(rows.filter { $0.selection == selection }) else { return nil }
    return WatchNativeListen(
      position: row.currentPosition, lastListenedAt: row.lastListenedAt, isFinished: row.isFinished,
      duration: row.duration)
  }

  /// At most one entry per episode: its newest closed row that has a listen newer than anything
  /// reported. Rows in `openIDs` are still being written, so reporting one would report a partial
  /// position the next tick immediately supersedes.
  public func pendingReport(
    excluding openIDs: Set<UUID>, limit: Int = WatchPendingProgressLimits.maxEntries
  ) throws -> [WatchNativeProgressEntry] {
    guard limit > 0 else { return [] }
    // The newest closed listen per episode decides; an older unreported row behind a reported newer
    // one would only send the phone a position it already has something newer than.
    var newest: [WatchNativeSelection: (row: Row, listenedAt: Date)] = [:]
    for row in rows {
      guard !openIDs.contains(row.id), let listenedAt = row.lastListenedAt else { continue }
      if let current = newest[row.selection], !Self.isNewer(row, than: current.row) { continue }
      newest[row.selection] = (row, listenedAt)
    }
    let pending = newest.values.filter { $0.row.revision > $0.row.reportedRevision }
    return try pending.sorted { Self.isNewer($0.row, than: $1.row) }.prefix(limit).map { item in
      // The entry re-checks the bounds the journal admitted the row with.
      try WatchNativeProgressEntry(
        selection: item.row.selection, position: item.row.currentPosition,
        lastListenedAt: item.listenedAt, isFinished: item.row.isFinished,
        duration: item.row.duration)
    }
  }

  /// Called once the report has been handed to `transferUserInfo`, which delivers queued items
  /// across relaunches, so there is no phone acknowledgement to wait for. A row recorded again
  /// later gets a newer revision and becomes pending again.
  public func markReported(_ entries: [WatchNativeProgressEntry]) throws {
    guard entries.isEmpty == false else { return }
    var updated = rows
    var changed = false
    for entry in entries {
      // The row that produced an entry is the newest one for the episode with that listen time. A
      // row recorded since carries a newer time and is left pending.
      let candidates = updated.indices.filter {
        updated[$0].selection == entry.selection
          && updated[$0].lastListenedAt == entry.lastListenedAt
          && updated[$0].reportedRevision < updated[$0].revision
      }
      guard let index = candidates.max(by: { updated[$0].revision < updated[$1].revision }) else {
        continue
      }
      updated[index].reportedRevision = updated[index].revision
      changed = true
    }
    guard changed else { return }
    try applying { rows in rows = updated }
  }

  /// Drops rows for episodes whose copy is gone, so a removed episode never keeps the sync loop
  /// awake. An unreported FINISHED row survives even when its copy is gone: the phone must still
  /// hear that the episode was played to the end, and the row goes on the next report.
  public func retainOnly(_ selections: Set<WatchNativeSelection>) throws {
    try applying { rows in
      rows = Self.compacted(
        rows.filter { selections.contains($0.selection) || Self.isUnreportedFinish($0) })
    }
  }

  public func removeAll() throws {
    try applying { rows in rows = [] }
  }

  // MARK: WatchProgressJournaling

  public func openRow(
    selection: WatchSelection,
    startPosition: Double?,
    duration: Double?,
    lastKnownSharedPosition: Double?,
    lastKnownSharedObservedAt: Date?
  ) throws -> UUID {
    guard let native = WatchNativeSelection(selection) else {
      throw WatchNativeProgressJournalError.absSelection
    }
    do {
      try native.validate()
    } catch {
      throw WatchNativeProgressJournalError.invalidSelection
    }
    try Self.validateStart(
      startPosition: startPosition, duration: duration,
      lastKnownSharedPosition: lastKnownSharedPosition,
      lastKnownSharedObservedAt: lastKnownSharedObservedAt)
    let timestamp = now()
    let row = Row(
      id: UUID(), selection: native, startedAt: timestamp, updatedAt: timestamp,
      startPosition: startPosition, currentPosition: startPosition ?? 0, duration: duration,
      isFinished: false, lastListenedAt: nil, revision: 0, reportedRevision: 0)
    try applying { rows in
      rows.append(row)
      rows = Self.compacted(rows)
    }
    return row.id
  }

  @discardableResult
  public func recordRow(
    id: UUID, currentPosition: Double, listenedDelta: Double, isFinished: Bool, userSeek: Bool
  ) throws -> Bool {
    guard currentPosition.isFinite, currentPosition >= 0,
      currentPosition <= WatchHandoffLimits.maxPositionSeconds
    else { throw WatchNativeProgressJournalError.invalidPosition }
    guard listenedDelta.isFinite, listenedDelta >= 0 else {
      throw WatchNativeProgressJournalError.invalidDelta
    }
    guard let index = rows.firstIndex(where: { $0.id == id }) else {
      throw WatchNativeProgressJournalError.notFound(id)
    }
    var row = rows[index]
    if let duration = row.duration, currentPosition > duration {
      throw WatchNativeProgressJournalError.invalidPosition
    }
    let timestamp = now()
    row.currentPosition = currentPosition
    row.updatedAt = timestamp
    row.isFinished = row.isFinished || isFinished
    if listenedDelta > 0 || userSeek { row.lastListenedAt = timestamp }
    row.revision += 1
    try applying { rows in rows[index] = row }
    return row.hasProgressToSend
  }

  public func growRowDuration(id: UUID, to duration: Double) throws {
    guard duration.isFinite, duration > 0, duration <= WatchHandoffLimits.maxPositionSeconds else {
      throw WatchNativeProgressJournalError.invalidDuration
    }
    guard let index = rows.firstIndex(where: { $0.id == id }) else {
      throw WatchNativeProgressJournalError.notFound(id)
    }
    guard let current = rows[index].duration, duration > current else { return }
    try applying { rows in
      rows[index].duration = duration
      rows[index].revision += 1
    }
  }

  public func deleteRow(id: UUID) throws {
    guard let index = rows.firstIndex(where: { $0.id == id }) else {
      throw WatchNativeProgressJournalError.notFound(id)
    }
    try applying { rows in rows.remove(at: index) }
  }

  // MARK: Test seams

  var rowCount: Int { rows.count }

  func rowCount(for selection: WatchNativeSelection) -> Int {
    rows.filter { $0.selection == selection }.count
  }

  // MARK: Compaction

  /// Keeps the newest `rowsPerSelection` rows of each episode, then whole episodes, least recently
  /// touched first, until the total fits `maximumRows`. An unreported finish is kept by the
  /// per-episode pass like any other row; only the global bound can drop one, and that needs more
  /// episodes with rows than an offer may name.
  private static func compacted(_ rows: [Row]) -> [Row] {
    var counts: [WatchNativeSelection: Int] = [:]
    var kept: [Row] = []
    for row in rows.reversed() {
      let count = counts[row.selection, default: 0]
      guard count < rowsPerSelection else { continue }
      counts[row.selection] = count + 1
      kept.append(row)
    }
    var compacted = Array(kept.reversed())
    guard compacted.count > maximumRows else { return compacted }

    let groups = Dictionary(grouping: compacted, by: \.selection)
    let order = groups.keys.sorted { lhs, rhs in
      guard let left = mostRecent(groups[lhs] ?? []), let right = mostRecent(groups[rhs] ?? [])
      else { return false }
      if isNewer(left, than: right) { return false }
      if isNewer(right, than: left) { return true }
      return (lhs.feedID, lhs.episodeID) < (rhs.feedID, rhs.episodeID)
    }
    var remaining = compacted.count
    var dropped: Set<WatchNativeSelection> = []
    for selection in order {
      guard remaining > maximumRows else { break }
      dropped.insert(selection)
      remaining -= groups[selection]?.count ?? 0
    }
    compacted.removeAll { dropped.contains($0.selection) }
    return compacted
  }

  // MARK: Helpers

  /// Applies a change and saves it. A save that throws restores the rows exactly as they were, so a
  /// caller that carries its listening into the next write does not count it twice.
  private func applying(_ change: (inout [Row]) -> Void) throws {
    let previous = rows
    change(&rows)
    do {
      try persistence.save(Payload(rows: rows))
    } catch {
      rows = previous
      throw WatchNativeProgressJournalError.storageFailure
    }
  }

  private static func isUnreportedFinish(_ row: Row) -> Bool {
    row.isFinished && row.revision > row.reportedRevision
  }

  /// Rows that have been listened to always outrank rows that have only been written, because a
  /// write without listening says nothing about which device was used last.
  private static func isNewer(_ lhs: Row, than rhs: Row) -> Bool {
    switch (lhs.lastListenedAt, rhs.lastListenedAt) {
    case (let left?, let right?): return left == right ? lhs.updatedAt > rhs.updatedAt : left > right
    case (.some, .none): return true
    case (.none, .some): return false
    case (.none, .none): return lhs.updatedAt > rhs.updatedAt
    }
  }

  private static func mostRecent(_ rows: [Row]) -> Row? {
    var best: Row?
    for row in rows {
      if let current = best {
        if isNewer(row, than: current) { best = row }
      } else {
        best = row
      }
    }
    return best
  }

  private static func validateStart(
    startPosition: Double?,
    duration: Double?,
    lastKnownSharedPosition: Double?,
    lastKnownSharedObservedAt: Date?
  ) throws {
    if let startPosition {
      guard startPosition.isFinite, startPosition >= 0,
        startPosition <= WatchHandoffLimits.maxPositionSeconds
      else { throw WatchNativeProgressJournalError.invalidPosition }
    }
    if let duration {
      guard duration.isFinite, duration > 0, duration <= WatchHandoffLimits.maxPositionSeconds else {
        throw WatchNativeProgressJournalError.invalidDuration
      }
    }
    if let startPosition, let duration, startPosition > duration {
      throw WatchNativeProgressJournalError.invalidPosition
    }
    // A local copy has no shared progress to anchor to; the values are checked for the lifecycle's
    // contract and then dropped, because nothing here reads them back.
    if let lastKnownSharedPosition {
      guard lastKnownSharedPosition.isFinite, lastKnownSharedPosition >= 0 else {
        throw WatchNativeProgressJournalError.invalidPosition
      }
    }
    if let lastKnownSharedObservedAt {
      guard lastKnownSharedObservedAt.timeIntervalSinceReferenceDate.isFinite else {
        throw WatchNativeProgressJournalError.invalidPosition
      }
    }
  }

  private static func validRows(_ rows: [Row]) -> [Row] {
    var seen: Set<UUID> = []
    var kept: [Row] = []
    for row in rows where seen.insert(row.id).inserted {
      guard (try? row.selection.validate()) != nil,
        row.startedAt.timeIntervalSinceReferenceDate.isFinite,
        row.updatedAt.timeIntervalSinceReferenceDate.isFinite,
        row.startPosition.map({ $0.isFinite && $0 >= 0 && $0 <= WatchHandoffLimits.maxPositionSeconds })
          ?? true,
        row.currentPosition.isFinite, row.currentPosition >= 0,
        row.currentPosition <= WatchHandoffLimits.maxPositionSeconds,
        row.duration.map({
          $0.isFinite && $0 > 0 && $0 <= WatchHandoffLimits.maxPositionSeconds
        }) ?? true,
        row.duration.map({ current in row.currentPosition <= current }) ?? true,
        row.lastListenedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
        row.revision >= 0
      else { continue }
      var restored = row
      restored.reportedRevision = min(max(row.reportedRevision, 0), row.revision)
      kept.append(restored)
    }
    return kept
  }
}
