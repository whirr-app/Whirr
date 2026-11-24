import CoreSupport
import Foundation

/// The local-session reconciliation device trace (`WHIRRSYNC localall`), read alongside the
/// other `WHIRRSYNC` records with:
///
///     log stream --predicate 'eventMessage CONTAINS "WHIRRSYNC localall"'
///
/// The outbox and UI do not distinguish one local-all batch from several, or from a coalesced
/// trigger that found no work; these records make that visible without changing the drain.
///
/// `drain=start` is emitted before the coalescing check, so a trigger coalescing onto a running
/// drain emits a start line (`coalesced=1`) with no `drain=end`. Count `drain=end` lines to
/// count drains.
///
/// Counts only: no session, client session, item or episode ids, URLs, tokens or timestamps
/// (SECURITY.md). Unlike `DownloadDeviceTrace`, the batch, session and accepted/rejected counts
/// suffice to tell concurrent work apart.
public enum LocalAllDeviceTrace {
  public static let prefix = "WHIRRSYNC localall"

  public struct DrainStart: Equatable, Sendable {
    public let coalesced: Int

    public init(coalesced: Int) {
      self.coalesced = coalesced
    }
  }

  public enum BatchResult: String, Equatable, Sendable {
    case ok
    case httpError
    case transport
    case cancelled
  }

  public struct Batch: Equatable, Sendable {
    public let index: Int
    public let sessions: Int
    public let result: BatchResult
    public let accepted: Int
    public let rejected: Int

    public init(index: Int, sessions: Int, result: BatchResult, accepted: Int, rejected: Int) {
      self.index = index
      self.sessions = sessions
      self.result = result
      self.accepted = accepted
      self.rejected = rejected
    }
  }

  public struct DrainEnd: Equatable, Sendable {
    public let batches: Int
    public let sessions: Int
    public let halted: Bool

    public init(batches: Int, sessions: Int, halted: Bool = false) {
      self.batches = batches
      self.sessions = sessions
      self.halted = halted
    }
  }

  public enum Record: Equatable, Sendable {
    case drainStart(DrainStart)
    case batch(Batch)
    case drainEnd(DrainEnd)
  }

  public static func line(_ record: Record) -> String {
    switch record {
    case .drainStart(let start):
      return "\(prefix) drain=start coalesced=\(start.coalesced)"
    case .batch(let batch):
      return
        "\(prefix) batch=\(batch.index) sessions=\(batch.sessions) result=\(batch.result.rawValue) accepted=\(batch.accepted) rejected=\(batch.rejected)"
    case .drainEnd(let end):
      let halted = end.halted ? " halted=1" : ""
      return "\(prefix) drain=end batches=\(end.batches) sessions=\(end.sessions)\(halted)"
    }
  }

  public static func emit(_ record: Record) {
    #if DEBUG
      DeviceTraceLog.emit(line(record))
    #endif
  }
}
