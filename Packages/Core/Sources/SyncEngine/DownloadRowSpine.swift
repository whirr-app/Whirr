import Foundation
import Persistence

/// One download table's row, reduced to what the automatic-retry decision reads. The tables keep
/// their own records; this is the common shape the retry body is written against, not a merged row.
struct DownloadRowRetryState: Equatable, Sendable {
  var id: Int64
  var state: DownloadState
  var origin: DownloadOrigin
  var autoRetryCount: Int
  var autoRetryNotBefore: Date?
}

/// The automatic-retry path's whole view of one download table: read one row, decide whether the
/// row is a failed automatic row, arm a deadline, list due rows and spend one attempt. Each table
/// keeps its own records, error column (`errorCategory` for ABS, `errorCode` for RSS) and delete
/// rules; the adapter is where those differences stay. Row ids are never compared across tables:
/// callers hold a tagged `TransferIdentity`.
protocol DownloadRowSpine: Sendable {
  func fetch(id: Int64) async -> DownloadRowRetryState?
  func isFailedAutomatic(row: DownloadRowRetryState) -> Bool
  func arm(id: Int64, notBefore: Date) async -> Bool
  func due(now: Date, limit: Int) async -> [(id: Int64, notBefore: Date)]
  /// Spends one attempt on a due row and returns the new count, or `nil` when the row was no
  /// longer due.
  func requeue(id: Int64, now: Date) async -> Int?
}

extension DownloadRowSpine {
  /// `DownloadState` and `DownloadOrigin` are shared by both tables, so the failure test is one
  /// body. The store repeats it in the guarded arm and requeue writes, because the row can move
  /// between this read and that write.
  func isFailedAutomatic(row: DownloadRowRetryState) -> Bool {
    row.state == .failed && row.origin == .automatic
  }
}

/// The ABS table, `download`.
struct AbsDownloadRowSpine: DownloadRowSpine {
  let store: DownloadStore

  func fetch(id: Int64) async -> DownloadRowRetryState? {
    guard let row = try? await store.fetchAsync(downloadId: id) else { return nil }
    return Self.retryState(row)
  }

  func arm(id: Int64, notBefore: Date) async -> Bool {
    (try? await store.armAutomaticRetryAsync(downloadId: id, notBefore: notBefore)) == true
  }

  func due(now: Date, limit: Int) async -> [(id: Int64, notBefore: Date)] {
    let rows = (try? await store.fetchDueAutomaticRetriesAsync(now: now, limit: limit)) ?? []
    return rows.compactMap { dueEntry(id: $0.id, notBefore: $0.autoRetryNotBefore) }
  }

  func requeue(id: Int64, now: Date) async -> Int? {
    guard let row = try? await store.requeueAutomaticRetryAsync(downloadId: id, now: now) else {
      return nil
    }
    return row.autoRetryCount
  }

  private static func retryState(_ row: DownloadRecord) -> DownloadRowRetryState? {
    guard let id = row.id else { return nil }
    return DownloadRowRetryState(
      id: id, state: row.state, origin: row.origin, autoRetryCount: row.autoRetryCount,
      autoRetryNotBefore: row.autoRetryNotBefore)
  }
}

/// The device-owned RSS table, `rssDownload`.
struct RssDownloadRowSpine: DownloadRowSpine {
  let store: RSSDownloadStore

  func fetch(id: Int64) async -> DownloadRowRetryState? {
    guard let row = try? await store.fetchAsync(downloadId: id) else { return nil }
    guard let rowId = row.id else { return nil }
    return DownloadRowRetryState(
      id: rowId, state: row.state, origin: row.origin, autoRetryCount: row.autoRetryCount,
      autoRetryNotBefore: row.autoRetryNotBefore)
  }

  func arm(id: Int64, notBefore: Date) async -> Bool {
    (try? await store.armAutomaticRetryAsync(downloadId: id, notBefore: notBefore)) == true
  }

  func due(now: Date, limit: Int) async -> [(id: Int64, notBefore: Date)] {
    let rows = (try? await store.fetchDueAutomaticRetriesAsync(now: now, limit: limit)) ?? []
    return rows.compactMap { dueEntry(id: $0.id, notBefore: $0.autoRetryNotBefore) }
  }

  func requeue(id: Int64, now: Date) async -> Int? {
    guard let row = try? await store.requeueAutomaticRetryAsync(downloadId: id, now: now) else {
      return nil
    }
    return row.autoRetryCount
  }
}

private func dueEntry(id: Int64?, notBefore: Date?) -> (id: Int64, notBefore: Date)? {
  guard let id, let notBefore else { return nil }
  return (id, notBefore)
}
