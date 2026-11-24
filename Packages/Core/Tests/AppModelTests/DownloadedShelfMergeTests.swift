import Persistence
import Testing

@testable import AppModel

/// The Downloads shelf's merge is pure so Home and its disclosure page agree: title order across
/// both sources, one row per identity, the limit applied last, and the RSS half gated off with the
/// native-subscriptions feature.
@Suite struct DownloadedShelfMergeTests {

  @Test func ordersByTitleAcrossSourcesAndAppliesTheLimitLast() {
    let abs = [Self.item(id: "abs-z", title: "Zeta"), Self.item(id: "abs-b", title: "beta")]
    let rss = [Self.item(id: "rss:1", title: "Alpha"), Self.item(id: "rss:2", title: "Gamma")]

    let merged = DownloadedShelfMerge.merge(
      abs: abs, rss: rss, nativeSubscriptionsEnabled: true, limit: 3)

    #expect(merged.map(\.serverItemId) == ["rss:1", "abs-b", "rss:2"])
  }

  @Test func theGateRemovesEveryRSSRow() {
    let abs = [Self.item(id: "abs", title: "Zeta")]
    let rss = [Self.item(id: "rss:1", title: "Alpha")]

    let merged = DownloadedShelfMerge.merge(
      abs: abs, rss: rss, nativeSubscriptionsEnabled: false, limit: 10)

    #expect(merged == abs)
  }

  @Test func aDuplicateIdentityAppearsOnce() {
    let item = Self.item(id: "rss:1", title: "Alpha")

    let merged = DownloadedShelfMerge.merge(
      abs: [item], rss: [item], nativeSubscriptionsEnabled: true, limit: 10)

    #expect(merged == [item])
  }

  @Test func aNonPositiveLimitYieldsNothing() {
    let merged = DownloadedShelfMerge.merge(
      abs: [Self.item(id: "abs", title: "Zeta")], rss: [],
      nativeSubscriptionsEnabled: true, limit: 0)

    #expect(merged.isEmpty)
  }

  private static func item(id: String, title: String) -> HomeItem {
    HomeItem(
      serverItemId: id, title: title, author: nil, category: .podcast, durationSeconds: nil,
      progressSeconds: 0, isFinished: false, addedAt: nil, isDownloaded: true,
      audioDownloaded: true)
  }
}
