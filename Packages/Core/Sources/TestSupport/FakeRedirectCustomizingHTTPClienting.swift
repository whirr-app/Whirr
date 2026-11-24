import ABSApi
import Foundation
import PodcastFeeds

/// `RedirectCustomizingHTTPClienting`'s fake: the transport seam under `FeedFetchClient`, the
/// directory search and the artwork client. It answers from a queue of scripted outcomes, then from
/// `fallback` for every request after the queue is empty, and records each request.
///
/// Hold `gate` to park every request until the test releases it, either with a response that
/// every parked request returns, or with `nil` to let each one take its scripted outcome. A parked
/// request whose task is cancelled counts in `cancellations` and throws `CancellationError`.
/// `maxInFlight` is the highest number of requests that were in the transport at once.
public final class FakeRedirectCustomizingHTTPClienting: RedirectCustomizingHTTPClienting,
  @unchecked Sendable
{
  /// One scripted answer: a response, or the error the transport fails with.
  public typealias Outcome = Result<HTTPResponse, any Error>

  /// Every request, in order, recorded before it is gated or answered.
  public let recorder = CallRecorder<HTTPRequest>(
    label: "FakeRedirectCustomizingHTTPClienting requests")

  /// Hold it (`hold()`) to park each request. `release(response)` resumes every parked request
  /// with `response`; `release(nil)` resumes each with its next scripted outcome. Open by default.
  public let gate = TestGate<HTTPResponse?>(label: "FakeRedirectCustomizingHTTPClienting.send")

  /// Requests that were cancelled while parked on `gate`.
  public let cancellations = TestCountRecorder(
    label: "FakeRedirectCustomizingHTTPClienting cancelled requests")

  private struct Flight {
    var current = 0
    var maximum = 0
  }

  private let script: Locked<[Outcome]>
  private let fallback: Locked<Outcome>
  private let flight = Locked(Flight())

  /// - Parameters:
  ///   - responses: outcomes returned in order, one per request.
  ///   - fallback: what every request returns once `responses` is spent (by default a failure, so
  ///     an unscripted request cannot pass unnoticed).
  public init(
    responses: [Outcome] = [],
    fallback: Outcome = .failure(FakeHTTPClientError(message: "No scripted response"))
  ) {
    script = Locked(responses)
    self.fallback = Locked(fallback)
  }

  /// The requests received so far, in order.
  public var requests: [HTTPRequest] { recorder.calls }

  /// The highest number of requests that were in `send` at the same moment.
  public var maxInFlight: Int { flight.value.maximum }

  public func send(
    _ request: HTTPRequest, redirectHandler _: any HTTPRedirectHandling
  ) async throws -> HTTPResponse {
    recorder.record(request)
    flight.withValue {
      $0.current += 1
      $0.maximum = max($0.maximum, $0.current)
    }
    defer { flight.withValue { $0.current -= 1 } }
    let wasGated = gate.isHeld
    if let released = await gate.pass(otherwise: { nil }) { return released }
    if wasGated && Task.isCancelled {
      cancellations.record()
      throw CancellationError()
    }
    return try nextOutcome().get()
  }

  private func nextOutcome() -> Outcome {
    let scripted = script.withValue { script -> Outcome? in
      script.isEmpty ? nil : script.removeFirst()
    }
    return scripted ?? fallback.value
  }
}
