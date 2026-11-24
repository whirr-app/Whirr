import TestSupport
import Testing

@testable import AppModel

/// The coordinator's observation tasks capture it weakly and upgrade per iteration, so dropping
/// the owning model releases the coordinator even while a source stream never finishes. Its
/// generation check only exits a stale loop on that stream's next emission, which never comes
/// for a discarded owner, so deinit's cancellation is the only teardown path.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct FilterObservationCoordinatorTests {

  @Test func coordinatorDeinitializesWhileItsObservationStreamRemainsAlive() async {
    let source = TestStream(initial: 1)
    weak var observer: FilterObservationCoordinator?
    var coordinator: FilterObservationCoordinator?

    let received = ReceivedValues()
    do {
      coordinator = FilterObservationCoordinator()
      observer = coordinator
      let generation = coordinator!.begin(sourceCount: 1)
      coordinator!.observe(source.stream, sourceID: 0, in: generation) { value, _ in
        received.append(value)
      }
      source.push(2)
      #expect(await waitUntil { received.values.contains(2) })
      coordinator = nil
    }

    #expect(await waitUntil { observer == nil })
  }
}

private final class ReceivedValues: @unchecked Sendable {
  private(set) var values: [Int] = []

  func append(_ value: Int) { values.append(value) }
}

private final class TestStream: @unchecked Sendable {
  let stream: AsyncStream<Int>
  private let continuation: AsyncStream<Int>.Continuation

  init(initial: Int) {
    var captured: AsyncStream<Int>.Continuation?
    stream = AsyncStream { captured = $0 }
    continuation = captured!
    continuation.yield(initial)
  }

  func push(_ value: Int) { continuation.yield(value) }
}
