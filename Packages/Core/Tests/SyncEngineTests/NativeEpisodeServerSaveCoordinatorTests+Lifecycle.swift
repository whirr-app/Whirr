import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

extension NativeEpisodeServerSaveCoordinatorTests {
  @Test func disablingNativeSubscriptionsAfterCreateStopsTheEnqueueSend() async throws {
    let fixture = try await SaveFixture.make()
    let subscriptions = FakeNativePodcastSubscriptionsReading(enabled: true)
    let gate = BlockingGate()
    let writer = StubPodcastWriter(trace: fixture.trace, createGate: gate)
    let coordinator = NativeEpisodeServerSaveCoordinator(
      accountReader: fixture.accountReader,
      capabilityReader: FixedCapabilityReader(canSave: true),
      commandReader: fixture.commandReader,
      destinationResolver: StubDestinationResolver(.create(lifecycleDestination())),
      podcastWriter: writer,
      itemDetailReader: StubItemDetailReader(.success(lifecycleCompleteItem(id: "created-show"))),
      attemptStore: fixture.attemptStore,
      nativeSubscriptions: subscriptions,
      foregroundConvergenceDelays: [])

    let saveTask = Task {
      await coordinator.save(feedId: fixture.command.feedId, episodeId: fixture.command.episodeId)
    }
    await gate.waitUntilEntered()
    await subscriptions.setEnabled(false)
    await gate.release()

    let result = await saveTask.value
    #expect(result == .failed(attemptID: 1, state: .failed, category: .unsubscribed))
    #expect(await writer.counts() == (1, 0))

    let record = try #require(try await fixture.baseStore.fetchAttemptAsync(id: 1))
    #expect(record.state == .failed)
    #expect(record.serverItemId == "created-show")
    #expect(record.accountId == fixture.accountID)
  }
}

private func lifecycleDestination() -> ServerPodcastDestination {
  ServerPodcastDestination(
    libraryID: "podcasts",
    folder: LibraryFolder(id: "folder", fullPath: "/srv/podcasts", libraryID: "podcasts"),
    nativeFeedTitle: "Native Show")!
}

private func lifecycleCompleteItem(id: String) -> ItemDetail {
  ItemDetail(
    id: id,
    libraryID: "podcasts",
    mediaType: "podcast",
    media: .podcast(
      PodcastMedia(
        title: "Native Show",
        author: "Native Author",
        description: "Native Synopsis",
        episodes: [],
        isEpisodeListStructurallyComplete: true)))
}
