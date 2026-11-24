import Persistence

/// Merges the account-owned ABS and device-owned RSS Continue Listening projections.
///
/// The RSS namespace is reserved (`rss:`), so the cross-source identity collision handled here
/// is defensive rather than a merge strategy. The function is pure so both Home
/// surfaces share the same ordering, deduplication, and limit semantics.
public enum ContinueListeningMerge: Sendable {
  private struct Identity: Hashable {
    let serverItemId: String
    let episodeID: String?
  }

  public static func merge(
    abs: [HomeItem],
    rss: [HomeItem],
    nativeSubscriptionsEnabled: Bool,
    limit: Int
  ) -> [HomeItem] {
    let candidates = (abs + (nativeSubscriptionsEnabled ? rss : [])).sorted { lhs, rhs in
      switch (lhs.progressRecency, rhs.progressRecency) {
      case (let left?, let right?) where left != right:
        return left > right
      case (nil, .some):
        return false
      case (.some, nil):
        return true
      default:
        break
      }

      if lhs.serverItemId != rhs.serverItemId {
        return lhs.serverItemId < rhs.serverItemId
      }

      switch (lhs.episodeID, rhs.episodeID) {
      case (let left?, let right?) where left != right:
        return left < right
      case (nil, .some):
        return true
      case (.some, nil):
        return false
      default:
        return false
      }
    }

    var seen = Set<Identity>()
    var result: [HomeItem] = []
    result.reserveCapacity(candidates.count)
    for item in candidates {
      let identity = Identity(serverItemId: item.serverItemId, episodeID: item.episodeID)
      guard seen.insert(identity).inserted else { continue }
      result.append(item)
    }
    return Array(result.prefix(max(0, limit)))
  }
}
