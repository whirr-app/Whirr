import Foundation

/// The one ordering rule the server and native "Your Shows" surfaces share.
///
/// The two surfaces keep their own stores, sort-mode enums and readiness barriers; only the pure
/// sequence operations and the copy a failed write surfaces live here so they cannot drift apart.
enum ShowOrderingPolicy {
  static let reorderFailed = "Couldn't save your show order. Try again."
  static let resetFailed = "Couldn't reset your show order. Try again."

  /// Truncates an already-ordered sequence without reordering it. A non-positive limit yields none.
  static func preview<Element>(_ shows: [Element], limit: Int) -> [Element] {
    Array(shows.prefix(max(0, limit)))
  }

  /// Pure and total: an unknown id leaves the sequence untouched, and a destination outside the
  /// range clamps to the ends rather than trapping. The destination is an index in the sequence
  /// after the moved id is removed, which is what drag and the accessibility move actions report.
  static func reorder(_ itemIDs: [String], moving itemID: String, to destination: Int) -> [String] {
    guard let current = itemIDs.firstIndex(of: itemID) else { return itemIDs }
    var reordered = itemIDs
    reordered.remove(at: current)
    reordered.insert(itemID, at: min(max(destination, 0), reordered.count))
    return reordered
  }
}
