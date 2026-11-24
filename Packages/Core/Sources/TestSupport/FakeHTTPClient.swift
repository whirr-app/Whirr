import ABSApi
import Foundation
import Testing

public struct FakeHTTPClientError: Error, Sendable, Equatable, CustomStringConvertible {
  public let message: String

  public init(message: String) {
    self.message = message
  }

  public var description: String { message }
}

public final class FakeHTTPClient: HTTPClienting, @unchecked Sendable {
  private let responseQueue: Locked<[HTTPResponse]>
  private let failureQueue: Locked<[any Error]>
  private let failure: (any Error)?
  private let requestHook = Locked<(@Sendable (HTTPRequest) async -> Void)?>(nil)
  private let handler = Locked<(@Sendable (HTTPRequest) async throws -> HTTPResponse)?>(nil)

  public let recorder = CallRecorder<HTTPRequest>(label: "FakeHTTPClient requests")

  public var requests: [HTTPRequest] { recorder.calls }

  public init(responses: [HTTPResponse] = [], failure: FakeHTTPClientError? = nil) {
    responseQueue = Locked(responses)
    failureQueue = Locked([])
    self.failure = failure
  }

  /// Fails every request with an arbitrary error rather than the fake's own type. Needed by tests
  /// that assert on how a real `URLError` is classified downstream.
  public init(responses: [HTTPResponse] = [], transportFailure: any Error) {
    responseQueue = Locked(responses)
    failureQueue = Locked([])
    failure = transportFailure
  }

  /// Answers every request from `handler` instead of the queues: routing by path, scripting a
  /// refresh, blocking on a `TestGate`, or throwing. Requests are still recorded first.
  public init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
    responseQueue = Locked([])
    failureQueue = Locked([])
    failure = nil
    self.handler.value = handler
  }

  /// Replaces the handler after construction; `nil` returns to the queues.
  public func setHandler(_ handler: (@Sendable (HTTPRequest) async throws -> HTTPResponse)?) {
    self.handler.value = handler
  }

  /// Appends more canned responses after construction, for tests that drive several sequential
  /// `refresh()` calls (e.g. two completed generations before a hard delete) without knowing the
  /// full response sequence up front.
  public func enqueue(_ response: HTTPResponse) {
    responseQueue.withValue { $0.append(response) }
  }

  public func enqueue(contentsOf responses: [HTTPResponse]) {
    responseQueue.withValue { $0.append(contentsOf: responses) }
  }

  public func enqueueFailure(_ error: any Error) {
    failureQueue.withValue { $0.append(error) }
  }

  /// Test-only synchronization seam. The request is recorded before this hook runs, so a test can
  /// deterministically change durable state while a request is in flight and release it later.
  public func setRequestHook(_ hook: (@Sendable (HTTPRequest) async -> Void)?) {
    requestHook.value = hook
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    recorder.record(request)
    if let hook = requestHook.value {
      await hook(request)
    }
    if let handler = handler.value {
      return try await handler(request)
    }
    if let failure {
      throw failure
    }
    if let failure = failureQueue.withValue({ failures -> (any Error)? in
      guard failures.isEmpty == false else { return nil }
      return failures.removeFirst()
    }) {
      throw failure
    }
    let result: Result<HTTPResponse, FakeHTTPClientError> = responseQueue.withValue { responses in
      guard responses.isEmpty == false else {
        return .failure(FakeHTTPClientError(message: "No canned response"))
      }
      return .success(responses.removeFirst())
    }
    return try result.get()
  }

  /// Test-only: suspends, bounded, until the recorded request list satisfies `predicate`.
  @discardableResult
  public func waitForRequests(
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation,
    satisfying predicate: @escaping @Sendable ([HTTPRequest]) -> Bool
  ) async -> TestWaitOutcome {
    await recorder.waitUntil(timeout: timeout, sourceLocation: sourceLocation, predicate)
  }
}
