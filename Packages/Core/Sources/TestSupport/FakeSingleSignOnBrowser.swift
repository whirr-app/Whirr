import AppModel
import Foundation

/// A `SingleSignOnBrowsing` that answers at once with a scripted outcome and records each request.
@MainActor
public final class FakeSingleSignOnBrowser: SingleSignOnBrowsing {
  public enum Outcome: Sendable {
    case callback(URL)
    case cancelled
    case failure(any Error)
  }

  public struct Request: Equatable {
    public let url: URL
    public let callbackScheme: String
    public let prefersEphemeralSession: Bool

    public init(url: URL, callbackScheme: String, prefersEphemeralSession: Bool) {
      self.url = url
      self.callbackScheme = callbackScheme
      self.prefersEphemeralSession = prefersEphemeralSession
    }
  }

  public static let defaultCallback = URL(string: "whirr://oauth?code=fake-code&state=fake-state")!

  public var outcome: Outcome
  public private(set) var requests: [Request] = []
  /// Runs while the "browser" is open, before it answers: stands in for whatever the user or the
  /// app does meanwhile.
  public var whileOpen: (@MainActor () -> Void)?
  /// Hold it (`hold()`) to keep the "browser" open until the test answers with the `Outcome` to
  /// return, so two sign-ins can overlap. Open by default, so the browser answers with `outcome`
  /// at once.
  public let gate = TestGate<Outcome>(label: "FakeSingleSignOnBrowser.authenticate")

  public init(outcome: Outcome = .callback(FakeSingleSignOnBrowser.defaultCallback)) {
    self.outcome = outcome
  }

  public func authenticate(at url: URL, callbackScheme: String, prefersEphemeralSession: Bool) async throws -> URL? {
    requests.append(
      Request(url: url, callbackScheme: callbackScheme, prefersEphemeralSession: prefersEphemeralSession))
    whileOpen?()
    let scripted = outcome
    switch await gate.pass(otherwise: { scripted }) {
    case .callback(let url): return url
    case .cancelled: return nil
    case .failure(let error): throw error
    }
  }
}
