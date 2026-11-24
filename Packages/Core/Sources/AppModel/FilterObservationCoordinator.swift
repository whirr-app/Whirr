import Foundation

/// Keeps a group of filter-scoped observations on one lifecycle.
///
/// A filter change is a generation change: values from an old generation are discarded, and the
/// consumer is told whether the current generation has its first value from every source. Home and
/// Library can then hold their rendered snapshot and publish the next as one unit, with one shared
/// sequencing contract.
@MainActor
final class FilterObservationCoordinator {
  struct Generation: Equatable {
    fileprivate let id: Int
  }

  private var nextGenerationID = 0
  private var activeGeneration: Generation?
  private var expectedSourceCount = 0
  private var receivedSourceIDs = Set<Int>()
  private var tasks: [Task<Void, Never>] = []

  deinit {
    for task in tasks { task.cancel() }
  }

  /// Starts a new generation and invalidates every task belonging to the previous one.
  func begin(sourceCount: Int) -> Generation {
    precondition(sourceCount > 0, "A filter observation needs at least one source")

    for task in tasks { task.cancel() }
    tasks.removeAll(keepingCapacity: true)

    nextGenerationID += 1
    let generation = Generation(id: nextGenerationID)
    activeGeneration = generation
    expectedSourceCount = sourceCount
    receivedSourceIDs.removeAll(keepingCapacity: true)
    return generation
  }

  /// Attaches one source to a generation. `ready` is false until every source has emitted once;
  /// it remains true for later emissions in that same generation so a consumer can keep updating
  /// its committed snapshot after the initial atomic swap.
  func observe<Value: Sendable>(
    _ stream: AsyncStream<Value>,
    sourceID: Int,
    in generation: Generation,
    receive: @escaping @MainActor @Sendable (Value, _ ready: Bool) -> Void
  ) {
    precondition(sourceID >= 0 && sourceID < expectedSourceCount)

    let task = Task { [weak self] in
      for await value in stream {
        guard let self else { return }
        guard let ready = self.accept(sourceID: sourceID, in: generation) else { return }
        receive(value, ready)
      }
    }
    tasks.append(task)
  }

  private func accept(sourceID: Int, in generation: Generation) -> Bool? {
    guard activeGeneration == generation else { return nil }

    receivedSourceIDs.insert(sourceID)
    return receivedSourceIDs.count == expectedSourceCount
  }
}
