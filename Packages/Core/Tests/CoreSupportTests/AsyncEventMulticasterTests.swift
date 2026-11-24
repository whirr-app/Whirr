import Foundation
import Testing

@testable import CoreSupport

/// Invariants: one underlying producer, N independent consumers, and a teardown that is strictly
/// local to the subscriber doing the tearing down.
@Suite("AsyncEventMulticaster", .timeLimit(.minutes(1)))
struct AsyncEventMulticasterTests {

  @Test("every subscriber receives every event yielded after it subscribed")
  func everySubscriberReceivesEveryEvent() async {
    let multicaster = AsyncEventMulticaster<Int>()
    let first = multicaster.subscribe()
    let second = multicaster.subscribe()

    multicaster.yield(1)
    multicaster.yield(2)
    multicaster.finish()

    #expect(await collect(first) == [1, 2])
    #expect(await collect(second) == [1, 2])
  }

  @Test("a torn-down subscriber terminates only its own stream")
  func aTornDownSubscriberTerminatesOnlyItsOwnStream() async {
    let multicaster = AsyncEventMulticaster<Int>()
    let survivor = multicaster.subscribe()
    let doomed = multicaster.subscribe()
    let doomedTask = Task {
      for await _ in doomed {}
    }

    multicaster.yield(1)
    doomedTask.cancel()
    await doomedTask.value
    // A consumer going away must not close the producer for anyone else. A cancelled iterator
    // finishing the single underlying stream would freeze every later event for every consumer.
    multicaster.yield(2)
    multicaster.finish()

    #expect(await collect(survivor) == [1, 2])
  }

  @Test("events yielded before a subscription are not replayed to it")
  func earlierEventsAreNotReplayed() async {
    let multicaster = AsyncEventMulticaster<Int>()

    multicaster.yield(1)
    let late = multicaster.subscribe()
    multicaster.yield(2)
    multicaster.finish()

    #expect(await collect(late) == [2])
  }

  @Test("finish terminates every live subscriber")
  func finishTerminatesEveryLiveSubscriber() async {
    let multicaster = AsyncEventMulticaster<Int>()
    let first = multicaster.subscribe()
    let second = multicaster.subscribe()

    multicaster.finish()

    #expect(await collect(first).isEmpty)
    #expect(await collect(second).isEmpty)
  }

  @Test("subscribing after finish yields an already-finished stream")
  func subscribingAfterFinishYieldsAFinishedStream() async {
    let multicaster = AsyncEventMulticaster<Int>()
    multicaster.finish()

    let late = multicaster.subscribe()
    multicaster.yield(1)

    #expect(await collect(late).isEmpty)
  }

  @Test("the fan-out is generic over the event type")
  func theFanOutIsGenericOverTheEventType() async {
    let multicaster = AsyncEventMulticaster<String>()
    let stream = multicaster.subscribe()

    multicaster.yield("a")
    multicaster.finish()

    #expect(await collect(stream) == ["a"])
  }

  private func collect<Event: Sendable>(_ stream: AsyncStream<Event>) async -> [Event] {
    var received: [Event] = []
    for await event in stream { received.append(event) }
    return received
  }
}
