import ABSApi
import Foundation

/// Waiters-by-key bookkeeping for one bounded URL transport.
///
/// Concurrent identical keys share one flight; the flight is cancelled only when its last waiter
/// cancels, never by one waiter leaving a flight another still holds; and a retryable failure arms
/// a per-URL backoff that success clears. The owning actor supplies the flight's work and stays the
/// only thing that serializes this pool, so the pool itself needs no isolation.
///
/// The flight key is not always the URL: `FeedFetchClient` keys by URL *and* credential
/// fingerprint, so two credentials for one feed never share a response. Backoff and pacing stay
/// per URL, as they were before the pool existed.
struct URLFlightPool<Key: Hashable, Value: Sendable> {
  private struct URLState {
    var policy = BackoffPolicy()
    var notBefore: Date?
  }

  private struct Flight {
    let task: Task<Value, Error>
    var waiters: Set<UUID>
  }

  private let now: @Sendable () -> Date
  private let randomUnit: @Sendable () -> Double
  private var states: [URL: URLState] = [:]
  private var flights: [Key: Flight] = [:]

  /// Flights still awaiting their last waiter. Test evidence for the cancellation boundary.
  var flightCount: Int { flights.count }

  init(now: @escaping @Sendable () -> Date, randomUnit: @escaping @Sendable () -> Double) {
    self.now = now
    self.randomUnit = randomUnit
  }

  /// The instant this URL may be retried, or nil when no retryable failure is pacing it.
  func backoffRetryAfter(for url: URL) -> Date? {
    guard let notBefore = states[url]?.notBefore, now() < notBefore else { return nil }
    return notBefore
  }

  /// Joins the flight for `key` when one is in flight, otherwise starts `make`'s task and records
  /// this caller as its first waiter.
  mutating func joinOrStart(
    key: Key, waiterID: UUID, make: () -> Task<Value, Error>
  ) -> Task<Value, Error> {
    if var existing = flights[key] {
      existing.waiters.insert(waiterID)
      flights[key] = existing
      return existing.task
    }

    let task = make()
    flights[key] = Flight(task: task, waiters: [waiterID])
    return task
  }

  /// Removes this waiter from its flight. The last waiter out cancels a flight whose caller was
  /// cancelled, and reports the flight's result so success clears the URL's pacing while a
  /// retryable failure arms it.
  mutating func finish(
    key: Key, url: URL, waiterID: UUID, cancelling: Bool, result: Result<Value, Error>?
  ) {
    guard var flight = flights[key], flight.waiters.remove(waiterID) != nil else { return }
    guard flight.waiters.isEmpty else {
      flights[key] = flight
      return
    }
    if cancelling { flight.task.cancel() }
    flights[key] = nil

    guard let result else { return }
    switch result {
    case .success:
      // Success clears the entry so the table only holds URLs that are actually paced.
      states[url] = nil
    case .failure(let error) where BackoffPolicy.isRetryable(error):
      // Retry-After is not exposed by the thrown APIError.rateLimited, so it cannot pace retries.
      var state = states[url] ?? URLState()
      let current = now()
      let delay = state.policy.nextDelay(retryAfter: nil, now: current, randomUnit: randomUnit())
      state.notBefore = current.addingTimeInterval(delay)
      states[url] = state
    case .failure:
      break
    }
  }
}
