import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct NativePodcastSubscriptionsGatedRefreshingTests {
  @Test func disabledPreferenceNeverEntersRefreshChild() async throws {
    let preference = FakeNativePodcastSubscriptionsReading(enabled: false)
    let child = FakePodcastRefreshing()
    let gate = NativePodcastSubscriptionsGatedRefreshing(child: child, reading: preference)

    #expect(try await gate.refresh(itemID: "rss:1") == .complete)
    #expect(child.refreshedItemIDs == [])
  }

  @Test func theStaleGatedRefreshIsDisarmedAndForwardedTheSameWay() async throws {
    let preference = FakeNativePodcastSubscriptionsReading(enabled: false)
    let child = FakePodcastRefreshing()
    let gate = NativePodcastSubscriptionsGatedRefreshing(child: child, reading: preference)

    #expect(try await gate.refreshIfStale(itemID: "rss:1", maximumAge: 60) == .complete)
    #expect(child.staleRefreshedItemIDs == [])

    await preference.setEnabled(true)
    #expect(try await gate.refreshIfStale(itemID: "rss:2", maximumAge: 60) == .complete)
    #expect(child.staleRefreshedItemIDs == ["rss:2"])
    #expect(child.refreshedItemIDs == [])
  }

  @Test func liveToggleControlsTheNextRefresh() async throws {
    let preference = FakeNativePodcastSubscriptionsReading(enabled: true)
    let child = FakePodcastRefreshing()
    let gate = NativePodcastSubscriptionsGatedRefreshing(child: child, reading: preference)

    _ = try await gate.refresh(itemID: "rss:1")
    await preference.setEnabled(false)
    _ = try await gate.refresh(itemID: "rss:2")

    #expect(child.refreshedItemIDs == ["rss:1"])
  }
}
