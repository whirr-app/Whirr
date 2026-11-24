import Foundation

/// Records request/response metadata through `RedactingHTTPLogger`, then forwards the response
/// (or rethrows the failure) unchanged. One of the internal transport decorators from
/// ARCHITECTURE.md §2, composed only in `Authentication.swift`.
struct LoggingHTTPClient: HTTPClienting {
  let transport: any HTTPClienting
  let logger: RedactingHTTPLogger

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let started = Date()
    do {
      let response = try await transport.send(request)
      await logger.record(
        request: request,
        response: response,
        duration: Date().timeIntervalSince(started),
        requestID: nil
      )
      return response
    } catch {
      await logger.recordFailure(
        request: request,
        duration: Date().timeIntervalSince(started),
        requestID: nil
      )
      throw error
    }
  }
}

/// Reports whether the wrapped foreground transport received an HTTP response or failed with a
/// `URLError`, then forwards the response or rethrows the original error unchanged. This is a
/// supplement, not a complete reachability oracle: `CoverImageClient` builds its own transport,
/// the App background-download adapter uses its own `URLSession`, and AVFoundation fetches audio
/// stream URLs directly. Those three traffic paths do not cross this decorator.
struct ReachabilityObservingHTTPClient: HTTPClienting {
  let transport: any HTTPClienting
  let observer: any ServerReachabilityObserving

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    do {
      let response = try await transport.send(request)
      await observer.reachabilityEvent(.responded)
      return response
    } catch let error as URLError {
      // Cancellation says nothing about the server: `URLSession.bytes` reports `.cancelled` when
      // the enclosing `Task` is cancelled, which a SwiftUI `.task` does on every disappear.
      // Counting those would let ordinary navigation build up "failures" and assert an outage
      // against a healthy server.
      if error.code != .cancelled {
        await observer.reachabilityEvent(.transportFailure)
      }
      throw error
    } catch {
      throw error
    }
  }
}

/// Admits requests through `ServerRequestGate` (FIFO, at most four in flight) before forwarding.
/// One of the internal transport decorators from ARCHITECTURE.md §2, composed only in
/// `Authentication.swift`.
struct GatedHTTPClient: HTTPClienting {
  let transport: any HTTPClienting
  let gate: ServerRequestGate

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await gate.withPermit { try await transport.send(request) }
  }
}
