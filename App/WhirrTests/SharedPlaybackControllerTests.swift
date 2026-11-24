import PlayerCore
import Testing

@testable import Whirr

/// Covers `SharedPlaybackController`'s progress-event fan-out. Consumers (`PlaybackModel`,
/// `NowPlayingMetadataAdapter`) are rebuilt on every `AppEnvironment` rebuild (login, logout), and
/// each torn-down consumer's `deinit` cancels the task iterating its stream. That terminates an
/// `AsyncStream` for good, so every subscription must be a fresh, independent stream. A single
/// shared stream would be killed by a displaced consumer on behalf of its replacement.
@MainActor
@Suite("SharedPlaybackController")
struct SharedPlaybackControllerTests {

  private func makeSUT() -> (shared: SharedPlaybackController, fake: FakeAdapterPlaybackControlling) {
    let fake = FakeAdapterPlaybackControlling()
    let adapter = AudioInterruptionRouteAdapter(player: fake)
    return (SharedPlaybackController(underlying: fake, interruptionAdapter: adapter), fake)
  }

  private static func event(sequence: Int) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: sequence, itemId: "item-1", phase: .playing, currentTime: Double(sequence),
      listenedDelta: 0)
  }

  /// Consumes `stream` as `PlaybackModel` and `NowPlayingMetadataAdapter` do, with a long-lived
  /// task. Each sequence number is forwarded so the test can confirm receipt while the consumer
  /// is live. Returns the task (for cancellation, as in `deinit`) and a receipts iterator.
  private func startConsumer(of stream: AsyncStream<PlaybackProgressEvent>) -> (
    task: Task<Void, Never>, receipts: AsyncStream<Int>.Iterator
  ) {
    let (receipts, continuation) = AsyncStream<Int>.makeStream()
    let task = Task {
      for await event in stream { continuation.yield(event.sequence) }
      continuation.finish()
    }
    return (task, receipts.makeAsyncIterator())
  }

  @Test("a consumer built after an earlier consumer was cancelled still receives progress events")
  func resubscriptionAfterConsumerCancellation() async {
    let (shared, fake) = makeSUT()

    // First-generation consumer, the pre-login PlaybackModel. Cancelled once it is iterating,
    // as RootView's rebuild after authentication does when it deallocates the model graph.
    var (firstTask, firstReceipts) = startConsumer(of: shared.progressEvents)
    fake.emit(Self.event(sequence: 1))
    #expect(await firstReceipts.next() == 1)
    firstTask.cancel()
    await firstTask.value

    // Second-generation consumer (the post-login PlaybackModel) subscribes afresh and must see
    // everything emitted from its subscription onward.
    var (secondTask, secondReceipts) = startConsumer(of: shared.progressEvents)
    fake.emit(Self.event(sequence: 2))
    #expect(await secondReceipts.next() == 2)
    secondTask.cancel()
    await secondTask.value
  }

  @Test("a secondary consumer rebuilt after cancellation still receives events")
  func secondaryResubscriptionAfterCancellation() async {
    let (shared, fake) = makeSUT()

    // The NowPlaying adapter is rebound (old one deallocated, its listener task cancelled) on
    // every AppEnvironment rebuild.
    var (firstTask, firstReceipts) = startConsumer(
      of: SecondaryPlaybackControllingView(shared: shared).progressEvents)
    fake.emit(Self.event(sequence: 1))
    #expect(await firstReceipts.next() == 1)
    firstTask.cancel()
    await firstTask.value

    var (secondTask, secondReceipts) = startConsumer(
      of: SecondaryPlaybackControllingView(shared: shared).progressEvents)
    fake.emit(Self.event(sequence: 2))
    #expect(await secondReceipts.next() == 2)
    secondTask.cancel()
    await secondTask.value
  }

  @Test("primary and secondary subscribers each receive the same event")
  func primaryAndSecondarySubscribersBothReceive() async {
    let (shared, fake) = makeSUT()

    var (primaryTask, primaryReceipts) = startConsumer(of: shared.progressEvents)
    var (secondaryTask, secondaryReceipts) = startConsumer(
      of: SecondaryPlaybackControllingView(shared: shared).progressEvents)

    fake.emit(Self.event(sequence: 7))
    #expect(await primaryReceipts.next() == 7)
    #expect(await secondaryReceipts.next() == 7)
    primaryTask.cancel()
    secondaryTask.cancel()
    await primaryTask.value
    await secondaryTask.value
  }

  @Test("quick-action projections forward without falling back to full player state")
  func quickActionProjectionsForwardDedicatedUnderlyingValues() {
    let (shared, fake) = makeSUT()
    let expected = PlayerQuickActionsState(
      rate: 1.75,
      sleepTimerMode: .endOfChapter,
      item: PlayerQuickActionsItem(
        id: "projected-item", episodeID: nil, totalDuration: 3_600, hasChapters: true))
    fake.quickActionsOverride = expected

    #expect(shared.state == .idle, "the full state deliberately disagrees with the projection")
    #expect(shared.quickActions == expected)
    #expect(SecondaryPlaybackControllingView(shared: shared).quickActions == expected)
  }

  @Test("sleep-timer label projection forwards without falling back to full player state")
  func sleepTimerProjectionForwardsDedicatedUnderlyingValue() {
    let (shared, fake) = makeSUT()
    let expected = SleepTimerState(mode: .countdown(remainingSeconds: 89))
    fake.quickActionsSleepTimerOverride = expected

    #expect(shared.state.sleepTimer == .off, "the full state deliberately disagrees with the projection")
    #expect(shared.quickActionsSleepTimer == expected)
    #expect(SecondaryPlaybackControllingView(shared: shared).quickActionsSleepTimer == expected)
  }
}
