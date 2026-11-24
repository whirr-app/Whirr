import Foundation
import Persistence
import Testing

@testable import TestSupport

/// Proves the release half of the observation contract on `FakeLibraryReading`.
///
/// A leaked continuation is silent: a later push would fan out to consumers that had already gone
/// away. The subscriber counts are the observable half, and without a test that cancels and reads
/// them back, `onTermination` could be deleted and no suite would notice.
@Suite("Fake observation release")
struct FakeObservationReleaseTests {
  /// Cancels `consumer`, then waits for `count` to reach zero. Cancellation propagates to the
  /// stream's `onTermination` asynchronously, so reading the count straight after `cancel()` would
  /// race the removal it is meant to observe.
  private func expectRelease(
    of consumer: Task<Void, Never>,
    liveCount: @escaping @Sendable () -> Int,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    consumer.cancel()
    await consumer.value
    let released = await waitUntil("the subscription to be released", sourceLocation: sourceLocation) {
      liveCount() == 0
    }
    #expect(released, "\(liveCount()) subscriptions were still live", sourceLocation: sourceLocation)
  }

  @Test func aCancelledBrowseObserverReleasesItsSubscription() async {
    let library = FakeLibraryReading()
    let consumer = Task { for await _ in library.observeBrowseList(libraryId: "library-1") {} }
    #expect(await waitUntil { library.browseSubscriberCount == 1 })
    await expectRelease(of: consumer, liveCount: { library.browseSubscriberCount })
  }

  @Test func aCancelledCrossLibraryObserverReleasesItsSubscription() async {
    let library = FakeLibraryReading()
    let consumer = Task { for await _ in library.observeBrowseList(category: .audiobook) {} }
    #expect(await waitUntil { library.crossLibrarySubscriberCount == 1 })
    await expectRelease(of: consumer, liveCount: { library.crossLibrarySubscriberCount })
  }

  @Test func aCancelledFilteredObserverReleasesItsSubscription() async {
    let library = FakeLibraryReading()
    let filters = BrowseFilters()
    let consumer = Task { for await _ in library.observeBrowseList(filters: filters) {} }
    #expect(await waitUntil { library.filteredSubscriberCount == 1 })
    await expectRelease(of: consumer, liveCount: { library.filteredSubscriberCount })
  }

  @Test func aCancelledSyncStatusObserverReleasesItsSubscription() async {
    let library = FakeLibraryReading()
    let consumer = Task { for await _ in library.observeSyncStatus(libraryId: "library-1") {} }
    #expect(await waitUntil { library.syncStatusSubscriberCount == 1 })
    await expectRelease(of: consumer, liveCount: { library.syncStatusSubscriberCount })
  }

  @Test func aCancelledItemDetailObserverReleasesItsSubscription() async {
    let library = FakeLibraryReading()
    let consumer = Task { for await _ in library.observeItemDetail(itemId: "item-1") {} }
    #expect(await waitUntil { library.itemDetailSubscriberCount == 1 })
    await expectRelease(of: consumer, liveCount: { library.itemDetailSubscriberCount })
  }

  /// The aggregate stream shares the library-scoped stream's continuation list, so two live
  /// observers must be counted and released independently rather than by a shared flag.
  @Test func aggregateAndScopedSyncStatusObserversReleaseIndependently() async {
    let library = FakeLibraryReading()
    let scoped = Task { for await _ in library.observeSyncStatus(libraryId: "library-1") {} }
    let aggregate = Task { for await _ in library.observeAggregateSyncStatus() {} }
    #expect(await waitUntil { library.syncStatusSubscriberCount == 2 })

    scoped.cancel()
    await scoped.value
    #expect(await waitUntil { library.syncStatusSubscriberCount == 1 })

    await expectRelease(of: aggregate, liveCount: { library.syncStatusSubscriberCount })
  }
}
