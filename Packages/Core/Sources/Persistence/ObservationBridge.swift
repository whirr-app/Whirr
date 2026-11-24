import Foundation
import GRDB
import os

/// The one Persistence boundary between GRDB observations and AsyncStream consumers.
internal enum ObservationBridge {
  /// Whether a consumer sees a value it has already seen. Suppression is the observation's own
  /// `removeDuplicates()`, so a restarted observation re-emits one current-value baseline.
  internal enum Deduplication: Sendable {
    /// Forward every observation change, including one that leaves the value equal.
    case everyChange
    /// Forward a value only when it differs from the last one forwarded.
    case unchangedValuesSuppressed
  }

  private static let logger = PersistenceLogging.logger(category: "observation")
  private static let retryDelays: [Duration] = [
    .milliseconds(250),
    .milliseconds(500),
    .seconds(1),
    .seconds(2),
    .seconds(4),
    .seconds(8),
    .seconds(16),
    .seconds(30),
  ]

  internal static func stream<Value: Sendable & Equatable>(
    in dbWriter: any DatabaseWriter,
    deduplication: Deduplication,
    fetch: @escaping @Sendable (Database) throws -> Value
  ) -> AsyncStream<Value> {
    let observation = ValueObservation.tracking(fetch)
    switch deduplication {
    case .everyChange:
      return stream(in: dbWriter, observation: observation)
    case .unchangedValuesSuppressed:
      return stream(in: dbWriter, observation: observation.removeDuplicates())
    }
  }

  internal static func stream<Value: Sendable>(
    in dbWriter: any DatabaseWriter,
    fetch: @escaping @Sendable (Database) throws -> Value
  ) -> AsyncStream<Value> {
    stream(in: dbWriter, observation: ValueObservation.tracking(fetch))
  }

  internal static func stream<Reducer: ValueReducer>(
    in dbWriter: any DatabaseWriter,
    observation: ValueObservation<Reducer>
  ) -> AsyncStream<Reducer.Value> where Reducer.Value: Sendable {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        var consecutiveFailures = 0
        while Task.isCancelled == false {
          do {
            // Starting again creates a fresh GRDB reducer. An observation with removeDuplicates()
            // therefore emits one current-value baseline after recovery, then resumes deduplicating.
            for try await value in observation.values(
              in: dbWriter, bufferingPolicy: .bufferingNewest(1)
            ) {
              consecutiveFailures = 0
              continuation.yield(value)
            }
            continuation.finish()
            return
          } catch {
            guard Task.isCancelled == false else { break }

            let retryDelay = retryDelays[min(consecutiveFailures, retryDelays.count - 1)]
            let delayDescription = String(describing: retryDelay)
            let errorDescription = String(describing: error)
            logger.error(
              "Database observation failed; retrying in \(delayDescription, privacy: .public). Error: \(errorDescription, privacy: .private)"
            )
            if consecutiveFailures < retryDelays.count - 1 {
              consecutiveFailures += 1
            }

            do {
              try await Task.sleep(for: retryDelay)
            } catch {
              break
            }
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
