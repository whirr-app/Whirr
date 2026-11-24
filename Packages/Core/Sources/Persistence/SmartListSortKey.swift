import Foundation

/// A position in a smart list's total order: `(isPriority DESC, value IS NULL, value <dir>, source,
/// showKey, episodeID)`. `value` is the publication time in whole milliseconds since 1970 for
/// Newest and Oldest, and the known length in seconds for Shortest and Longest; nil (undated, or
/// unknown length) sorts after every known value in both directions.
///
/// The key is stored on `smartListRun.anchorSortKey` as `encoded`, so a run keeps its place after
/// the anchor's row is hidden, finished or deleted. `precedes` and the SQL the reading builds from
/// the same fields agree row for row.
public struct SmartListSortKey: Sendable, Codable, Equatable {
  public let order: SmartListSortOrder
  public let isPriority: Bool
  public let value: Double?
  public let source: SmartListShowSource
  public let showKey: String
  public let episodeID: String

  public init(
    order: SmartListSortOrder, isPriority: Bool, value: Double?, source: SmartListShowSource,
    showKey: String, episodeID: String
  ) {
    self.order = order
    self.isPriority = isPriority
    self.value = value
    self.source = source
    self.showKey = showKey
    self.episodeID = episodeID
  }

  /// The value sorts downwards for Newest and Longest.
  var valueDescends: Bool { order == .newest || order == .longest }

  /// True when `self` is listed before `other` in `order`. Both keys must share an order; a key
  /// from another order compares by this key's order, which is only meaningful for a stale anchor.
  public func precedes(_ other: SmartListSortKey) -> Bool {
    if isPriority != other.isPriority { return isPriority }
    switch (value, other.value) {
    case (nil, .some): return false
    case (.some, nil): return true
    case (let lhs?, let rhs?) where lhs != rhs:
      return valueDescends ? lhs > rhs : lhs < rhs
    default: break
    }
    // SQLite's BINARY collation compares UTF-8 bytes; Swift's String ordering does not.
    if source != other.source { return source.rawValue.utf8.lexicographicallyPrecedes(other.source.rawValue.utf8) }
    if showKey != other.showKey { return showKey.utf8.lexicographicallyPrecedes(other.showKey.utf8) }
    return episodeID.utf8.lexicographicallyPrecedes(other.episodeID.utf8)
  }

  /// The text stored in `smartListRun.anchorSortKey`.
  public var encoded: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// Nil when `encoded` is not a key this version wrote.
  public init?(encoded: String) {
    guard let key = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)) else {
      return nil
    }
    self = key
  }
}
