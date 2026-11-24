import ABSApi
import Foundation

/// Credential-free `/status` operation supplied by the composition root. An ABSApi adapter calls
/// `ABSClient.fetchServerStatus()` and discards its response; the monitor only needs to know
/// whether that operation proved that the server answered.
public protocol ServerStatusProbing: Sendable {
  func probeServerStatus() async throws
}

/// The composition bridge for the existing unauthenticated ABSApi route. The response is
/// discarded before it reaches SyncEngine: reachability publishes state only, not
/// server version or any other response body field.
public struct ABSClientServerStatusProbe: ServerStatusProbing, Sendable {
  private let client: ABSClient

  public init(client: ABSClient) {
    self.client = client
  }

  public func probeServerStatus() async throws {
    _ = try await client.fetchServerStatus()
  }
}

/// A construction-order bridge for the shared credential-free `/status` probe: the monitor must
/// exist before `ABSClient` is built with its reachability observer, yet the probe needs that
/// client. The slot is weak because the account-lifetime composition owns the client; a strong
/// edge would make client, observer, monitor and probe a cycle once the shared-services cache
/// replaces an account. An emptied slot reports no verdict rather than an outage, so outliving the
/// client cannot manufacture one.
public final class LateBoundServerStatusProbe: ServerStatusProbing, @unchecked Sendable {
  private let lock = NSLock()
  private weak var client: ABSClient?

  public init() {}

  /// Binds the client after the monitor and its observer adapter have been composed. Rebinding is
  /// harmless; the lock is held only for the reference swap, never across the network await.
  public func setClient(_ client: ABSClient) {
    lock.lock()
    self.client = client
    lock.unlock()
  }

  public func probeServerStatus() async throws {
    // A cold launch can trigger the monitor before the slot is filled. That is our wiring, not the
    // server, so it reports the same no-verdict cancellation as a timed-out request and the
    // monitor re-arms. An unanswered-request failure would assert an outage, and a probe failure
    // bypasses the three-failure hysteresis, so it would reach the user immediately.
    guard let client = clientSnapshot() else {
      throw URLError(.cancelled)
    }
    _ = try await client.fetchServerStatus()
  }

  private func clientSnapshot() -> ABSClient? {
    lock.lock()
    defer { lock.unlock() }
    return client
  }
}
