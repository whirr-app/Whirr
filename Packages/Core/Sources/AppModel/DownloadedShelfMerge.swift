import Foundation
import Persistence

/// Merges the account-owned ABS and device-owned RSS Downloads projections for Home's shelf and
/// its disclosure page.
///
/// Pure like `ContinueListeningMerge`: both surfaces must agree on ordering, deduplication and the
/// limit. The RSS namespace is reserved, so an identity collision is only defensive. Ordered by
/// title, the nearest shared key to the ABS `sortTitle` (a `HomeItem` has none).
public enum DownloadedShelfMerge: Sendable {
  public static func merge(
    abs: [HomeItem],
    rss: [HomeItem],
    nativeSubscriptionsEnabled: Bool,
    limit: Int
  ) -> [HomeItem] {
    let candidates = (abs + (nativeSubscriptionsEnabled ? rss : [])).sorted { lhs, rhs in
      let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
      if byTitle != .orderedSame { return byTitle == .orderedAscending }
      return lhs.serverItemId < rhs.serverItemId
    }

    var seen = Set<String>()
    var result: [HomeItem] = []
    result.reserveCapacity(candidates.count)
    for item in candidates where seen.insert(item.serverItemId).inserted {
      result.append(item)
    }
    return Array(result.prefix(max(0, limit)))
  }
}
