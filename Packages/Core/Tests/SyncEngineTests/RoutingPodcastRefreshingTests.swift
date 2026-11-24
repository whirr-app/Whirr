import Foundation
import SyncEngine
import TestSupport
import Testing

@Suite struct RoutingPodcastRefreshingTests {
  @Test func routesRefreshesPreservesIdsAndHandlesInvalidIds() async throws {
    let abs = FakePodcastRefreshing(result: .success(.partial))
    let rss = FakePodcastRefreshing(result: .success(.complete))
    let refreshing = RoutingPodcastRefreshing(abs: abs, rss: rss)

    #expect(try await refreshing.refresh(itemID: "li_abc") == .partial)
    #expect(try await refreshing.refresh(itemID: "rss:7") == .complete)
    #expect(abs.refreshedItemIDs == ["li_abc"])
    #expect(rss.refreshedItemIDs == ["rss:7"])

    for itemID in ["", "rss:007"] {
      #expect(try await refreshing.refresh(itemID: itemID) == .complete)
    }
    #expect(abs.refreshedItemIDs == ["li_abc"])
    #expect(rss.refreshedItemIDs == ["rss:7"])
  }

  @Test func routesTheStaleGatedRefreshToTheSameSource() async throws {
    let abs = FakePodcastRefreshing(result: .success(.partial))
    let rss = FakePodcastRefreshing(result: .success(.complete))
    let refreshing = RoutingPodcastRefreshing(abs: abs, rss: rss)

    #expect(try await refreshing.refreshIfStale(itemID: "li_abc", maximumAge: 60) == .partial)
    #expect(try await refreshing.refreshIfStale(itemID: "rss:7", maximumAge: 60) == .complete)
    #expect(try await refreshing.refreshIfStale(itemID: "", maximumAge: 60) == .complete)
    #expect(abs.calls == [.refreshIfStale(itemID: "li_abc", maximumAge: 60)])
    #expect(rss.calls == [.refreshIfStale(itemID: "rss:7", maximumAge: 60)])
    #expect(abs.refreshedItemIDs.isEmpty && rss.refreshedItemIDs.isEmpty)
  }

  @Test func propagatesChildErrors() async {
    let expected = TestError()
    let refreshing = RoutingPodcastRefreshing(
      abs: FakePodcastRefreshing(result: .failure(expected)),
      rss: FakePodcastRefreshing(result: .success(.complete)))

    await #expect(throws: TestError.self) {
      try await refreshing.refresh(itemID: "li_abc")
    }
  }
}

private struct TestError: Error, Equatable {}
