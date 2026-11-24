import ABSApi
import Foundation

/// `/api/me` is not a set-valued API contract: several rows can name one identity, and the
/// dictionary a caller files them in must not make the winner depend on response order. This
/// extension keeps that choice here, beside the merge order it extends, so the show-refresh path
/// and the `/api/me` item path cannot pick different winners.
extension ProgressMergePolicy {
  /// One server progress row offered for duplicate resolution, with the whole row kept so the
  /// caller can read the fields no ordering decision needs.
  public struct DuplicateServerRow: Sendable, Equatable {
    public let row: MediaProgress
    let order: Order

    public init(_ row: MediaProgress) {
      self.row = row
      self.order = Order(row)
    }
  }

  /// The one row of `rows` a merge should use: the greatest by `Order`, or nil for no rows.
  /// Because `Order` covers every field either path reads, the same input set yields the same
  /// winner in any order.
  public func resolveDuplicateServerRows(_ rows: [DuplicateServerRow]) -> DuplicateServerRow? {
    guard let first = rows.first else { return nil }
    return rows.dropFirst().reduce(first) { winner, next in
      next.order > winner.order ? next : winner
    }
  }
}

extension ProgressMergePolicy.DuplicateServerRow {
  /// The deterministic total order over duplicate rows. Its prefix is `MergeOrderKey`, the same
  /// comparator `candidateWins` uses (`serverUpdatedAt`, `isFinished`, `currentTime`; every
  /// candidate is a server row, so the origin component is constant), then it extends that with
  /// the fields a merge decision never reads, so a tie is still decided by row content:
  /// `startedAt` feeds reset evidence, and `serverProgressID` makes the order total for decodable
  /// rows. Remaining DTO fields ride in `residualKey`.
  struct Order: Comparable, Sendable, Equatable {
    let mergeOrder: ProgressMergePolicy.MergeOrderKey
    let ebookProgress: Double?
    let ebookLocation: String?
    let startedAt: Date?
    let serverProgressID: String?
    let hideFromContinueListening: Bool
    let residualKey: String

    init(_ row: MediaProgress) {
      mergeOrder = ProgressMergePolicy.MergeOrderKey(
        serverUpdatedAt: row.lastUpdate,
        isFinished: row.isFinished,
        position: row.currentTime,
        originKey: ProgressMergePolicy.serverOriginKey)
      ebookProgress = row.ebookProgress
      ebookLocation = row.ebookLocation
      startedAt = row.startedAt
      serverProgressID = row.serverProgressID
      hideFromContinueListening = row.hideFromContinueListening
      residualKey = Self.residualKey(row)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.mergeOrder != rhs.mergeOrder { return lhs.mergeOrder < rhs.mergeOrder }
      if lhs.ebookProgress != rhs.ebookProgress {
        return Self.lower(lhs.ebookProgress, rhs.ebookProgress)
      }
      if lhs.ebookLocation != rhs.ebookLocation {
        return Self.lower(lhs.ebookLocation, rhs.ebookLocation)
      }
      if lhs.startedAt != rhs.startedAt { return Self.lower(lhs.startedAt, rhs.startedAt) }
      if lhs.serverProgressID != rhs.serverProgressID {
        return Self.lower(lhs.serverProgressID, rhs.serverProgressID)
      }
      if lhs.hideFromContinueListening != rhs.hideFromContinueListening {
        return rhs.hideFromContinueListening
      }
      return lhs.residualKey < rhs.residualKey
    }

    /// Unequal optionals order a present value above an absent one, then by value; `Optional`
    /// itself is not `Comparable`.
    private static func lower<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool {
      switch (lhs, rhs) {
      case (.some(let left), .some(let right)): return left < right
      case (.none, .some): return true
      case (.some, .none), (.none, .none): return false
      }
    }

    private static func residualKey(_ row: MediaProgress) -> String {
      let separator = "\u{1F}"
      func text(_ value: Double?) -> String { value.map { String($0) } ?? "" }
      let finishedAt = row.finishedAt.map { String($0.timeIntervalSince1970) } ?? ""
      return (row.mediaItemID ?? "") + separator + (row.mediaItemType ?? "") + separator
        + text(row.duration) + separator + text(row.progress) + separator + finishedAt
    }
  }
}
