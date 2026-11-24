import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Server reachability observing")
struct ServerReachabilityObservingTests {
  @Test("a successful response emits exactly one responded event")
  func successfulResponseEmitsResponded() async throws {
    let observer = RecordingServerReachabilityObserving()
    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let client = ReachabilityObservingHTTPClient(transport: transport, observer: observer)

    _ = try await client.send(makeRequest())

    #expect(await observer.events == [.responded])
  }

  @Test("HTTP error responses count as responded, not transport failures")
  func httpErrorResponsesEmitResponded() async throws {
    for statusCode in [401, 500] {
      let observer = RecordingServerReachabilityObserving()
      let transport = FakeHTTPClient(
        responses: [HTTPResponse(statusCode: statusCode, headers: [:], body: Data())])
      let client = ReachabilityObservingHTTPClient(transport: transport, observer: observer)

      let response = try await client.send(makeRequest())

      #expect(response.statusCode == statusCode)
      #expect(await observer.events == [.responded])
    }
  }

  @Test("a transport failure emits no error payload and rethrows the original URLError")
  func transportFailurePreservesURLError() async throws {
    let observer = RecordingServerReachabilityObserving()
    let failingURL = URL(string: "https://books.example.test/search?q=private-term")!
    let originalError = URLError(
      .notConnectedToInternet,
      userInfo: [NSURLErrorFailingURLStringErrorKey: failingURL.absoluteString])
    let transport = FakeHTTPClient(transportFailure: originalError)
    let client = ReachabilityObservingHTTPClient(transport: transport, observer: observer)

    do {
      _ = try await client.send(makeRequest())
      Issue.record("expected the transport to throw")
    } catch {
      let rethrownError = try #require(error as? URLError)
      #expect(rethrownError.code == originalError.code)
      #expect(
        (rethrownError as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String
          == failingURL.absoluteString)
    }

    let events = await observer.events
    #expect(events.count == 1)
    guard case .transportFailure = events[0] else {
      Issue.record("expected a transportFailure event")
      return
    }
  }

  @Test("a cancelled request is not evidence about the server")
  func cancellationEmitsNoEvent() async throws {
    let observer = RecordingServerReachabilityObserving()
    let originalError = URLError(.cancelled)
    let transport = FakeHTTPClient(transportFailure: originalError)
    let client = ReachabilityObservingHTTPClient(transport: transport, observer: observer)

    do {
      _ = try await client.send(makeRequest())
      Issue.record("expected the transport to throw")
    } catch {
      let rethrownError = try #require(error as? URLError)
      #expect(rethrownError.code == .cancelled)
    }

    #expect(await observer.events.isEmpty)
  }

  @Test("a non-URLError is rethrown without an event")
  func nonURLErrorIsRethrownWithoutObservation() async throws {
    let observer = RecordingServerReachabilityObserving()
    let originalError = FakeHTTPClientError(message: "not a URL loading error")
    let transport = FakeHTTPClient(transportFailure: originalError)
    let client = ReachabilityObservingHTTPClient(transport: transport, observer: observer)

    do {
      _ = try await client.send(makeRequest())
      Issue.record("expected the transport to throw")
    } catch {
      let rethrownError = try #require(error as? FakeHTTPClientError)
      #expect(rethrownError == originalError)
      #expect(type(of: error) == FakeHTTPClientError.self)
    }

    #expect(await observer.events.isEmpty)
  }

  @Test("ABSClient composition observes the raw transport")
  func absClientCompositionReachesObserver() async throws {
    let server = try makeServer()
    let observer = RecordingServerReachabilityObserving()
    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let client = ABSClient(
      server: server,
      httpClient: transport,
      tokenStore: InMemoryTokenStore(),
      serverReachabilityObserving: observer
    )

    let response = try await client.send(makeRequest())

    #expect(response.statusCode == 200)
    #expect(await observer.events == [.responded])
  }

  @Test("ABSClient defaults to the no-op reachability observer")
  func defaultConstructionStillWorks() async throws {
    let server = try makeServer()
    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 204, headers: [:], body: Data())])
    let client = ABSClient(
      server: server,
      httpClient: transport,
      tokenStore: InMemoryTokenStore()
    )

    let response = try await client.send(makeRequest())

    #expect(response.statusCode == 204)
  }
}

private func makeServer() throws -> ABSServerConfig {
  try ABSServerConfig(url: URL(string: "https://books.example.test")!)
}

private func makeRequest() -> HTTPRequest {
  HTTPRequest(
    method: .get,
    url: URL(string: "https://books.example.test/status")!,
    headers: [:],
    body: nil,
    routeTemplate: "/status"
  )
}

private actor RecordingServerReachabilityObserving: ServerReachabilityObserving {
  private(set) var events: [ServerReachabilityEvent] = []

  func reachabilityEvent(_ event: ServerReachabilityEvent) async {
    events.append(event)
  }
}
