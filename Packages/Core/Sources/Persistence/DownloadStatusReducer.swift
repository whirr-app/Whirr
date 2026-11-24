import Foundation

/// The fields needed to reduce one download row without coupling the reducer to a fetch shape.
/// Item-level and episode-level readers build this projection from their own queries.
struct DownloadStatusProjection: Sendable {
  let expectedBytes: Int64
  let receivedBytes: Int64
  let state: DownloadState
  let holdReason: DownloadHoldReason?
  let errorCategory: DownloadErrorCategory?

  init(
    expectedBytes: Int64,
    receivedBytes: Int64,
    state: DownloadState,
    holdReason: DownloadHoldReason?,
    errorCategory: DownloadErrorCategory?
  ) {
    self.expectedBytes = expectedBytes
    self.receivedBytes = receivedBytes
    self.state = state
    self.holdReason = holdReason
    self.errorCategory = errorCategory
  }

  init(record: DownloadRecord) {
    self.init(
      expectedBytes: record.expectedBytes,
      receivedBytes: record.receivedBytes,
      state: record.state,
      holdReason: record.holdReason,
      errorCategory: record.errorCategory)
  }
}

/// One Persistence-owned reduction of per-file download rows into the detailed item status.
enum DownloadStatusReducer {
  static func reduce(_ rows: [DownloadStatusProjection]) -> ItemDownloadStatus {
    guard rows.isEmpty == false else { return .notDownloaded }

    let liveRows = rows.filter { $0.state != .deleting }
    guard liveRows.isEmpty == false else { return .deleting }

    if liveRows.contains(where: { $0.state == .pausedAuth }) { return .pausedAuth }
    if let failedRow = liveRows.first(where: { $0.state == .failed }) {
      return .failed(category: failedRow.errorCategory ?? .unknown)
    }
    if liveRows.contains(where: { $0.state == .paused }) { return .paused }
    if liveRows.contains(where: { $0.state == .downloading }) {
      let totalExpected = liveRows.reduce(into: Int64(0)) { $0 += $1.expectedBytes }
      let totalReceived = liveRows.reduce(into: Int64(0)) { $0 += $1.receivedBytes }
      let fraction = totalExpected > 0 ? Double(totalReceived) / Double(totalExpected) : 0
      return .downloading(progressFraction: min(max(fraction, 0), 1))
    }
    if liveRows.contains(where: { $0.state == .pending && $0.holdReason == .waitingForWiFi }) {
      return .waitingForWiFi
    }
    if liveRows.contains(where: { $0.state == .interrupted }) { return .interrupted }
    if liveRows.contains(where: { $0.state == .pending }) { return .queued }
    return .completed
  }
}
